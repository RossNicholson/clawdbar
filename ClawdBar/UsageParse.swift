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

/// Where the weekly limit is heading if you keep this window's average pace.
/// The server's figure already covers the whole window, so this needs no
/// history and still works after ClawdBar was closed for a while.
struct WeeklyForecast: Equatable {
    enum Verdict: Equatable { case plenty, tight, runsOut }

    let verdict: Verdict
    /// Usage at reset at the current pace, as a fraction (can pass 1). It's
    /// also the pace: 1.0 means exactly 100% by reset.
    let projectedAtReset: Double
    /// The most you can use per day, as a fraction, and still last to reset
    let dailyBudget: Double
    /// When the limit runs out, if that's before reset
    let runsOutAt: Date?
    let reset: Date

    var tag: String {
        switch verdict {
        case .plenty: return "Plenty"
        case .tight: return "Tight"
        case .runsOut: return "Runs dry"
        }
    }

    var paceText: String { String(format: "%.1f× pace", projectedAtReset) }

    /// "~73% at reset", or "Over by reset" when it won't last
    var ghostLabel: String {
        projectedAtReset > 1 ? "Over by reset, ~\(Int((projectedAtReset * 100).rounded()))%"
                             : "~\(Int((projectedAtReset * 100).rounded()))% at reset"
    }

    func message(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch verdict {
        case .plenty:
            return "You'll make it, ~\(Int(((1 - projectedAtReset) * 100).rounded()))% to spare"
        case .tight:
            return "Keep under \(max(1, Int(dailyBudget * 100)))% a day to last"
        case .runsOut:
            guard let runsOutAt else { return "Won't last to reset" }
            return "\(Self.when(runsOutAt, now: now, calendar: calendar, locale: locale)), \(Self.roughly(reset.timeIntervalSince(runsOutAt))) early"
        }
    }

    /// "1d 15h" or "21h": whole hours, as minutes would overstate the precision
    static func roughly(_ interval: TimeInterval) -> String {
        let hours = Int((interval / 3600).rounded())
        guard hours > 0 else { return "under 1h" }
        guard hours >= 24 else { return "\(hours)h" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// "Today ~3pm", "Tomorrow ~9am" or "Fri ~1pm" (or "~13:00" on a 24-hour
    /// Mac), rounded to the hour because it's an estimate
    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let hour = calendar.dateInterval(of: .hour, for: date.addingTimeInterval(1800))?.start ?? date
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
        formatter.dateFormat = twelveHour ? "ha" : "HH:mm"
        var time = formatter.string(from: hour)
        if twelveHour { time = time.lowercased() }

        let day: String
        if calendar.isDate(hour, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(hour, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            day = formatter.string(from: hour)
        }
        return "\(day) ~\(time)"
    }
}

extension UsageParse {
    static let weekLength: TimeInterval = 7 * 86400

    /// The weekly forecast, or nil when there's nothing useful to say: no data,
    /// already at the limit, or under 12 hours into the window, when one
    /// burst of work makes the pace swing wildly.
    static func weeklyForecast(used: Double?, reset: Date?, now: Date = Date()) -> WeeklyForecast? {
        guard let used, let reset, used > 0, used < 1 else { return nil }
        let left = reset.timeIntervalSince(now)
        let elapsed = weekLength - left
        guard left > 0, elapsed >= 12 * 3600 else { return nil }

        let rate = used / elapsed   // fraction per second
        let projected = used + rate * left
        let verdict: WeeklyForecast.Verdict = projected > 1 ? .runsOut : projected >= 0.9 ? .tight : .plenty
        return WeeklyForecast(
            verdict: verdict,
            projectedAtReset: projected,
            dailyBudget: (1 - used) / (left / 86400),
            runsOutAt: verdict == .runsOut ? now.addingTimeInterval((1 - used) / rate) : nil,
            reset: reset
        )
    }
}
