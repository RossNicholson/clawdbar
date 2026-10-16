import Foundation
import Security
import UserNotifications

struct UsageData: Sendable {
    var session5h: Double?      // 0.0–1.0
    var session5hReset: Date?
    var weekly7d: Double?       // 0.0–1.0
    var weekly7dReset: Date?
    var status: String?
}

@MainActor
final class UsageFetcher: ObservableObject {
    @Published var usage = UsageData()
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?

    private var timer: Timer?
    private var cachedToken: String?

    func start() {
        let interval = UserDefaults.standard.double(forKey: "refreshInterval").nonZero ?? 60
        Task { await refresh() }
        scheduleTimer(interval: interval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        scheduleTimer(interval: interval)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    /// Forget the cached Claude Code token, e.g. after logging in or out, so the
    /// next refresh picks the right credentials.
    func resetCredentials() {
        cachedToken = nil
    }

    func refresh() async {
        // The timer, opening the panel and the refresh button can all ask at once
        guard !isLoading else { return }
        isLoading = true
        // lastError is kept until this refresh finishes, so the error card
        // doesn't vanish and reappear (resizing the panel) on every retry
        do {
            let token = try await currentToken()
            let result: UsageData
            do {
                result = try await fetchUsage(token: token)
            } catch FetchError.tokenRejected {
                // Token no longer valid — renew our own login if we have one,
                // or re-read Claude Code's from scratch, and retry once.
                cachedToken = nil
                result = try await fetchUsage(token: try await currentToken(forceRefresh: true))
            }
            usage = result
            lastUpdated = Date()
            lastError = nil
            checkNotifications(for: result)
        } catch {
            lastError = message(for: error)
        }
        isLoading = false
    }

    // MARK: - Credential reading

    /// ClawdBar's own login is checked every time (it's cheap, and renews
    /// itself before expiry), so logging in or out takes effect on the next
    /// refresh. If it can't give a token right now, Claude Code's is used
    /// instead, so a renewal hiccup doesn't interrupt anything. Only Claude
    /// Code's token is cached, to avoid a Keychain read every poll.
    private func currentToken(forceRefresh: Bool = false) async throws -> String {
        // 1. ClawdBar's own logged-in token (self-contained, auto-renewing)
        var ownError: Error?
        do {
            if let token = try await ClaudeAuth.shared.validAccessToken(forceRefresh: forceRefresh) { return token }
        } catch {
            ownError = error
        }
        if let cached = cachedToken { return cached }
        // 2. Claude Code desktop app Keychain entry
        // 3. Standalone CLI credentials file
        guard let token = (try? keychainCredentials()) ?? (try? cliFileCredentials()) else {
            throw ownError ?? FetchError.noCredentials
        }
        cachedToken = token
        return token
    }

    /// Sign-in problems are explained by ClawdBar's own login state when it has
    /// one: only an expired login asks the user to act; a failed renewal just
    /// says it will retry.
    private func message(for error: Error) -> String {
        let auth = ClaudeAuth.shared
        switch error {
        case FetchError.tokenRejected, FetchError.noCredentials, is ClaudeAuth.AuthError:
            if auth.signInExpired {
                return "ClawdBar's sign-in has expired. Log in again to keep usage updating."
            }
            if let renewError = auth.lastRefreshError {
                return "Couldn't renew ClawdBar's sign-in (\(renewError)). ClawdBar will try again."
            }
            if case FetchError.tokenRejected = error, auth.isLoggedIn {
                return "ClawdBar's own sign-in was rejected. Log out and back in from Settings."
            }
        default:
            break
        }
        return error.localizedDescription
    }

    /// Reads the Claude Code OAuth access token from the Keychain.
    ///
    /// There can be MORE THAN ONE "Claude Code-credentials" item — e.g. a stale
    /// entry left by an old login sitting next to the live one. A `kSecMatchLimitOne`
    /// query returns an *arbitrary* match, which is how we'd end up using an expired
    /// token and getting 401s ("credentials rejected") even though a valid token is
    /// present. So read them all and pick the token with the latest `expiresAt`.
    private func keychainCredentials() throws -> String {
        // There can be more than one "Claude Code-credentials" item (a stale entry
        // from an old login next to the live one), and they can have DIFFERENT
        // access permissions. Asking for every item's data at once
        // (kSecMatchLimitAll + kSecReturnData) fails outright if any one item is
        // inaccessible — reading nothing. So first enumerate the items by reference
        // (attributes only, which doesn't touch the protected data), then read each
        // one's data individually, skip any we can't access, and use the token with
        // the latest expiresAt.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var listResult: CFTypeRef?
        var entries: [[String: Any]] = []
        if SecItemCopyMatching(listQuery as CFDictionary, &listResult) == errSecSuccess {
            entries = (listResult as? [[String: Any]]) ?? (listResult as? [String: Any]).map { [$0] } ?? []
        }

        var best: (token: String, expiresAt: Double)?
        for entry in entries {
            guard let ref = entry[kSecValuePersistentRef as String] as? Data else { continue }
            let dataQuery: [String: Any] = [
                kSecValuePersistentRef as String: ref,
                kSecReturnData as String: true,
            ]
            var dataResult: CFTypeRef?
            guard SecItemCopyMatching(dataQuery as CFDictionary, &dataResult) == errSecSuccess,
                  let data = dataResult as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else { continue }
            let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            if best == nil || expiresAt > best!.expiresAt { best = (token, expiresAt) }
        }
        guard let token = best?.token else { throw FetchError.noCredentials }
        return token
    }

    private func cliFileCredentials() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let token = UsageParse.accessToken(fromCredentialsFile: try Data(contentsOf: path)) else {
            throw FetchError.noCredentials
        }
        return token
    }

    // MARK: - API

    private func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }

