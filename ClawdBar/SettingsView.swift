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
    @State private var checkedUpToDate = false
    @State private var notificationError: String? = nil
    @AppStorage("notifyEnabled") private var notifyEnabled = false
    @AppStorage("notifyThresholdPercent") private var notifyThresholdPercent = 80
    @AppStorage("refreshInterval") private var refreshInterval = 60.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PopoverHeader(title: "Settings", subtitle: "ClawdBar preferences")
                .padding(.bottom, 4)

            // Usage alerts
            VStack(alignment: .leading, spacing: 10) {
                settingToggle("Usage alerts", detail: "Notify me when a limit passes \(notifyThresholdPercent)%",
                              isOn: Binding(get: { notifyEnabled }, set: { setNotifications($0) }))
                if let notificationError {
                    Text(notificationError)
                        .font(.mono(9.5))
                        .foregroundStyle(AppColors.destructive)
                        .fixedSize(horizontal: false, vertical: true)
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
            .padding(12)
            .card()

            // Refresh interval
            VStack(alignment: .leading, spacing: 8) {
                settingLabel("Refresh every", detail: "How often ClawdBar checks your usage")
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("30 sec").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: refreshInterval) { interval in
                    fetcher.setRefreshInterval(interval)
                }
            }
            .padding(12)
            .card()

            // Launch at login
            VStack(alignment: .leading, spacing: 6) {
                settingToggle("Launch at login", detail: "Start ClawdBar when you log in",
                              isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.mono(9.5))
                        .foregroundStyle(AppColors.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .card()

            // Claude account
            HStack(alignment: .center, spacing: 10) {
                settingLabel("Claude account", detail: accountStatus)
                Spacer(minLength: 4)
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
            }
            .padding(12)
            .card()

            // Updates
            if selfUpdater.updateAvailable {
                ColorBlockButton(
                    title: selfUpdater.isUpdating ? "Updating…" : "Update ClawdBar",
                    detail: "A new version is ready. ClawdBar will restart.",
                    fill: AppColors.peach, symbol: "arrow.up"
                ) {
                    Task { await selfUpdater.update() }
                }
                .disabled(selfUpdater.isUpdating)
            } else {
                ColorBlockButton(
                    title: selfUpdater.isChecking ? "Checking…" : "Check for updates",
                    detail: checkedUpToDate ? "ClawdBar is up to date." : "See if a new version of ClawdBar is out",
                    fill: checkedUpToDate ? AppColors.mint : AppColors.butter,
                    symbol: checkedUpToDate ? "checkmark" : "arrow.clockwise"
                ) {
                    checkedUpToDate = false
                    Task {
                        await selfUpdater.check()
                        checkedUpToDate = !selfUpdater.updateAvailable
                    }
                }
                .disabled(selfUpdater.isChecking)
            }
        }
        .popoverChrome(width: 280)
    }

    // MARK: - Pieces

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.display(17, relativeTo: .headline))
                .textCase(.uppercase)
                .foregroundStyle(AppColors.text)
            Text(detail)
                .font(.mono(9.5))
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            settingLabel(title, detail: detail)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(AppColors.toggle)
    }

    private var accountStatus: String {
        if auth.isLoggedIn { return "Signed in with ClawdBar's own login" }
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
