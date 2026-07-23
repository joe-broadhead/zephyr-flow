import AppKit
import SwiftUI

/// Branded menu bar glyph — flowing ribbons + orb (template, monochrome).
enum ZephyrMenuBarIcon {
    enum State {
        case idle
        case listening
        case processing
        case error
    }

    static func image(state: State, pointSize: CGFloat = 18) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixels = ceil(pointSize * scale)
        let size = NSSize(width: pixels, height: pixels)

        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)
            ctx.saveGState()
            ctx.scaleBy(x: rect.width, y: rect.height)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            drawFlowMark(ctx: ctx)

            switch state {
            case .idle:
                break
            case .listening:
                ctx.setLineWidth(0.06)
                ctx.strokeEllipse(in: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84))
            case .processing:
                ctx.setLineWidth(0.07)
                ctx.setLineCap(.round)
                ctx.addArc(
                    center: CGPoint(x: 0.78, y: 0.78),
                    radius: 0.12,
                    startAngle: .pi * 0.15,
                    endAngle: .pi * 1.1,
                    clockwise: false
                )
                ctx.strokePath()
            case .error:
                ctx.setLineWidth(0.10)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 0.22, y: 0.18))
                ctx.addLine(to: CGPoint(x: 0.78, y: 0.82))
                ctx.strokePath()
            }

            ctx.restoreGState()
            return true
        }

        image.isTemplate = true
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    /// Unit-space (0…1) flow mark — ribbons + core, no letters.
    private static func drawFlowMark(ctx: CGContext) {
        // Core
        ctx.setLineWidth(0.045)
        ctx.strokeEllipse(in: CGRect(x: 0.36, y: 0.36, width: 0.28, height: 0.28))
        ctx.fillEllipse(in: CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16))

        // Ribbons
        let ribbons: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.32, 0.06, 0.0, 0.07),
            (0.50, 0.08, 0.9, 0.085),
            (0.68, 0.06, 1.7, 0.07),
        ]
        for (yMid, amp, phase, width) in ribbons {
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let steps = 24
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let x = 0.12 + 0.76 * t
                let y = yMid + amp * sin(t * .pi * 2.1 + phase) + 0.015 * sin(t * .pi)
                if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
                else { ctx.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.strokePath()
        }

        // Spark
        ctx.fillEllipse(in: CGRect(x: 0.78, y: 0.30, width: 0.08, height: 0.08))
    }
}

struct ZephyrMenuBarLabel: View {
    @ObservedObject private var controller = DictationController.shared

    var body: some View {
        Image(nsImage: ZephyrMenuBarIcon.image(state: iconState))
            .renderingMode(.template)
            .accessibilityLabel(accessibilityText)
    }

    private var iconState: ZephyrMenuBarIcon.State {
        switch controller.panelState {
        case .listening: return .listening
        case .processing: return .processing
        case .error: return .error
        default: return .idle
        }
    }

    private var accessibilityText: String {
        switch controller.panelState {
        case .listening: return "ZephyrFlow listening"
        case .processing: return "ZephyrFlow processing"
        case .error: return "ZephyrFlow error"
        default: return "ZephyrFlow"
        }
    }
}