        if http.statusCode == 401 { throw FetchError.tokenRejected }

        // allHeaderFields keys are NSString — bridge manually and normalize to lowercase
        var headers = [String: String]()
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k.lowercased()] = v
            }
        }

        guard let result = UsageParse.usage(fromHeaders: headers) else {
            throw FetchError.noRateLimitHeaders(statusCode: http.statusCode)
        }
        return result
    }

    // MARK: - Notifications

    private func checkNotifications(for result: UsageData) {
        guard UserDefaults.standard.bool(forKey: "notifyEnabled") else { return }
        let threshold = UsageParse.alertThreshold(UserDefaults.standard.object(forKey: "notifyThresholdPercent"))
        let limits: [(id: String, usage: Double?, reset: Date?, title: String, body: String)] = [
            ("5h", result.session5h, result.session5hReset, "5h session",
             "Your Claude Code 5-hour usage has reached your alert threshold."),
            ("7d", result.weekly7d, result.weekly7dReset, "7d weekly",
             "Your Claude Code 7-day usage has reached your alert threshold."),
        ]
        for limit in limits {
            guard let usage = limit.usage else { continue }
            // Remembered across launches, so restarting ClawdBar doesn't alert again
            let key = "alertedReset\(limit.id)"
            let last = (UserDefaults.standard.object(forKey: key) as? Double).map(Date.init(timeIntervalSince1970:))
            guard UsageParse.shouldAlert(usage: usage, threshold: threshold, reset: limit.reset, lastAlertedReset: last) else { continue }
            UserDefaults.standard.set((limit.reset ?? Date()).timeIntervalSince1970, forKey: key)
            notify(id: limit.id, title: "\(limit.title) at \(Int(usage * 100))%", body: limit.body)
        }
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Errors

    enum FetchError: LocalizedError {
        case noCredentials
        case badResponse
        case tokenRejected
        case noRateLimitHeaders(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No Claude credentials found — log in via Claude Code or the desktop app"
            case .badResponse:
                return "Unexpected response from Anthropic API"
            case .tokenRejected:
                return "Claude credentials were rejected — try signing in again via Claude Code"
            case .noRateLimitHeaders(let code):
                return UsageParse.noUsageMessage(statusCode: code)
            }
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

func formatTimeRemaining(until date: Date) -> String {
    formatDuration(date.timeIntervalSinceNow)
}

/// "3d 5h", "2h 15m" or "40m"
func formatDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, interval)
    let minutes = Int(seconds / 60)
    let hours = minutes / 60
    let days = hours / 24

    if days > 0 {
        let h = hours % 24
        return h > 0 ? "\(days)d \(h)h" : "\(days)d"
    } else if hours > 0 {
        let m = minutes % 60
        return m > 0 ? "\(hours)h \(m)m" : "\(hours)h"
    }
    return "\(minutes)m"
}
