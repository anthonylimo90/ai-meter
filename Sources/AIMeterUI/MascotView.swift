import SwiftUI
import AIMeterCore

/// The "Meter Buddy" — a gauge-faced sprite whose expression encodes app state.
/// It animates only while a session is active (and Reduce Motion is off);
/// every other state renders a single static frame, so there are no idle
/// redraws. Drawn with `Canvas` so the whole thing is one cheap layer.
struct MascotView: View {
    let status: MascotStatus
    var size: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// #5BD0C0 — the brand-neutral resting tint.
    private static let teal = Color(red: 0.357, green: 0.816, blue: 0.753)
    private static let loopPeriod: Double = 1.2

    private var animating: Bool { status.face == .active && !reduceMotion }

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 20.0, paused: !animating)
        ) { context in
            Canvas { ctx, canvasSize in
                draw(
                    in: ctx,
                    size: canvasSize,
                    time: context.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, time: Double) {
        let s = min(size.width, size.height)
        let phase = animating
            ? time.truncatingRemainder(dividingBy: Self.loopPeriod) / Self.loopPeriod
            : 0
        let bob = animating ? sin(phase * 2 * .pi) * (s * 0.04) : 0
        let tint = tintColor

        var g = context
        if status.face == .active || status.face == .low || status.face == .awaiting {
            g.addFilter(.shadow(color: tint.opacity(0.5), radius: s * 0.12))
        }

        let inset = s * 0.06
        let rect = CGRect(
            x: inset,
            y: inset + bob,
            width: s - 2 * inset,
            height: s - 2 * inset
        )

        // Face: filled dark disc with a tinted ring.
        g.fill(Circle().path(in: rect), with: .color(faceFill))
        g.stroke(Circle().path(in: rect), with: .color(tint), lineWidth: s * 0.07)

        // Eyes (blink briefly near the end of the active loop).
        let blink = animating && phase > 0.88
        let eyeR = s * 0.06
        let eyeY = rect.minY + rect.height * 0.34
        for ex in [rect.minX + rect.width * 0.34, rect.minX + rect.width * 0.66] {
            if blink {
                let r = CGRect(
                    x: ex - eyeR,
                    y: eyeY - s * 0.012,
                    width: eyeR * 2,
                    height: s * 0.024
                )
                g.fill(Capsule().path(in: r), with: .color(tint))
            } else {
                let r = CGRect(x: ex - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)
                g.fill(Circle().path(in: r), with: .color(tint))
            }
        }

        // Mouth: a quadratic curve whose depth carries the expression.
        let mx = rect.minX + rect.width * 0.28
        let mw = rect.width * 0.44
        let my = rect.minY + rect.height * 0.64
        var mouth = Path()
        mouth.move(to: CGPoint(x: mx, y: my))
        mouth.addQuadCurve(
            to: CGPoint(x: mx + mw, y: my),
            control: CGPoint(x: mx + mw / 2, y: my + mouthDepth(s: s, phase: phase))
        )
        g.stroke(
            mouth,
            with: .color(tint),
            style: StrokeStyle(lineWidth: s * 0.07, lineCap: .round)
        )
    }

    /// Positive curves down into a smile; negative is a frown.
    private func mouthDepth(s: CGFloat, phase: Double) -> CGFloat {
        switch status.face {
        case .active:
            return s * 0.07 + CGFloat(abs(sin(phase * 2 * .pi))) * s * 0.10
        case .idle:
            return s * 0.09
        case .low:
            return -s * 0.07
        case .awaiting:
            return s * 0.02
        case .refreshing:
            return 0
        }
    }

    private var faceFill: Color {
        Color(red: 0.13, green: 0.18, blue: 0.21)
    }

    private var tintColor: Color {
        switch status.face {
        case .low:
            return .orange
        case .awaiting:
            return .yellow
        case .active, .idle, .refreshing:
            return status.tint.map(\.accentColor) ?? Self.teal
        }
    }
}
