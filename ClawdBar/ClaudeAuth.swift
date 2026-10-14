import Foundation
import Security
import AppKit
import CryptoKit
import os

/// Self-contained Claude sign-in for ClawdBar.
///
/// Instead of depending on whatever Claude Code happens to have stashed in the
/// Keychain (which can be duplicated, expired, or inaccessible), ClawdBar can run
/// its OWN OAuth login and store its OWN token in its OWN Keychain item, which it
/// fully controls and can refresh. UsageFetcher prefers this token and only falls
/// back to reading Claude Code's entry.
///
/// NOTE: this uses Claude Code's OAuth flow, which is unofficial / reverse
/// engineered — Anthropic could change it, in which case the login would need
/// updating. The flow is: open the browser to authorize → user pastes back the
/// code shown by the callback page → exchange it for tokens.
@MainActor
final class ClaudeAuth: ObservableObject {
    static let shared = ClaudeAuth()

    @Published var isLoggedIn = false
    @Published var awaitingCode = false      // browser opened, waiting for the user to paste the code
    @Published var working = false           // exchanging/refreshing
    @Published var loginError: String?
    /// The saved login was revoked or expired (the server said invalid_grant),
    /// so ClawdBar signed out and needs a fresh login.
    @Published var signInExpired = false
    /// Why the last renewal failed, if it did. Cleared by the next success.
    @Published var lastRefreshError: String?

    private var pendingVerifier: String?
    private var pendingState: String?

    // One renewal at a time: each refresh token can be used only once, so two
    // overlapping renewals would leave one holding a spent token.
    private var refreshTask: Task<Creds, Error>?
    // After a temporary failure (offline, rate limited), wait before trying
    // again rather than hitting the token server on every poll.
    private var retryDelay: TimeInterval = 0
    private var retryNotBefore = Date.distantPast
    private var lastRetryableError: Error?

    private let logger = Logger(subsystem: "com.rossnicholson.ClawdBar", category: "auth")

    // Claude Code's public OAuth client + endpoints.
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let authorizeURL = "https://claude.ai/oauth/authorize"
    private let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    private let scopes = "org:create_api_key user:profile user:inference"

    private let service = "ClawdBar-claude-credentials"
    private let account = "oauth"

    private init() {
        isLoggedIn = (try? Self.readStored(service: service, account: account)) != nil
    }

    // MARK: - Login flow

