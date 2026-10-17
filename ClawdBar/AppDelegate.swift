import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanelController!
    private var cancellables = Set<AnyCancellable>()
    let fetcher = UsageFetcher()
    let selfUpdater = SelfUpdater(app: .clawdBar)

    private var isDemo = false

    private var hasGrantedAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "hasGrantedAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "hasGrantedAccess") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = hasGrantedAccess ? "––" : "🐾"
        panel = MenuBarPanelController(statusItem: statusItem)
        panel.onOpen = { [weak self] in self?.refreshIfStale() }

        fetcher.$usage.receive(on: RunLoop.main).sink { [weak self] (_: UsageData) in
            self?.updateStatusTitle()
        }.store(in: &cancellables)
        // The panel fits its content; an error card appearing or clearing changes it.
        // The menu bar figures go grey while checks are failing.
        fetcher.$lastError.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.panel.fitToContent()
                self?.updateStatusTitle()
            }
        }.store(in: &cancellables)

        // Don't read the Keychain or call the API when launched as a unit-test host
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        #if DEBUG
        // `-demo YES` shows sample usage without touching the Keychain or the API,
        // for checking the UI. `-demoError YES` adds an error, `-demoLogin YES`
        // opens the login sheet, and `-demoWeekly 0.71` sets the weekly figure
        // to try the forecast's states.
        if UserDefaults.standard.bool(forKey: "demo") { startDemo(); return }
        #endif

        if hasGrantedAccess {
            setupUsagePanel()
            fetcher.start()
            Task { await selfUpdater.checkSilent() }
        } else {
            setupWelcomePanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.open() }
        }
    }

    // MARK: - Status title

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        // Before access is granted there's no usage yet; keep the paw
        guard hasGrantedAccess || isDemo else { button.title = "🐾"; return }
        // While checks are failing the last figures may be out of date, so grey them
        let stale = fetcher.lastError != nil
        let s = fetcher.usage.session5h.map { "\(Int($0 * 100))%" } ?? "–"
        let w = fetcher.usage.weekly7d.map { "\(Int($0 * 100))%" } ?? "–"

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: s, attributes: [.foregroundColor: stale ? .secondaryLabelColor : usageColor(fetcher.usage.session5h ?? 0)]))
        attr.append(NSAttributedString(string: " · "))
        attr.append(NSAttributedString(string: w, attributes: [.foregroundColor: stale ? .secondaryLabelColor : usageColor(fetcher.usage.weekly7d ?? 0)]))
        button.attributedTitle = attr
        button.toolTip = stale ? "ClawdBar can't reach your usage right now. These figures may be out of date." : nil
    }

    private func usageColor(_ ratio: Double) -> NSColor {
        switch ratio {
        case ..<0.5:  return .systemGreen
        case ..<0.8:  return .systemOrange
        default:      return .systemRed
        }
    }

    // MARK: - Panel

    private func setupWelcomePanel() {
        panel.setContent(resizable: false) {
            WelcomeView { [weak self] in self?.grantAccess() }
        }
    }

    private func setupUsagePanel() {
        panel.setContent {
            MenuBarView()
                .environmentObject(fetcher)
                .environmentObject(selfUpdater)
        }
    }

    /// Fresh numbers on open if the last refresh is more than 30 seconds old
    private func refreshIfStale() {
        if hasGrantedAccess, !fetcher.isLoading,
           (fetcher.lastUpdated.map { Date().timeIntervalSince($0) > 30 } ?? true) {
            Task { await fetcher.refresh() }
        }
    }

    private func grantAccess() {
        hasGrantedAccess = true
        panel.close()
        setupUsagePanel()
        statusItem.button?.title = "––"
        fetcher.start()
        Task { await selfUpdater.checkSilent() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.panel.open() }
    }

    #if DEBUG
    private func startDemo() {
        isDemo = true
        setupUsagePanel()
        let weekly = UserDefaults.standard.double(forKey: "demoWeekly")
        fetcher.usage = UsageData(session5h: 0.42, session5hReset: Date().addingTimeInterval(2 * 3600 + 15 * 60),
                                  weekly7d: weekly > 0 ? weekly : 0.27,
                                  weekly7dReset: Date().addingTimeInterval(3 * 86400 + 5 * 3600),
                                  status: "allowed")
        fetcher.lastUpdated = Date()
        if UserDefaults.standard.bool(forKey: "demoError") {
            fetcher.lastError = "Claude credentials were rejected — try signing in again via Claude Code"
        }
        updateStatusTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.panel.open()
            if UserDefaults.standard.bool(forKey: "demoLogin") { ClaudeAuth.shared.awaitingCode = true }
        }
    }
    #endif
}
