import XCTest
@testable import ClawdBar

final class UsageParseTests: XCTestCase {

    func testReadsUnifiedRateLimitHeaders() {
        let usage = UsageParse.usage(fromHeaders: [
            "anthropic-ratelimit-unified-5h-utilization": "0.48",
            "anthropic-ratelimit-unified-7d-utilization": "0.23",
            "anthropic-ratelimit-unified-5h-reset": "1791936000",
            "anthropic-ratelimit-unified-5h-status": "allowed",
        ])
        XCTAssertEqual(usage?.session5h, 0.48)
        XCTAssertEqual(usage?.weekly7d, 0.23)
        XCTAssertEqual(usage?.session5hReset, Date(timeIntervalSince1970: 1791936000))
        XCTAssertNil(usage?.weekly7dReset)
        XCTAssertEqual(usage?.status, "allowed")
    }

    func testNoUsageWithoutUnifiedHeaders() {
        XCTAssertNil(UsageParse.usage(fromHeaders: ["content-type": "application/json"]))
    }

    func testCredentialsFileBothLayouts() {
        let nested = #"{"claudeAiOauth":{"accessToken":"abc","refreshToken":"r"}}"#.data(using: .utf8)!
        let flat = #"{"accessToken":"xyz"}"#.data(using: .utf8)!
        XCTAssertEqual(UsageParse.accessToken(fromCredentialsFile: nested), "abc")
        XCTAssertEqual(UsageParse.accessToken(fromCredentialsFile: flat), "xyz")
        XCTAssertNil(UsageParse.accessToken(fromCredentialsFile: Data("nope".utf8)))
    }

    func testAlertThresholdDefaultsTo80() {
        XCTAssertEqual(UsageParse.alertThreshold(nil), 0.8)
        XCTAssertEqual(UsageParse.alertThreshold(65), 0.65)
    }

    func testTimeRemaining() {
        XCTAssertEqual(formatTimeRemaining(until: Date().addingTimeInterval(3 * 86400 + 5 * 3600 + 30)), "3d 5h")
        XCTAssertEqual(formatTimeRemaining(until: Date().addingTimeInterval(2 * 3600 + 15 * 60 + 30)), "2h 15m")
        XCTAssertEqual(formatTimeRemaining(until: Date().addingTimeInterval(-60)), "0m")
    }

