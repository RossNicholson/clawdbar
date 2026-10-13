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
}
