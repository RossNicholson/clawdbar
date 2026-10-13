import SwiftUI

struct WelcomeView: View {
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Mascot(size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hi, I'm ClawdBar")
                        .font(.display(28, relativeTo: .largeTitle))
                        .textCase(.uppercase)
                        .foregroundStyle(AppColors.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your Claude Code limits, always in view")
                        .font(.mono(10))
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 4)

            infoCard(title: "How it works", fill: AppColors.periwinkle,
                     text: "ClawdBar reads the Claude Code sign-in saved in your Mac's Keychain, then asks Anthropic how much of your 5-hour and 7-day limits you've used. Your sign-in stays in your Keychain and is only ever sent to Anthropic.")
            infoCard(title: "You'll need", fill: AppColors.butter,
                     text: "Claude Code installed and signed in, on a Pro or Max plan. macOS asks you to allow Keychain access the first time.")

            ColorBlockButton(title: "Allow access & continue", detail: "You can revoke access in Keychain Access at any time",
                             fill: AppColors.mint, symbol: "arrow.right") {
                onAllow()
            }
            .padding(.top, 2)
        }
        .popoverChrome(width: 300)
    }

    private func infoCard(title: String, fill: Color, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.display(17, relativeTo: .headline))
                .textCase(.uppercase)
            Text(text)
                .font(.mono(9.5))
                .opacity(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppColors.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
