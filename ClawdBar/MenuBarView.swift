import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var fetcher: UsageFetcher
    @EnvironmentObject var selfUpdater: SelfUpdater
    @ObservedObject private var auth = ClaudeAuth.shared
    @State private var now = Date()
    @State private var showingSettings = false
    @State private var showingAbout = false

    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 8) {
                UsageCard(title: "5-hour session",
                          ratio: fetcher.usage.session5h,
                          resetDate: fetcher.usage.session5hReset,
                          now: now)
                UsageCard(title: "7-day weekly",
                          ratio: fetcher.usage.weekly7d,
                          resetDate: fetcher.usage.weekly7dReset,
                          now: now,
                          forecast: UsageParse.weeklyForecast(used: fetcher.usage.weekly7d,
                                                              reset: fetcher.usage.weekly7dReset,
                                                              now: now))
                if let err = fetcher.lastError {
                    errorCard(err)
                }
            }
            .padding(.horizontal, PanelMetrics.inset)
            .padding(.bottom, 12)
            // When the panel is made bigger, the extra room goes here
            Spacer(minLength: 0)
            footer
        }
        .menuBarPanel()
        .onReceive(timer) { now = $0 }
        .sheet(isPresented: $auth.awaitingCode) {
            LoginCodeView {
                fetcher.resetCredentials()
                Task { await fetcher.refresh() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        PanelHeader(title: "ClawdBar", subtitle: "Claude Code usage") {
            Mascot(size: PanelMetrics.mascot)
        } actions: {
            HeaderRefreshButton(isRefreshing: fetcher.isLoading) {
                Task { await fetcher.refresh() }
            }
            HeaderIconButton(symbol: "gearshape", help: "Settings") {
                showingSettings.toggle()
            }
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsView()
                    .environmentObject(fetcher)
                    .environmentObject(selfUpdater)
            }
            HeaderIconButton(symbol: "info", help: "About & help") {
                showingAbout.toggle()
            }
            .popover(isPresented: $showingAbout, arrowEdge: .bottom) {
                AboutPopover(app: .clawdBar) { Mascot(size: 56) }
            }
        }
    }

    // MARK: - Error

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 1)
            Text(message)
                .font(.mono(10))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !auth.isLoggedIn {
                Button { auth.beginLogin() } label: {
                    Text("Log in")
                        .font(.mono(10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AppColors.ink, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .foregroundStyle(AppColors.ink)
        .padding(12)
        .background(AppColors.coral, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        PanelFooter {
            if let updated = fetcher.lastUpdated {
                Text("Updated \(updated, style: .relative) ago")
            } else if fetcher.lastError == nil {
                Text("Loading…")
            } else {
                Text("Couldn't load usage")
            }
        }
    }
}

/// One usage limit as a colour block: mint when there's plenty left, butter
/// from 50%, peach from 80%. Text is always ink on the pastel.
struct UsageCard: View {
    let title: String
    let ratio: Double?
    let resetDate: Date?
    let now: Date
    var forecast: WeeklyForecast? = nil

    static func fill(for ratio: Double?) -> Color {
        guard let ratio else { return AppColors.surface }
        switch ratio {
        case ..<0.5: return AppColors.mint
        case ..<0.8: return AppColors.butter
        default: return AppColors.peach
        }
    }

    var body: some View {
        let ink = ratio == nil ? AppColors.text : AppColors.ink
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.display(19, relativeTo: .headline))
                        .textCase(.uppercase)
                    Text(subtitle)
                        .font(.mono(9.5))
                        .opacity(0.7)
                }
                Spacer()
                Text(ratio.map { "\(Int($0 * 100))%" } ?? "–")
                    .font(.display(42, relativeTo: .largeTitle))
                    .monospacedDigit()
            }
            if let forecast {
                forecastBar(forecast, ink: ink)
                forecastVerdict(forecast)
            } else {
                GeometryReader { geo in
                    bar(width: geo.size.width, ink: ink)
                }
                .frame(height: 8)
            }
        }
        .foregroundStyle(ink)
        .padding(14)
        .background(Self.fill(for: ratio), in: RoundedRectangle(cornerRadius: Radius.block, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .id(now)   // re-render the countdown when the 30-second timer ticks
    }

    private var subtitle: String {
        guard let resetDate else { return "Waiting for data" }
        let resets = "Resets in \(formatTimeRemaining(until: resetDate))"
        return forecast.map { "\(resets)\n\($0.paceText)" } ?? resets
    }

    private var accessibilityValue: String {
        guard let ratio else { return "no data yet" }
        var text = "\(Int(ratio * 100)) percent used"
        if let resetDate { text += ", resets in \(formatTimeRemaining(until: resetDate))" }
        if let forecast { text += ". \(forecast.message(now: now)), \(forecast.ghostLabel), \(forecast.paceText)" }
        return text
    }

    /// The usage bar. With a forecast, a striped ghost runs on to where usage
    /// will be at reset at this pace.
    private func bar(width: CGFloat, ink: Color, forecast: WeeklyForecast? = nil) -> some View {
        let used = max(8, width * min(1, ratio ?? 0))
        return ZStack(alignment: .leading) {
            Capsule().fill(ink.opacity(0.14))
            if let forecast {
                // Starts under the fill's rounded end so there's no gap
                Stripes(color: ink.opacity(0.42))
                    .frame(width: max(0, width * min(1, forecast.projectedAtReset) - used + 4))
                    .offset(x: used - 4)
            }
            Capsule().fill(ink)
                .frame(width: used)
                .opacity(ratio == nil ? 0 : 1)
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .animation(.easeInOut, value: ratio)
    }

    /// The bar plus a tick and a label where the ghost ends
    private func forecastBar(_ forecast: WeeklyForecast, ink: Color) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let end = width * min(1, forecast.projectedAtReset)
            ZStack(alignment: .topLeading) {
                Text(forecast.ghostLabel)
                    .font(.mono(8.5, weight: .semibold))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize()
                    // Centred on the tick, but kept inside the card at either end
                    .alignmentGuide(.leading) { d in -min(width - d.width, max(0, end - d.width / 2)) }
                bar(width: width, ink: ink, forecast: forecast)
                    .offset(y: 18)
                Rectangle().fill(ink)
                    .frame(width: 2, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                    .offset(x: min(width - 2, max(0, end - 1)), y: 14)
            }
        }
        .frame(height: 30)
    }

    private func forecastVerdict(_ forecast: WeeklyForecast) -> some View {
        let runsOut = forecast.verdict == .runsOut
        return HStack(spacing: 7) {
            TagPill(text: forecast.tag,
                    fill: runsOut ? AppColors.coral : AppColors.ink,
                    foreground: runsOut ? AppColors.ink : Self.fill(for: ratio))
            Text(forecast.message(now: now))
                .font(.mono(10))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
        .help("At this pace: \(forecast.ghostLabel.lowercased()). Based on your average use since the week began.")
    }
}

/// The forecast ghost: diagonal ink stripes
private struct Stripes: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }
}

/// Sheet shown after the browser opens for sign-in: the user pastes back the code.
struct LoginCodeView: View {
    @ObservedObject private var auth = ClaudeAuth.shared
    @State private var code = ""
    var onSuccess: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PopoverHeader(title: "Log in with Claude",
                              subtitle: "Your browser opened to authorise ClawdBar. Once you approve, copy the code it shows and paste it here.")
                Mascot(size: 48, disc: AppColors.periwinkle)
            }

            TextField("Paste the code", text: $code)
                .textFieldStyle(.plain)
                .font(.mono(12))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .disableAutocorrection(true)

            if let err = auth.loginError {
                Text(err)
                    .font(.mono(10))
                    .foregroundStyle(AppColors.ink)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.coral, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                GhostButton(title: "Cancel") { auth.cancelLogin() }
                Spacer()
                PillButton(title: auth.working ? "Checking…" : "Log in", symbol: "arrow.right") {
                    Task {
                        await auth.completeLogin(pasted: code)
                        if auth.isLoggedIn { onSuccess() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || auth.working)
                .opacity(code.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .popoverChrome(width: 360)
    }
}
