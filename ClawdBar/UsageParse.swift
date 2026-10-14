import Foundation

/// Pure parsing, kept apart from UsageFetcher (which does networking and
/// Keychain access) so it can be unit tested.
enum UsageParse {

    /// Reads Anthropic's unified rate-limit headers (keys lowercased). Nil when
    /// the response has none, e.g. on a plan without usage limits.
    static func usage(fromHeaders headers: [String: String]) -> UsageData? {
        guard headers.keys.contains(where: { $0.hasPrefix("anthropic-ratelimit-unified") }) else { return nil }
        // Reset values are Unix timestamps in seconds
        func date(_ key: String) -> Date? {
            headers[key].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        }
        var result = UsageData()
        result.session5h = headers["anthropic-ratelimit-unified-5h-utilization"].flatMap(Double.init)
        result.weekly7d = headers["anthropic-ratelimit-unified-7d-utilization"].flatMap(Double.init)
        result.session5hReset = date("anthropic-ratelimit-unified-5h-reset")
        result.weekly7dReset = date("anthropic-ratelimit-unified-7d-reset")
        result.status = headers["anthropic-ratelimit-unified-5h-status"]
        return result
    }

    /// The access token in Claude Code's credentials file. It uses the same
    /// layout as the Keychain entry ({"claudeAiOauth": {"accessToken": …}});
    /// older versions put the token at the top level, so accept either.
    static func accessToken(fromCredentialsFile data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = json["claudeAiOauth"] as? [String: Any] ?? json
        return oauth["accessToken"] as? String
    }

    /// Alert threshold as a fraction. Settings shows 80% until the slider is
    /// moved, but @AppStorage doesn't save its default, so an unset value means
    /// 80 (not 0, which alerted at any usage).
    static func alertThreshold(_ stored: Any?) -> Double {
        Double(stored as? Int ?? 80) / 100
    }

    /// Whether to alert for one limit. Each limit window alerts at most once,
    /// even across relaunches: `lastAlertedReset` is the reset time of the
    /// window we last alerted in, and only a clearly later window (over an
    /// hour later, allowing for jitter) can alert again.
    static func shouldAlert(usage: Double, threshold: Double, reset: Date?, lastAlertedReset: Date?) -> Bool {
        guard usage >= threshold else { return false }
        guard let last = lastAlertedReset else { return true }
        guard let reset else { return false }
        return reset.timeIntervalSince(last) > 3600
    }

    /// What a failed token request means. Only `invalid_grant` says the saved
    /// login is dead and needs the user; anything else (offline, rate limited,
    /// server trouble) is temporary and worth retrying later.
    enum TokenFailure: Equatable { case signInExpired, invalidScope, temporary }

    static func tokenFailure(statusCode: Int, body: Data) -> TokenFailure {
        guard statusCode == 400 || statusCode == 401 else { return .temporary }
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("invalid_grant") { return .signInExpired }
        if text.contains("invalid_scope") { return .invalidScope }
        return .temporary
    }

    /// What to say when a response carried no usage headers, by HTTP status
    static func noUsageMessage(statusCode code: Int) -> String {
        switch code {
        case 500..<600, 429:
            return "Anthropic's API is busy right now (HTTP \(code)). ClawdBar will try again."
        case 404:
            return "The usage check failed (HTTP 404). ClawdBar may need an update."
        default:
            return "No usage data in the response (HTTP \(code)). Usage limits need a Claude Pro or Max plan."
        }
    }
}
