import AppKit
import VikingBarCore

enum HelmetRenderer {
    static let size = NSSize(width: 22, height: 18)

    static func image(for treatment: HelmetTreatment) -> NSImage {
        let image = NSImage(size: Self.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            Self.draw(treatment, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func draw(_ treatment: HelmetTreatment, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(self.silhouette())
        context.fillPath()
        context.setBlendMode(.clear)
        switch treatment {
        case let .finite(fraction):
            context.fill(CGRect(x: 4, y: 3, width: 14 * fraction, height: 2))
        case .unlimited:
            let infinity = CGMutablePath()
            infinity.move(to: CGPoint(x: 11, y: 4))
            infinity.addCurve(to: CGPoint(x: 7, y: 4), control1: CGPoint(x: 8, y: 8), control2: CGPoint(x: 6, y: 6))
            infinity.addCurve(to: CGPoint(x: 11, y: 4), control1: CGPoint(x: 6, y: 2), control2: CGPoint(x: 8, y: 0))
            infinity.addCurve(to: CGPoint(x: 15, y: 4), control1: CGPoint(x: 14, y: 8), control2: CGPoint(x: 16, y: 6))
            infinity.addCurve(to: CGPoint(x: 11, y: 4), control1: CGPoint(x: 16, y: 2), control2: CGPoint(x: 14, y: 0))
            context.addPath(infinity)
            context.setLineWidth(1.2)
            context.strokePath()
        case .unavailable:
            let question = CGMutablePath()
            question.move(to: CGPoint(x: 9.2, y: 6.5))
            question.addCurve(
                to: CGPoint(x: 12.8, y: 6.5),
                control1: CGPoint(x: 9.2, y: 9),
                control2: CGPoint(x: 12.8, y: 9),
            )
            question.addCurve(
                to: CGPoint(x: 11, y: 4),
                control1: CGPoint(x: 12.8, y: 5),
                control2: CGPoint(x: 11, y: 5),
            )
            context.addPath(question)
            context.setLineWidth(1.2)
            context.setLineCap(.round)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: 10.4, y: 2, width: 1.2, height: 1.2))
        }
    }

    private static func silhouette() -> CGPath {
        let helmet = CGMutablePath()
        helmet.move(to: CGPoint(x: 3, y: 1))
        helmet.addLine(to: CGPoint(x: 19, y: 1))
        helmet.addQuadCurve(to: CGPoint(x: 20, y: 2), control: CGPoint(x: 20, y: 1))
        helmet.addCurve(to: CGPoint(x: 18.8, y: 8.8), control1: CGPoint(x: 20, y: 5), control2: CGPoint(x: 19.8, y: 7))
        helmet.addCurve(to: CGPoint(x: 20, y: 16.5), control1: CGPoint(x: 21, y: 11), control2: CGPoint(x: 21, y: 14))
        helmet.addQuadCurve(to: CGPoint(x: 19, y: 16.5), control: CGPoint(x: 19.5, y: 17.5))
        helmet.addCurve(
            to: CGPoint(x: 17.2, y: 11.5),
            control1: CGPoint(x: 19, y: 14),
            control2: CGPoint(x: 18.5, y: 12.5),
        )
        helmet.addCurve(
            to: CGPoint(x: 4.8, y: 11.5),
            control1: CGPoint(x: 13.5, y: 15.2),
            control2: CGPoint(x: 8.5, y: 15.2),
        )
        helmet.addCurve(to: CGPoint(x: 3, y: 16.5), control1: CGPoint(x: 3.5, y: 12.5), control2: CGPoint(x: 3, y: 14))
        helmet.addQuadCurve(to: CGPoint(x: 2, y: 16.5), control: CGPoint(x: 2.5, y: 17.5))
        helmet.addCurve(to: CGPoint(x: 3.2, y: 8.8), control1: CGPoint(x: 1, y: 14), control2: CGPoint(x: 1, y: 11))
        helmet.addCurve(to: CGPoint(x: 2, y: 2), control1: CGPoint(x: 2.2, y: 7), control2: CGPoint(x: 2, y: 5))
        helmet.addQuadCurve(to: CGPoint(x: 3, y: 1), control: CGPoint(x: 2, y: 1))
        helmet.closeSubpath()
        return helmet
    }
}
