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
    private var hasNotified5h = false
    private var hasNotified7d = false
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

    func refresh() async {
        isLoading = true
        lastError = nil
        do {
            let token = try cachedToken ?? readAccessToken()
            cachedToken = token
            let result: UsageData
            do {
                result = try await fetchUsage(token: token)
            } catch FetchError.tokenRejected {
                // Cached token no longer valid — re-read keychain once and retry.
                let fresh = try readAccessToken()
                cachedToken = fresh
                result = try await fetchUsage(token: fresh)
            }
            usage = result
            lastUpdated = Date()
            checkNotifications(for: result)
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Credential reading

    private func readAccessToken() throws -> String {
        // 1. Claude Code desktop app Keychain entry
        if let token = try? keychainCredentials() { return token }
        // 2. Standalone CLI credentials file
        if let token = try? cliFileCredentials() { return token }
        throw FetchError.noCredentials
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
        let data = try Data(contentsOf: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String else {
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

        guard headers.keys.contains(where: { $0.hasPrefix("anthropic-ratelimit-unified") }) else {
            throw FetchError.noRateLimitHeaders(statusCode: http.statusCode)
        }

        // Reset values are Unix timestamps in seconds
        var result = UsageData()
        result.session5h = headers["anthropic-ratelimit-unified-5h-utilization"].flatMap(Double.init)
        result.weekly7d = headers["anthropic-ratelimit-unified-7d-utilization"].flatMap(Double.init)
        result.session5hReset = headers["anthropic-ratelimit-unified-5h-reset"].flatMap(unixDate)
        result.weekly7dReset = headers["anthropic-ratelimit-unified-7d-reset"].flatMap(unixDate)
        result.status = headers["anthropic-ratelimit-unified-5h-status"]
        return result
    }

    private func unixDate(_ s: String) -> Date? {
        Double(s).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Notifications

    private func checkNotifications(for result: UsageData) {
        guard UserDefaults.standard.bool(forKey: "notifyEnabled") else {
            hasNotified5h = false
            hasNotified7d = false
            return
        }
        let threshold = Double(UserDefaults.standard.integer(forKey: "notifyThresholdPercent")) / 100.0

        if let util = result.session5h {
            if util >= threshold && !hasNotified5h {
                hasNotified5h = true
                notify(id: "5h", title: "5h session at \(Int(util * 100))%",
                       body: "Your Claude Code 5-hour usage has reached your alert threshold.")
            } else if util < threshold - 0.1 {
                hasNotified5h = false
            }
        }

        if let util = result.weekly7d {
            if util >= threshold && !hasNotified7d {
                hasNotified7d = true
                notify(id: "7d", title: "7d weekly at \(Int(util * 100))%",
                       body: "Your Claude Code 7-day usage has reached your alert threshold.")
            } else if util < threshold - 0.1 {
                hasNotified7d = false
            }
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
                return "No rate-limit data in response (HTTP \(code)) — Claude Max plan required"
            }
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

func formatTimeRemaining(until date: Date) -> String {
    let seconds = max(0, date.timeIntervalSinceNow)
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
