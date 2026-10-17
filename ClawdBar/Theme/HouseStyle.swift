// The shared look (colours, fonts, buttons, cards, the menu bar panel and the
// updater) lives in the HouseStyle package, shared with Ross's other Mac apps.
// Re-exported so every file here can use it without its own import.
@_exported import HouseStyle

extension AppInfo {
    static let clawdBar = AppInfo(name: "ClawdBar", repo: "clawdbar", cask: "clawdbar",
                                  coffeeLine: "If ClawdBar helps you pace your day")
}
