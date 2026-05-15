import SwiftUI

struct WelcomeView: View {
    let onAllow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            content
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 280)
        .liquidGlassBackground(in: Rectangle())
    }

    private var header: some View {
        HStack {
            Image(systemName: "pawprint.fill")
                .foregroundStyle(.purple)
                .font(.subheadline)
            Text("ClawdBar")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ClawdBar shows your **Claude Code** 5-hour and 7-day usage limits in the menu bar.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("How it works", systemImage: "key.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("To fetch your usage, ClawdBar reads your **Claude Code session credentials** from your macOS Keychain — the same entry the Claude Code CLI uses. No credentials are stored or transmitted beyond Anthropic's API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Requirements", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("Claude Code must be installed and signed in. macOS will ask you to approve Keychain access the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        Button {
            onAllow()
        } label: {
            Text("Allow Access & Continue")
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.purple)
        .liquidGlassInteractive(in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }
}
