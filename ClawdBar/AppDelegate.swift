import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    let fetcher = UsageFetcher()
    let selfUpdater = SelfUpdater()

    private var isDemo = false

    private var hasGrantedAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "hasGrantedAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "hasGrantedAccess") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = hasGrantedAccess ? "––" : "🐾"
            button.action = #selector(togglePanel)
            button.target = self
        }

        fetcher.$usage.receive(on: RunLoop.main).sink { [weak self] (_: UsageData) in
            self?.updateStatusTitle()
        }.store(in: &cancellables)
        // The panel fits its content; an error card appearing or clearing changes it.
        // The menu bar figures go grey while checks are failing.
        fetcher.$lastError.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.fitPanelToContent()
                self?.updateStatusTitle()
            }
        }.store(in: &cancellables)

        // Don't read the Keychain or call the API when launched as a unit-test host
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        #if DEBUG
        // `-demo YES` shows sample usage without touching the Keychain or the API,
        // for checking the UI. `-demoError YES` adds an error, `-demoLogin YES`
        // opens the login sheet.
        if UserDefaults.standard.bool(forKey: "demo") { startDemo(); return }
        #endif

        if hasGrantedAccess {
            setupUsagePanel()
            fetcher.start()
            Task { await selfUpdater.checkSilent() }
        } else {
            setupWelcomePanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openPanel() }
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

    // MARK: - Panel setup

    private func makePanel(for content: NSView) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.delegate = self
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        return p
    }

    private func setupWelcomePanel() {
        let content = WelcomeView { [weak self] in
            self?.grantAccess()
        }
        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]
        panel = makePanel(for: hostingView)
        panel.contentView = hostingView
    }

    private func setupUsagePanel() {
        let content = MenuBarView()
            .environmentObject(fetcher)
            .environmentObject(selfUpdater)
        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]
        panel = makePanel(for: hostingView)
        panel.contentView = hostingView
    }

    private func grantAccess() {
        hasGrantedAccess = true
        closePanel()
        setupUsagePanel()
        statusItem.button?.title = "––"
        fetcher.start()
        Task { await selfUpdater.checkSilent() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.openPanel() }
    }

    #if DEBUG
    private func startDemo() {
        isDemo = true
        setupUsagePanel()
        fetcher.usage = UsageData(session5h: 0.42, session5hReset: Date().addingTimeInterval(2 * 3600 + 15 * 60),
                                  weekly7d: 0.27, weekly7dReset: Date().addingTimeInterval(3 * 86400 + 5 * 3600),
                                  status: "allowed")
        fetcher.lastUpdated = Date()
        if UserDefaults.standard.bool(forKey: "demoError") {
            fetcher.lastError = "Claude credentials were rejected — try signing in again via Claude Code"
        }
        updateStatusTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.openPanel()
            if UserDefaults.standard.bool(forKey: "demoLogin") { ClaudeAuth.shared.awaitingCode = true }
        }
    }
    #endif

    // MARK: - Panel show/hide

    @objc func togglePanel() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    /// Resize the panel to its SwiftUI content, keeping it hanging from the menu bar
    private func fitPanelToContent() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        guard size != panel.frame.size, size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)
        if panel.isVisible { positionPanel() }
    }

    private func openPanel() {
        fitPanelToContent()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        // Fresh numbers on open if the last refresh is more than 30 seconds old
        if hasGrantedAccess, !fetcher.isLoading,
           (fetcher.lastUpdated.map { Date().timeIntervalSince($0) > 30 } ?? true) {
            Task { await fetcher.refresh() }
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        guard let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        var x = screenRect.midX - panel.frame.width / 2
        let y = screenRect.minY - panel.frame.height

        x = min(max(x, screen.visibleFrame.minX + 4),
                screen.visibleFrame.maxX - panel.frame.width - 4)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Wait a tick for the new key window to settle, then stay open if it's
        // one of ours (the login code sheet or a popover): closing would hide
        // the sheet you're typing into. Clicking another app leaves us with no
        // key window, so the panel closes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if NSApp.modalWindow != nil || NSApp.keyWindow != nil { return }
            self.closePanel()
        }
    }
}
