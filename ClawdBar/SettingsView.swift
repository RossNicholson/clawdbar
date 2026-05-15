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
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            VStack(spacing: 0) {
                settingsRow {
                    sectionLabel("Updates", icon: "arrow.triangle.2.circlepath")
                }

                settingsRow {
                    Toggle("Auto-update", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .toggleStyle(.switch)
                    .font(.callout)
                }

                settingsRow {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Check for Updates Now", systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(updater.canCheckForUpdates ? .blue : .secondary)
                    .disabled(!updater.canCheckForUpdates)
                }

                Divider().padding(.vertical, 4)

                settingsRow {
                    sectionLabel("General", icon: "macwindow")
                }

                settingsRow {
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

                Divider().padding(.vertical, 4)

                settingsRow {
                    sectionLabel("Notifications", icon: "bell.fill")
                }

                settingsRow {
                    Toggle("Alert on high usage", isOn: $notifyEnabled)
                        .toggleStyle(.switch)
                        .font(.callout)
                        .onChange(of: notifyEnabled) { enabled in
                            if enabled { requestNotificationPermission() }
                        }
                }

                settingsRow {
                    HStack {
                        Text("Threshold")
                            .font(.callout)
                            .foregroundStyle(notifyEnabled ? .primary : .tertiary)
                        Spacer()
                        Text("\(notifyThresholdPercent)%")
                            .font(.callout)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(notifyEnabled ? .primary : .tertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                settingsRow {
                    Slider(
                        value: Binding(
                            get: { Double(notifyThresholdPercent) },
                            set: { notifyThresholdPercent = Int($0.rounded()) }
                        ),
                        in: 50...95,
                        step: 5
                    )
                    .tint(.orange)
                    .disabled(!notifyEnabled)
                    .opacity(notifyEnabled ? 1 : 0.35)
                }

                Divider().padding(.vertical, 4)

                settingsRow {
                    sectionLabel("Refresh", icon: "clock")
                }

                settingsRow {
                    HStack {
                        Text("Interval")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $refreshInterval) {
                            Text("30s").tag(30.0)
                            Text("1 min").tag(60.0)
                            Text("5 min").tag(300.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 126)
                        .onChange(of: refreshInterval) { interval in
                            fetcher.setRefreshInterval(interval)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 260)
    }

    // MARK: - Helpers

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
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
