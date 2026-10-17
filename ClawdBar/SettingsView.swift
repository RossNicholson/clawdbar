import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var fetcher: UsageFetcher
    @EnvironmentObject var selfUpdater: SelfUpdater
    @ObservedObject private var auth = ClaudeAuth.shared
    @Environment(\.dismiss) private var dismiss

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var loginItemError: String? = nil
    @State private var notificationError: String? = nil
    @AppStorage("notifyEnabled") private var notifyEnabled = false
    @AppStorage("notifyThresholdPercent") private var notifyThresholdPercent = 80
    @AppStorage("refreshInterval") private var refreshInterval = 60.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Settings", subtitle: "ClawdBar preferences")
                .padding(.bottom, 4)

            SettingToggle(title: "Usage alerts", detail: "Notify me when a limit passes \(notifyThresholdPercent)%",
                          isOn: Binding(get: { notifyEnabled }, set: { setNotifications($0) })) {
                if let notificationError {
                    SettingNote(notificationError)
                }
                if notifyEnabled {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(notifyThresholdPercent) },
                                set: { notifyThresholdPercent = Int($0.rounded()) }
                            ),
                            in: 50...95, step: 5
                        )
                        .tint(AppColors.toggle)
                        Text("\(notifyThresholdPercent)%")
                            .font(.display(20, relativeTo: .headline))
                            .monospacedDigit()
                            .foregroundStyle(AppColors.text)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            SettingCard(title: "Refresh every", detail: "How often ClawdBar checks your usage", below: {
                PillPicker(selection: $refreshInterval, options: [30.0, 60.0, 300.0], track: AppColors.ground) {
                    switch $0 {
                    case 30: return "30 sec"
                    case 60: return "1 min"
                    default: return "5 min"
                    }
                }
                .onChange(of: refreshInterval) { interval in
                    fetcher.setRefreshInterval(interval)
                }
            })

            SettingToggle(title: "Launch at login", detail: "Start ClawdBar when you log in",
                          isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                if let loginItemError {
                    SettingNote(loginItemError)
                }
            }

            SettingCard(title: "Claude account", detail: accountStatus, trailing: {
                Button {
                    if auth.isLoggedIn {
                        auth.logout()
                        fetcher.resetCredentials()
                        Task { await fetcher.refresh() }
                    } else {
                        dismiss()          // close this popover so the login sheet can show
                        auth.beginLogin()
                    }
                } label: {
                    Text(auth.isLoggedIn ? "Log out" : "Log in")
                        .font(.mono(10, weight: .semibold))
                        .foregroundStyle(auth.isLoggedIn ? AppColors.ink : AppColors.onSolid)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        // Solid inverts in dark mode, so the button stays visible on a dark card
                        .background(auth.isLoggedIn ? AppColors.peach : AppColors.solid, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            })

            UpdateBlock(updater: selfUpdater, app: .clawdBar)
        }
        .popoverChrome(width: 280)
    }

    private var accountStatus: String {
        if auth.isLoggedIn { return "Signed in with ClawdBar's own login" }
        if auth.signInExpired && fetcher.lastError == nil {
            return "ClawdBar's own sign-in expired, so it's using Claude Code's. Log in to make it independent again."
        }
        if fetcher.lastError == nil && fetcher.lastUpdated != nil {
            return "Using Claude Code's sign-in. Log in to make ClawdBar independent of it."
        }
        return "Not signed in"
    }

    private func setNotifications(_ enabled: Bool) {
        notificationError = nil
        guard enabled else { notifyEnabled = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                notifyEnabled = granted
                if !granted { notificationError = "Allow ClawdBar in System Settings → Notifications." }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if enabled && status == .requiresApproval {
            loginItemError = "Allow ClawdBar in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
