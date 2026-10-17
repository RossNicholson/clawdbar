import XCTest
import SwiftUI
@testable import ClawdBar

/// Renders the panel, its popovers and the welcome screen with sample usage,
/// for the website and for checking the design. Skipped unless SCREENSHOTS
/// names an output folder: `make screenshots`.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var out: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOTS"], !dir.isEmpty else {
            throw XCTSkip("Set SCREENSHOTS to render screenshots")
        }
        out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private func sampleFetcher(error: String? = nil, weekly: Double = 0.27) -> UsageFetcher {
        let fetcher = UsageFetcher()
        fetcher.usage = UsageData(session5h: 0.42, session5hReset: Date().addingTimeInterval(2 * 3600 + 15 * 60),
                                  weekly7d: weekly, weekly7dReset: Date().addingTimeInterval(3 * 86400 + 5 * 3600),
                                  status: "allowed")
        fetcher.lastUpdated = Date().addingTimeInterval(-12)
        fetcher.lastError = error
        return fetcher
    }

    func testRenderPanel() throws {
        for dark in [false, true] {
            let fetcher = sampleFetcher()
            let updater = SelfUpdater(app: .clawdBar)
            try Snapshot.panel(dark: dark, to: out.appendingPathComponent("panel\(dark ? "-dark" : "-light").png")) {
                MenuBarView().environmentObject(fetcher).environmentObject(updater)
            }
        }
        let busy = sampleFetcher(weekly: 0.71)
        try Snapshot.panel(to: out.appendingPathComponent("panel-forecast.png")) {
            MenuBarView().environmentObject(busy).environmentObject(SelfUpdater(app: .clawdBar))
        }
        let failing = sampleFetcher(error: "Claude credentials were rejected. Try signing in again via Claude Code.")
        try Snapshot.panel(to: out.appendingPathComponent("panel-error.png")) {
            MenuBarView().environmentObject(failing).environmentObject(SelfUpdater(app: .clawdBar))
        }
    }

    func testRenderPopovers() throws {
        let fetcher = sampleFetcher()
        let updater = SelfUpdater(app: .clawdBar)
        for dark in [false, true] {
            try Snapshot.panel(dark: dark, to: out.appendingPathComponent("panel-settings\(dark ? "-dark" : "").png")) {
                SettingsView().environmentObject(fetcher).environmentObject(updater)
            }
        }
        try Snapshot.panel(to: out.appendingPathComponent("panel-about.png")) {
            AboutPopover(app: .clawdBar) { Mascot(size: 56) }
        }
        try Snapshot.panel(to: out.appendingPathComponent("panel-welcome.png")) {
            WelcomeView {}
        }
        try Snapshot.panel(to: out.appendingPathComponent("panel-login.png")) {
            LoginCodeView()
        }
    }
}
