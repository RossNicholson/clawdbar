import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var eventMonitor: Any?
    let fetcher = UsageFetcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "––"
            button.action = #selector(togglePanel)
            button.target = self
        }

        setupPanel()
        fetcher.$usage.receive(on: RunLoop.main).sink { [weak self] (_: UsageData) in
            self?.updateStatusTitle()
        }.store(in: &cancellables)
        fetcher.start()
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let s = fetcher.usage.session5h.map { "\(Int($0 * 100))%" } ?? "–"
        let w = fetcher.usage.weekly7d.map { "\(Int($0 * 100))%" } ?? "–"

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: s, attributes: [
            .foregroundColor: usageColor(fetcher.usage.session5h ?? 0)
        ]))
        attr.append(NSAttributedString(string: " · "))
        attr.append(NSAttributedString(string: w, attributes: [
            .foregroundColor: usageColor(fetcher.usage.weekly7d ?? 0)
        ]))
        button.attributedTitle = attr
    }

    private func usageColor(_ ratio: Double) -> NSColor {
        switch ratio {
        case ..<0.5:  return .systemGreen
        case ..<0.8:  return .systemOrange
        default:      return .systemRed
        }
    }

    private func setupPanel() {
        let content = MenuBarView().environmentObject(fetcher)
        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    @objc func togglePanel() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
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
        closePanel()
    }
}
