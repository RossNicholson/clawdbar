import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var fetcher: UsageFetcher
    @State private var now = Date()

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
                Button {
                    Task { await fetcher.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .liquidGlassInteractive(in: Circle())
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
