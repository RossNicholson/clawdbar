import SwiftUI

struct SettingsView: View {
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

            Text("Nothing here yet — coming soon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 220)
    }
}