    /// Step 1 — open the browser to the Claude authorization page.
    func beginLogin() {
        let verifier = Self.randomURLSafe(32)
        pendingVerifier = verifier
        pendingState = Self.randomURLSafe(24)
        loginError = nil

        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pendingState!),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
        awaitingCode = true
    }

    /// Step 2 — exchange the pasted code (the callback page shows "code#state").
    func completeLogin(pasted: String) async {
        guard let verifier = pendingVerifier else { loginError = "Please start the login again."; return }
        loginError = nil
        working = true
        defer { working = false }

        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? trimmed
        let state = parts.count > 1 ? parts[1] : (pendingState ?? "")

        do {
            let creds = try await exchange([
                "grant_type": "authorization_code",
                "code": code,
                "state": state,
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "code_verifier": verifier,
            ])
            try store(creds)
            isLoggedIn = true
            signInExpired = false
            clearRetryState()
            awaitingCode = false
            pendingVerifier = nil
            pendingState = nil
        } catch AuthError.signInExpired {
            loginError = "Login failed: that code is invalid or has expired. Please start again."
        } catch {
            loginError = "Login failed: \(error.localizedDescription)"
        }
    }

    func cancelLogin() {
        awaitingCode = false
        pendingVerifier = nil
        pendingState = nil
        loginError = nil
    }

    func logout() {
        Self.deleteStored(service: service, account: account)
        isLoggedIn = false
        signInExpired = false
        clearRetryState()
    }

    // MARK: - Token access (used by UsageFetcher)

    /// A usable access token from ClawdBar's own login, renewed when it's near
    /// expiry, or when `forceRefresh` is set because the API rejected it.
    /// Returns nil if not logged in here (the caller falls back to Claude
    /// Code's token). Throws `AuthError.signInExpired` if the login is dead,
    /// or the renewal error if it failed for a temporary reason; the login is
    /// kept and renewed again later.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String? {
        guard let creds = try? Self.readStored(service: service, account: account) else { return nil }
        let msToExpiry = creds.expiresAt - Date().timeIntervalSince1970 * 1000
        guard forceRefresh || msToExpiry < 60_000 else { return creds.accessToken }
        return try await refresh(creds).accessToken
    }

    // MARK: - Internals

    private func refresh(_ creds: Creds) async throws -> Creds {
        if let refreshTask { return try await refreshTask.value }
        if Date() < retryNotBefore, let lastRetryableError { throw lastRetryableError }

        let task = Task { try await renew(creds) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            clearRetryState()
            return new
        } catch AuthError.signInExpired {
            // The only failure that needs the user: the refresh token is dead
            logger.error("Refresh token rejected (invalid_grant); signing out")
            logout()
            signInExpired = true
            throw AuthError.signInExpired
        } catch {
            retryDelay = min(max(retryDelay * 2, 60), 15 * 60)
            retryNotBefore = Date().addingTimeInterval(retryDelay)
            lastRetryableError = error
            lastRefreshError = error.localizedDescription
            logger.error("Token refresh failed, retrying in \(Int(self.retryDelay))s: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Mirrors Claude Code's own renewal, which sends the scopes it holds
    private func renew(_ creds: Creds) async throws -> Creds {
        var grant = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": clientID,
            "scope": creds.scope ?? scopes,
        ]
        let new: Creds
        do {
            new = try await exchange(grant)
        } catch AuthError.invalidScope {
            // Asked for more than was granted; the server then uses the
            // original grant when no scope is sent
            grant["scope"] = nil
            new = try await exchange(grant)
        }
        try store(new)
        return new
    }

    private func clearRetryState() {
        retryDelay = 0
        retryNotBefore = .distantPast
        lastRetryableError = nil
        lastRefreshError = nil
    }

    private func exchange(_ grant: [String: String]) async throws -> Creds {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: grant)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AuthError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            switch UsageParse.tokenFailure(statusCode: http.statusCode, body: data) {
            case .signInExpired: throw AuthError.signInExpired
            case .invalidScope: throw AuthError.invalidScope
            case .temporary:
                let body = String(decoding: data, as: UTF8.self)
                logger.error("Token request HTTP \(http.statusCode): \(body, privacy: .public)")
                throw AuthError.server(status: http.statusCode)
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw AuthError.badResponse
        }
        let refreshToken = (json["refresh_token"] as? String) ?? grant["refresh_token"] ?? ""
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let expiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000
        let scope = (json["scope"] as? String) ?? grant["scope"]
        return Creds(accessToken: access, refreshToken: refreshToken, expiresAt: expiresAt, scope: scope)
    }

    // MARK: - Keychain (ClawdBar's own item)

    struct Creds { let accessToken: String; let refreshToken: String; let expiresAt: Double; let scope: String? }

    private func store(_ creds: Creds) throws {
        var fields: [String: Any] = [
            "accessToken": creds.accessToken,
            "refreshToken": creds.refreshToken,
            "expiresAt": creds.expiresAt,
        ]
        fields["scope"] = creds.scope
        let json = try JSONSerialization.data(withJSONObject: fields)
        Self.deleteStored(service: service, account: account)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: json,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychain(status) }
    }

    private static func readStored(service: String, account: String) throws -> Creds {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["accessToken"] as? String,
              let refresh = json["refreshToken"] as? String else {
            throw AuthError.notStored
        }
        let expiresAt = (json["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        return Creds(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                     scope: json["scope"] as? String)
    }

    private static func deleteStored(service: String, account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    // MARK: - PKCE

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }
    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum AuthError: LocalizedError {
        case server(status: Int), signInExpired, invalidScope, badResponse, notStored, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .server(let status):
                return status == 429 ? "Claude's sign-in server is rate limiting (HTTP 429)"
                                     : "Claude's sign-in server returned HTTP \(status)"
            case .signInExpired: return "the sign-in has expired"
            case .invalidScope: return "the sign-in asked for permissions it doesn't have"
            case .badResponse: return "unexpected response"
            case .notStored: return "no stored credentials"
            case .keychain(let s): return "keychain error \(s)"
            }
        }
    }
}
