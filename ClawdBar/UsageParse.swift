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
}
