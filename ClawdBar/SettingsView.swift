import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var fetcher: UsageFetcher
    @EnvironmentObject var updater: UpdaterViewModel

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @AppStorage("notifyEnabled") private var notifyEnabled = false
    @AppStorage("notifyThresholdPercent") private var notifyThresholdPercent = 80
    @AppStorage("refreshInterval") private var refreshInterval = 60.0

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.title3).fontWeight(.semibold)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                updatesSection
                Divider()
                startupSection
                Divider()
                notificationsSection
                Divider()
                pollingSection
            }
        }
        .padding(20)
        .frame(width: 260)
    }

    // MARK: - Sections

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Updates", icon: "arrow.triangle.2.circlepath")

            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            .toggleStyle(.switch)
            .font(.callout)

            Button {
                updater.checkForUpdates()
            } label: {
                Label("Check for Updates Now", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .liquidGlassInteractive(in: Capsule())
            .disabled(!updater.canCheckForUpdates)
        }
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("General", icon: "macwindow")

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .font(.callout)
                .onChange(of: launchAtLogin) { enabled in
                    if enabled {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Notifications", icon: "bell.fill")

            Toggle("Alert when usage exceeds threshold", isOn: $notifyEnabled)
                .toggleStyle(.switch)
                .font(.callout)
                .onChange(of: notifyEnabled) { enabled in
                    if enabled { requestNotificationPermission() }
                }

            if notifyEnabled {
                HStack {
                    Text("Threshold")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(notifyThresholdPercent)%")
                        .font(.callout)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Slider(
                    value: Binding(
                        get: { Double(notifyThresholdPercent) },
                        set: { notifyThresholdPercent = Int($0.rounded()) }
                    ),
                    in: 50...95,
                    step: 5
                )
                .tint(.orange)
            }
        }
    }

    private var pollingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Polling", icon: "clock")

            HStack {
                Text("Refresh interval")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $refreshInterval) {
                    Text("30s").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .onChange(of: refreshInterval) { interval in
                    fetcher.setRefreshInterval(interval)
                }
            }
        }
    }

    // MARK: - Helpers

    private func label(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if !granted { notifyEnabled = false }
            }
        }
    }
}