    func testAlertsOncePerLimitWindow() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        // First time over the threshold: alert
        XCTAssertTrue(UsageParse.shouldAlert(usage: 0.82, threshold: 0.8, reset: reset, lastAlertedReset: nil))
        // Same window (even after a relaunch): don't
        XCTAssertFalse(UsageParse.shouldAlert(usage: 0.9, threshold: 0.8, reset: reset, lastAlertedReset: reset))
        // A later window: alert again
        XCTAssertTrue(UsageParse.shouldAlert(usage: 0.85, threshold: 0.8, reset: reset.addingTimeInterval(5 * 3600), lastAlertedReset: reset))
        // Under the threshold: never
        XCTAssertFalse(UsageParse.shouldAlert(usage: 0.5, threshold: 0.8, reset: reset, lastAlertedReset: nil))
    }

    func testNoUsageMessages() {
        XCTAssertTrue(UsageParse.noUsageMessage(statusCode: 529).contains("busy"))
        XCTAssertTrue(UsageParse.noUsageMessage(statusCode: 404).contains("update"))
        XCTAssertTrue(UsageParse.noUsageMessage(statusCode: 403).contains("Pro or Max"))
    }

    func testOnlyInvalidGrantNeedsANewSignIn() {
        func failure(_ status: Int, _ body: String) -> UsageParse.TokenFailure {
            UsageParse.tokenFailure(statusCode: status, body: Data(body.utf8))
        }
        XCTAssertEqual(failure(400, #"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#), .signInExpired)
        XCTAssertEqual(failure(401, #"{"error":{"type":"invalid_grant"}}"#), .signInExpired)
        XCTAssertEqual(failure(400, #"{"error":"invalid_scope"}"#), .invalidScope)
        // Rate limits, server trouble and other errors are retried, not a sign-out
        XCTAssertEqual(failure(429, #"{"error":{"type":"rate_limit_error"}}"#), .temporary)
        XCTAssertEqual(failure(503, "invalid_grant"), .temporary)
        XCTAssertEqual(failure(400, #"{"error":"invalid_request"}"#), .temporary)
        XCTAssertEqual(failure(401, ""), .temporary)
    }

    // MARK: - Weekly forecast

    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    /// A forecast `daysIn` days into the week at `used` usage
    private func forecast(used: Double, daysIn: Double) -> WeeklyForecast? {
        UsageParse.weeklyForecast(used: used, reset: now.addingTimeInterval((7 - daysIn) * 86400), now: now)
    }

    func testForecastPlenty() throws {
        // 40% after 4 days is 10% a day, so 70% by reset
        let f = try XCTUnwrap(forecast(used: 0.4, daysIn: 4))
        XCTAssertEqual(f.verdict, .plenty)
        XCTAssertEqual(f.projectedAtReset, 0.7, accuracy: 0.0001)
        XCTAssertNil(f.runsOutAt)
        XCTAssertEqual(f.message(now: now), "You'll make it, ~30% to spare")
        XCTAssertEqual(f.ghostLabel, "~70% at reset")
        XCTAssertEqual(f.paceText, "0.7× pace")
    }

    func testForecastTight() throws {
        // 65% after 5 days: 91% by reset; 35% left over 2 days is 17.5% a day
        let f = try XCTUnwrap(forecast(used: 0.65, daysIn: 5))
        XCTAssertEqual(f.verdict, .tight)
        XCTAssertEqual(f.dailyBudget, 0.175, accuracy: 0.0001)
        XCTAssertEqual(f.message(now: now), "Keep under 17% a day to last")
    }

    func testForecastRunsOut() throws {
        // 60% after 3 days is 20% a day: out in 2 more days, 2 days before reset
        let f = try XCTUnwrap(forecast(used: 0.6, daysIn: 3))
        XCTAssertEqual(f.verdict, .runsOut)
        XCTAssertEqual(f.projectedAtReset, 1.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(f.runsOutAt).timeIntervalSince(now), 2 * 86400, accuracy: 1)
        XCTAssertTrue(f.message(now: now).hasSuffix(", 2d early"), f.message(now: now))
        XCTAssertEqual(f.ghostLabel, "Over by reset, ~140%")
        XCTAssertEqual(WeeklyForecast.roughly(21 * 3600 + 13 * 60), "21h")
        XCTAssertEqual(WeeklyForecast.roughly(39 * 3600 + 40 * 60), "1d 16h")
        XCTAssertEqual(WeeklyForecast.roughly(600), "under 1h")
    }

    func testForecastNeedsData() {
        XCTAssertNil(forecast(used: 0.3, daysIn: 0.25))   // too early in the week
        XCTAssertNil(forecast(used: 0, daysIn: 3))
        XCTAssertNil(forecast(used: 1, daysIn: 3))        // already at the limit
        XCTAssertNil(UsageParse.weeklyForecast(used: 0.5, reset: nil, now: now))
        XCTAssertNil(UsageParse.weeklyForecast(used: 0.5, reset: now.addingTimeInterval(-60), now: now))
    }

    func testForecastTimeIsRoundedToTheHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US"), uk = Locale(identifier: "en_GB")
        // now is Wed 2026-10-14 17:46:40 UTC
        func when(_ offset: TimeInterval, _ locale: Locale) -> String {
            WeeklyForecast.when(now.addingTimeInterval(offset), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(when(3 * 3600, us), "Today ~9pm")          // 20:46 rounds up
        XCTAssertEqual(when(3 * 3600, uk), "Today ~21:00")
        XCTAssertEqual(when(86400 - 1200, us), "Tomorrow ~5pm")   // 17:26 rounds down
        XCTAssertEqual(when(2 * 86400, uk), "Fri ~18:00")
    }
}
