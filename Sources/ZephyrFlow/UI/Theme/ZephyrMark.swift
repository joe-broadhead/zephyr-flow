import SwiftUI

/// Canonical ZephyrFlow mark: flowing wind / sound ribbons + core orb (no letterforms).
/// Used in About, onboarding, and other in-app brand moments.
struct ZephyrMark: View {
    var size: CGFloat = 64
    var monochrome: Bool = false

    private struct Ribbon {
        let yMid: CGFloat
        let amp: CGFloat
        let phase: CGFloat
        let widthFrac: CGFloat
        let opacity: CGFloat
    }

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let cx = canvasSize.width * 0.5
            let cy = canvasSize.height * 0.52

            let stroke = monochrome ? Color.primary.opacity(0.92) : Color.white.opacity(0.94)
            let accent = monochrome ? Color.primary.opacity(0.55) : ZephyrTheme.cyan.opacity(0.95)

            if !monochrome {
                for (frac, op) in [(0.22, 0.18), (0.17, 0.26), (0.13, 0.34)] as [(CGFloat, Double)] {
                    let r = s * frac
                    var ring = Path()
                    ring.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                    context.stroke(
                        ring,
                        with: .color(ZephyrTheme.cyan.opacity(op)),
                        lineWidth: max(1, s * 0.012)
                    )
                }
            }

            // Core orb
            let orbR = s * 0.13
            let orbRect = CGRect(x: cx - orbR, y: cy - orbR, width: orbR * 2, height: orbR * 2)
            let orb = Path(ellipseIn: orbRect)
            if monochrome {
                context.fill(orb, with: .color(Color.primary.opacity(0.9)))
            } else {
                context.fill(
                    orb,
                    with: .linearGradient(
                        Gradient(colors: [Color.white, ZephyrTheme.cyan.opacity(0.85)]),
                        startPoint: CGPoint(x: cx - orbR, y: cy - orbR),
                        endPoint: CGPoint(x: cx + orbR, y: cy + orbR)
                    )
                )
            }

            let ribbons = [
                Ribbon(yMid: 0.34, amp: 0.055, phase: 0.0, widthFrac: 0.055, opacity: 0.9),
                Ribbon(yMid: 0.50, amp: 0.07, phase: 0.8, widthFrac: 0.065, opacity: 1.0),
                Ribbon(yMid: 0.66, amp: 0.055, phase: 1.6, widthFrac: 0.055, opacity: 0.88),
            ]

            for ribbon in ribbons {
                var path = Path()
                let steps = 40
                let x0 = canvasSize.width * 0.14
                let x1 = canvasSize.width * 0.86
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let x = x0 + (x1 - x0) * t
                    let y = canvasSize.height * ribbon.yMid
                        + s * ribbon.amp * sin(t * .pi * 2.1 + ribbon.phase)
                        + s * 0.02 * sin(t * .pi)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(
                    path,
                    with: .color(stroke.opacity(ribbon.opacity)),
                    style: StrokeStyle(
                        lineWidth: max(1.5, s * ribbon.widthFrac),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }

            // Leading spark
            let sparkR = s * 0.028
            let spark = CGRect(
                x: canvasSize.width * 0.82 - sparkR,
                y: canvasSize.height * 0.36 - sparkR,
                width: sparkR * 2,
                height: sparkR * 2
            )
            context.fill(Path(ellipseIn: spark), with: .color(accent))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Circular badge used on onboarding / about headers.
struct ZephyrMarkBadge: View {
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            Circle()
                .fill(ZephyrTheme.brandGradient.opacity(0.22))
                .frame(width: size + 16, height: size + 16)
                .blur(radius: 2)
            Circle()
                .strokeBorder(ZephyrTheme.borderGlow, lineWidth: 1)
                .frame(width: size + 8, height: size + 8)
            Circle()
                .fill(ZephyrTheme.bgCard)
                .frame(width: size, height: size)
            ZephyrMark(size: size * 0.72)
        }
    }
}
