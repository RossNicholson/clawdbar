import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var fetcher: UsageFetcher
    @State private var now = Date()
    @State private var showingSettings = false
    @State private var showingHelp = false
    @State private var showingAbout = false

    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(dividerOpacity)
            usageRow(
                label: "5h Session",
                ratio: fetcher.usage.session5h,
                resetDate: fetcher.usage.session5hReset,
                now: now
            )
            Divider().opacity(dividerOpacity)
            usageRow(
                label: "7d Weekly",
                ratio: fetcher.usage.weekly7d,
                resetDate: fetcher.usage.weekly7dReset,
                now: now
            )
            Divider().opacity(dividerOpacity)
            footer
        }
        .frame(width: 280)
        .liquidGlassBackground(in: Rectangle())
        .onReceive(timer) { now = $0 }
    }

    private var dividerOpacity: Double {
        if #available(macOS 26, *) { return 0.25 }
        return 1.0
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "pawprint.fill")
                .foregroundStyle(.purple)
                .font(.subheadline)
            Text("ClawdBar")
                .font(.headline)
            Spacer()
            if fetcher.isLoading {
                ProgressView().scaleEffect(0.6)
            } else {
                refreshButton
            }
            helpButton
            aboutButton
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Usage rows

    private func usageRow(label: String, ratio: Double?, resetDate: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ratio.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(ratio.map { usageColor($0) } ?? .secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ratio.map { usageColor($0) } ?? .secondary)
                        .frame(width: geo.size.width * (ratio ?? 0), height: 6)
                        .animation(.easeInOut, value: ratio)
                }
            }
            .frame(height: 6)

            if let reset = resetDate {
                Text("Resets in \(formatTimeRemaining(until: reset))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func usageColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.5:  return .green
        case ..<0.8:  return .orange
        default:      return .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let err = fetcher.lastError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption2)
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let updated = fetcher.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Loading…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Header buttons

    private var refreshButton: some View {
        Button {
            Task { await fetcher.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.footnote)
                .padding(6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .liquidGlassInteractive(in: Circle())
    }

    private var helpButton: some View {
        Button { showingHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.footnote)
                .padding(6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .liquidGlassInteractive(in: Circle())
        .popover(isPresented: $showingHelp, arrowEdge: .top) {
            helpView
        }
    }

    private var aboutButton: some View {
        Button { showingAbout.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .padding(6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .liquidGlassInteractive(in: Circle())
        .popover(isPresented: $showingAbout, arrowEdge: .top) {
            aboutView
        }
    }

    private var settingsButton: some View {
        Button { showingSettings.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.footnote)
                .padding(6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .liquidGlassInteractive(in: Circle())
        .popover(isPresented: $showingSettings, arrowEdge: .top) {
            SettingsView()
        }
    }

    // MARK: - Help popover

    private var helpView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "lifepreserver")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("Help & Support")
                    .font(.title3).fontWeight(.semibold)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Found a bug or need help? Visit the support page or drop us an email — we read everything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Feature requests and feedback are always welcome too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Link(destination: URL(string: "https://rossnicholson.dev/support")!) {
                    Label("Support Page", systemImage: "globe")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .liquidGlassInteractive(in: Capsule())

                Link(destination: URL(string: "mailto:support@rossnicholson.dev")!) {
                    Label("support@rossnicholson.dev", systemImage: "envelope")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .liquidGlassInteractive(in: Capsule())
            }
        }
        .padding(20)
        .frame(width: 240)
    }

    // MARK: - About popover

    private var aboutView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.purple)
                Text("ClawdBar")
                    .font(.title3).fontWeight(.semibold)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 8) {
                Text("Made by Ross Nicholson")
                    .font(.subheadline)
                Link("rossnicholson.dev", destination: URL(string: "https://rossnicholson.dev")!)
                    .font(.caption)
                Link(destination: URL(string: "https://github.com/RossNicholson/clawdbar")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                }
            }

            Divider()

            VStack(spacing: 4) {
                Text("If you find ClawdBar helpful:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://buymeacoffee.com/rossnicholson")!) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .liquidGlassInteractive(in: Capsule())
            }

            Divider()

            HStack(spacing: 12) {
                Link("Terms & Conditions", destination: URL(string: "https://rossnicholson.dev/terms")!)
                Text("·").foregroundStyle(.tertiary)
                Link("Privacy Policy", destination: URL(string: "https://rossnicholson.dev/privacy")!)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 220)
    }
}
