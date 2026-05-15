import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var fetcher: UsageFetcher
    @EnvironmentObject var selfUpdater: SelfUpdater

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @AppStorage("notifyEnabled") private var notifyEnabled = false
    @AppStorage("notifyThresholdPercent") private var notifyThresholdPercent = 80
    @AppStorage("refreshInterval") private var refreshInterval = 60.0

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            VStack(spacing: 0) {
                if selfUpdater.updateAvailable {
                    row {
                        Button(selfUpdater.isUpdating ? "Updating…" : "Update ClawdBar…") {
                            Task { await selfUpdater.update() }
                        }
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .buttonStyle(.plain)
                        .disabled(selfUpdater.isUpdating)
                    }
                    divider()
                }

                row {
                    Button(selfUpdater.isChecking ? "Checking…" : "Check for updates") {
                        Task { await selfUpdater.check() }
                    }
                    .font(.caption)
                    .foregroundStyle(selfUpdater.isChecking ? Color.secondary : Color.blue)
                    .buttonStyle(.plain)
                    .disabled(selfUpdater.isChecking)
                }

                divider()

                row("Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { enabled in
                            if enabled {
                                try? SMAppService.mainApp.register()
                            } else {
                                try? SMAppService.mainApp.unregister()
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }

                divider()

                row("Usage alerts") {
                    Toggle("", isOn: $notifyEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: notifyEnabled) { enabled in
                            if enabled { requestNotificationPermission() }
                        }
                }

                row("Threshold") {
                    Text("\(notifyThresholdPercent)%")
                        .font(.callout)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(notifyEnabled ? .primary : .tertiary)
                }
                .foregroundStyle(notifyEnabled ? .primary : .tertiary)

                row {
                    Slider(
                        value: Binding(
                            get: { Double(notifyThresholdPercent) },
                            set: { notifyThresholdPercent = Int($0.rounded()) }
                        ),
                        in: 50...95, step: 5
                    )
                    .tint(.orange)
                    .disabled(!notifyEnabled)
                    .opacity(notifyEnabled ? 1 : 0.35)
                }

                divider()

                row("Refresh interval") {
                    Picker("", selection: $refreshInterval) {
                        Text("30s").tag(30.0)
                        Text("1m").tag(60.0)
                        Text("5m").tag(300.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .onChange(of: refreshInterval) { interval in
                        fetcher.setRefreshInterval(interval)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 260)
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func row<Control: View>(_ label: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            if let label {
                Text(label)
                    .font(.callout)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func divider() -> some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if !granted { notifyEnabled = false }
            }
        }
    }
}
