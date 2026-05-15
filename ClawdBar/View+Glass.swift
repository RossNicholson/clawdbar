import SwiftUI

extension View {
    @ViewBuilder
    func liquidGlassBackground(in shape: some Shape = Rectangle()) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.regularMaterial))
        }
    }

    @ViewBuilder
    func liquidGlassInteractive(in shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}
