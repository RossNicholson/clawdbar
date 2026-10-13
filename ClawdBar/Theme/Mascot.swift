import SwiftUI

/// ClawdBar's mascot: a cat raising a paw (toe beans and all), in the
/// rubber-hose cartoon style of BrewDock's mug and the Don't Worry and Word
/// Slip characters: thick ink outlines, pastel fills, big eyes. Drawn on a
/// pastel disc so it reads in dark mode too.
struct Mascot: View {
    enum Mood { case happy, sleepy }

    var mood: Mood = .happy
    var size: CGFloat = 72
    var disc: Color = AppColors.mint

    private static let ink = Color(hex: 0x232428)
    private static let fur = Color(hex: 0xC3C7F6)        // periwinkle
    private static let furShade = Color(hex: 0xA9AEEB)
    private static let innerEar = Color(hex: 0xF6C3B4)   // peach
    private static let sclera = Color(hex: 0xFBF6E9)
    private static let blush = Color(hex: 0xF6C3B4)
    private static let bean = Color(hex: 0xEE9C86)       // coral

    var body: some View {
        Canvas { context, canvasSize in
            // Draw in a 100×100 space
            let scale = min(canvasSize.width, canvasSize.height) / 100
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
        .frame(width: size, height: size)
        .background(disc, in: Circle())
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext) {
        let ink = Self.ink
        let outline = StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)

        // Ears, behind the head
        for (outer, tip, inner) in [((29.0, 47.0), (32.0, 17.0), (50.0, 33.0)),
                                    ((50.0, 33.0), (68.0, 17.0), (71.0, 47.0))] {
            var ear = Path()
            ear.move(to: CGPoint(x: outer.0, y: outer.1))
            ear.addQuadCurve(to: CGPoint(x: tip.0, y: tip.1), control: CGPoint(x: (outer.0 + tip.0) / 2 - (tip.0 < 50 ? 3 : -3), y: (outer.1 + tip.1) / 2))
            ear.addQuadCurve(to: CGPoint(x: inner.0, y: inner.1), control: CGPoint(x: (tip.0 + inner.0) / 2, y: (tip.1 + inner.1) / 2 - 2))
            ear.closeSubpath()
            context.fill(ear, with: .color(Self.fur))
            context.stroke(ear, with: .color(ink), style: outline)
            // Inner ear
            let cx = tip.0 < 50 ? 36.0 : 64.0
            var innerEar = Path()
            innerEar.move(to: CGPoint(x: cx - 5, y: 36))
            innerEar.addLine(to: CGPoint(x: tip.0 < 50 ? cx - 2 : cx + 2, y: 25))
            innerEar.addLine(to: CGPoint(x: cx + 5, y: 34))
            innerEar.closeSubpath()
            context.fill(innerEar, with: .color(Self.innerEar))
        }

        // Head
        let head = Path(ellipseIn: CGRect(x: 23, y: 29, width: 56, height: 52))
        context.fill(head, with: .color(Self.fur))
        context.drawLayer { layer in
            layer.clip(to: head)
            layer.fill(Path(ellipseIn: CGRect(x: 60, y: 26, width: 30, height: 60)), with: .color(Self.furShade))
        }
        context.stroke(head, with: .color(ink), style: outline)

        // Whiskers
        for (from, to) in [((28.0, 63.0), (20.0, 61.5)), ((28.0, 67.0), (20.0, 68.5)),
                           ((74.0, 63.0), (88.0, 60.0)), ((74.0, 67.0), (88.0, 69.0))] {
            var whisker = Path()
            whisker.move(to: CGPoint(x: from.0, y: from.1))
            whisker.addLine(to: CGPoint(x: to.0, y: to.1))
            context.stroke(whisker, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }

        // Cheeks
        for x in [30.0, 63.0] {
            context.fill(Path(ellipseIn: CGRect(x: x, y: 64, width: 9, height: 5)), with: .color(Self.blush))
        }

        // Eyes
        for x in [36.0, 54.0] {
            switch mood {
            case .happy:
                let eye = Path(ellipseIn: CGRect(x: x, y: 44, width: 12, height: 15))
                context.fill(eye, with: .color(Self.sclera))
                context.stroke(eye, with: .color(ink), lineWidth: 2.2)
                context.fill(Path(ellipseIn: CGRect(x: x + 3.5, y: 48.5, width: 7, height: 9)), with: .color(ink))
                context.fill(Path(ellipseIn: CGRect(x: x + 4.8, y: 49.6, width: 2.6, height: 2.6)), with: .color(.white))
            case .sleepy:
                var lid = Path()
                lid.move(to: CGPoint(x: x + 1, y: 52))
                lid.addQuadCurve(to: CGPoint(x: x + 11, y: 52), control: CGPoint(x: x + 6, y: 57))
                context.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }

        // Nose and "w" mouth
        var nose = Path()
        nose.move(to: CGPoint(x: 48, y: 62))
        nose.addLine(to: CGPoint(x: 54, y: 62))
        nose.addLine(to: CGPoint(x: 51, y: 65.5))
        nose.closeSubpath()
        context.fill(nose, with: .color(Self.bean))
        context.stroke(nose, with: .color(ink), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        var mouth = Path()
        mouth.move(to: CGPoint(x: 45.5, y: 67))
        mouth.addQuadCurve(to: CGPoint(x: 51, y: 67), control: CGPoint(x: 48.2, y: 71.5))
        mouth.addQuadCurve(to: CGPoint(x: 56.5, y: 67), control: CGPoint(x: 53.8, y: 71.5))
        context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))

        // Raised paw on a rubber-hose arm, showing its toe beans
        var arm = Path()
        arm.move(to: CGPoint(x: 27, y: 74))
        arm.addCurve(to: CGPoint(x: 17, y: 44),
                     control1: CGPoint(x: 17, y: 76),
                     control2: CGPoint(x: 13, y: 58))
        context.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        let paw = Path(ellipseIn: CGRect(x: 7, y: 26, width: 20, height: 19))
        context.fill(paw, with: .color(Self.fur))
        context.stroke(paw, with: .color(ink), lineWidth: 2.2)
        context.fill(Path(ellipseIn: CGRect(x: 12.5, y: 34, width: 9, height: 7.5)), with: .color(Self.bean))
        for (x, y) in [(9.8, 30.0), (14.8, 28.2), (19.8, 30.0)] {
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 4.2, height: 4.2)), with: .color(Self.bean))
        }
    }
}
