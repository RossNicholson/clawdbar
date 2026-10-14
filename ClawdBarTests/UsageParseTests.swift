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
}
