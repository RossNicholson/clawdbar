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
    // After a "Don't Allow" on Claude Code's Keychain item, don't ask again on
    // every poll; a manual refresh (resetCredentials) asks straight away
    private var keychainDeniedUntil = Date.distantPast

    /// The usage endpoint is rate limited: Claude Code reads it at most every
    /// 5 minutes, and asking more often gets HTTP 429s. Automatic checks keep
    /// to that; the refresh button may ask after a minute.
    static let minimumInterval: TimeInterval = 5 * 60
    static let manualInterval: TimeInterval = 60
    static let intervals: [TimeInterval] = [5 * 60, 10 * 60, 15 * 60]
    private var lastRead = Date.distantPast
    // After a 429 from the usage endpoint: read usage the old way (the
    // headers of a 1-token message) until this, growing while 429s continue.
    // The endpoint's limit seems to be shared with Claude Code's own checks,
    // so with Claude Code open it can refuse ClawdBar for hours.
    private var endpointLimitedUntil = Date.distantPast
    private var endpointDelay: TimeInterval = 0

    static func interval(fromSetting stored: Double) -> TimeInterval {
        stored == 0 ? minimumInterval : max(stored, minimumInterval)
    }

    func start() {
        // Settings from before 1.3.4 could be 30 seconds or 1 minute
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        let interval = Self.interval(fromSetting: stored)
        if stored != interval { UserDefaults.standard.set(interval, forKey: "refreshInterval") }
        Task { await refresh(manual: true) }
        scheduleTimer(interval: interval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        scheduleTimer(interval: Self.interval(fromSetting: interval))
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
        keychainDeniedUntil = .distantPast
        // Another sign-in may be another account, with limits of its own
        endpointLimitedUntil = .distantPast
        endpointDelay = 0
        lastRead = .distantPast
    }

    /// `manual` is the refresh button (or a new sign-in): it may check after a
    /// minute, where the timer and opening the panel wait the full 5 minutes.
    func refresh(manual: Bool = false) async {
        // The timer, opening the panel and the refresh button can all ask at once
        guard !isLoading else { return }
        let now = Date()
        let gap = manual ? Self.manualInterval : Self.minimumInterval - 5   // timer ticks drift a little
        guard now.timeIntervalSince(lastRead) >= gap else { return }
        lastRead = now
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
    /// refresh. Claude Code's token is used only when ClawdBar has no login
    /// of its own: it can belong to another account, so a failed renewal
    /// shows an error rather than quietly switching. Only Claude Code's
    /// token is cached, to avoid a Keychain read every poll.
    private func currentToken(forceRefresh: Bool = false) async throws -> String {
        // 1. ClawdBar's own logged-in token (self-contained, auto-renewing)
        if let token = try await ClaudeAuth.shared.validAccessToken(forceRefresh: forceRefresh) { return token }
        // Its login just expired: say so until the user logs in again or out
        if ClaudeAuth.shared.signInExpired { throw ClaudeAuth.AuthError.signInExpired }
        if let cached = cachedToken { return cached }
        // 2. Claude Code desktop app Keychain entry, read off the main thread
        //    so its "allow access" prompt can't freeze the menu bar
        // 3. Standalone CLI credentials file
        var token: String?
        if Date() >= keychainDeniedUntil {
            switch await Task.detached(operation: { Self.keychainCredentials() }).value {
            case .found(let found): token = found
            case .denied: keychainDeniedUntil = Date().addingTimeInterval(15 * 60)
            case .none: break
            }
        }
        guard let token = token ?? (try? Self.cliFileCredentials()) else { throw FetchError.noCredentials }
        cachedToken = token
        return token
    }

    enum KeychainRead: Sendable { case found(String), denied, none }

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
    nonisolated private static func keychainCredentials() -> KeychainRead {
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
        var denied = false
        for entry in entries {
            guard let ref = entry[kSecValuePersistentRef as String] as? Data else { continue }
            let dataQuery: [String: Any] = [
                kSecValuePersistentRef as String: ref,
                kSecReturnData as String: true,
            ]
            var dataResult: CFTypeRef?
            let status = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
            if status == errSecUserCanceled || status == errSecAuthFailed { denied = true }
            guard status == errSecSuccess,
                  let data = dataResult as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else { continue }
            let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            if best == nil || expiresAt > best!.expiresAt { best = (token, expiresAt) }
        }
        if let token = best?.token { return .found(token) }
        return denied ? .denied : .none
    }

    nonisolated private static func cliFileCredentials() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let token = UsageParse.accessToken(fromCredentialsFile: try Data(contentsOf: path)) else {
            throw FetchError.noCredentials
        }
        return token
    }

    // MARK: - API

    /// Reads usage from the endpoint Claude Code's /usage uses. It only reads,
    /// so checking costs no quota and doesn't keep a 5-hour window open.
    /// While that endpoint is refusing with 429s, the old way is used instead.
    private func fetchUsage(token: String) async throws -> UsageData {
        guard Date() >= endpointLimitedUntil else { return try await fetchUsageFromHeaders(token: token) }
        do {
            let result = try await fetchUsageFromEndpoint(token: token)
            endpointDelay = 0
            return result
        } catch FetchError.rateLimited(let retryAfter) {
            // Leave the endpoint alone for as long as Anthropic asks, else
            // 15 minutes, then 30, then an hour
            endpointDelay = min(max(endpointDelay * 2, 15 * 60), 60 * 60)
            endpointLimitedUntil = Date().addingTimeInterval(max(retryAfter ?? 0, endpointDelay))
            return try await fetchUsageFromHeaders(token: token)
        }
    }

    private func fetchUsageFromEndpoint(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.clawdBar.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse }
        if http.statusCode == 401 { throw FetchError.tokenRejected }
        if http.statusCode == 429 {
            throw FetchError.rateLimited(retryAfter: (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init))
        }
        // Should the endpoint ever go, the old way still works: a 1-token
        // message whose rate-limit headers carry the same figures
        if http.statusCode == 404 { return try await fetchUsageFromHeaders(token: token) }
        guard http.statusCode == 200, let result = UsageParse.usage(fromUsageEndpoint: data) else {
            throw FetchError.noRateLimitHeaders(statusCode: http.statusCode)
        }
        return result
    }

    private func fetchUsageFromHeaders(token: String) async throws -> UsageData {
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

        let (_, response) = try await URLSession.clawdBar.data(for: request)
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
        case rateLimited(retryAfter: TimeInterval?)

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
            case .rateLimited:
                return UsageParse.noUsageMessage(statusCode: 429)
            }
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

extension URLSession {
    /// Gives up on a stalled request after 15 seconds, so a refresh (which
    /// can chain a renewal and a retry) can't keep the spinner going for minutes
    static let clawdBar: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
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
