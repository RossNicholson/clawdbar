import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var eventMonitor: Any?
    /// An off-screen copy of the panel's content at its natural size, to
    /// measure how big the panel needs to be
    private var measure: NSView?
    /// Only the usage panel can be resized; the welcome panel fits its content
    private var panelIsResizable = false
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
            contentRect: NSRect(origin: .zero, size: measure?.fittingSize ?? content.fittingSize),
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
        let welcomeMeasure = NSHostingView(rootView: WelcomeView {})
        if #available(macOS 13.3, *) { welcomeMeasure.safeAreaRegions = [] }
        measure = welcomeMeasure
        panelIsResizable = false
        panel = makePanel(for: hostingView)
        install(hostingView, in: panel)
    }

    private func setupUsagePanel() {
        let content = MenuBarView(onResized: { size in
            UserDefaults.standard.set(NSStringFromSize(size), forKey: "panelSize")
        })
            .environmentObject(fetcher)
            .environmentObject(selfUpdater)
        let hostingView = NSHostingView(rootView: content)
        let usageMeasure = NSHostingView(rootView: MenuBarView(flexible: false)
            .environmentObject(fetcher)
            .environmentObject(selfUpdater))
        if #available(macOS 13.3, *) { usageMeasure.safeAreaRegions = [] }
        measure = usageMeasure
        panelIsResizable = true
        panel = makePanel(for: hostingView)
        install(hostingView, in: panel)
    }

    /// The SwiftUI view goes inside a plain container rather than being the
    /// panel's own content view: as the content view, SwiftUI sizes the window
    /// from its content, which fights the resize grip and loops.
    private func install<V: View>(_ hostingView: NSHostingView<V>, in panel: NSPanel) {
        hostingView.sizingOptions = []
        // The panel's title bar is hidden; don't leave a gap for it
        if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container
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
    /// Size the panel to its content, or to the size you dragged it to if
    /// that's bigger, keeping it hanging from the menu bar. It can't be made
    /// smaller than its content.
    private func fitPanelToContent() {
        guard let panel, let measure else { return }
        let fit = measure.fittingSize
        guard fit.width > 0, fit.height > 0 else { return }
        panel.minSize = fit
        let saved = panelIsResizable
            ? (UserDefaults.standard.string(forKey: "panelSize").map(NSSizeFromString) ?? .zero) : .zero
        let size = NSSize(width: max(fit.width, saved.width), height: max(fit.height, saved.height))
        guard size != panel.frame.size else { return }
        if panel.isVisible {
            let frame = panel.frame
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                           display: true)
        } else {
            panel.setContentSize(size)
        }
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
        // Clicks on our own menu bar figures arrive here too; leave those to togglePanel
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.mouseIsOverStatusItem else { return }
            self.closePanel()
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
            // A click on the menu bar figures is togglePanel's to handle; closing
            // here would make that click reopen the panel straight away.
            if self.mouseIsOverStatusItem { return }
            self.closePanel()
        }
    }

    private var mouseIsOverStatusItem: Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.contains(NSEvent.mouseLocation)
    }
}
