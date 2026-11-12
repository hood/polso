import AppKit
import SwiftUI

/// One alert announcement. Everything visual is a pure function of `t` (seconds since `start`),
/// so a single paused-when-idle TimelineView drives it and snapshots can render any frame.
struct AlertBurst: Equatable {
    let id = UUID()
    var alert: AlertPayload
    var duration: TimeInterval = 5
    var start = Date()
    let sparks = Spark.make(count: 64)

    static let bannerHeight: CGFloat = 44
    static let extraWidth: CGFloat = 36   // per side, on top of the idle width

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.alert.count == b.alert.count }

    var tint: Color { alert.severity.color }
    var ramp: [Color] { alert.severity.ramp }

    static func size(idle: CGSize) -> CGSize {
        CGSize(width: idle.width + 2 * extraWidth, height: idle.height + bannerHeight)
    }

    /// Rim/halo intensity: hard flash on impact, settles into a slow pulse, fades before retracting.
    func glow(_ t: Double) -> Double {
        let flash = t < 0.12 ? t / 0.12 : 0.45 + 0.55 * exp(-(t - 0.12) * 5)
        let pulse = 0.14 * sin(2 * .pi * 1.2 * t) * clamp01((t - 0.6) / 0.4)
        return max(0, flash + pulse) * clamp01((duration - t) / 0.6)
    }

    /// Damped horizontal wobble right after the banner lands.
    static func shake(_ t: Double) -> Double {
        let s = t - 0.14
        return s > 0 ? 7 * exp(-s * 7) * sin(2 * .pi * 8 * s) : 0
    }

    /// Icon scale: grows in, then a springy overshoot on impact.
    static func pop(_ t: Double) -> Double {
        let s = t - 0.14
        return s < 0 ? 0.3 + 0.7 * clamp01(t / 0.14) : 1 + 0.5 * exp(-s * 8) * cos(2 * .pi * 2.6 * s)
    }
}

struct Spark {
    var u: Double       // -1...1 along the bottom edge
    var angle: Double   // radians, canvas space (π/2 = straight down)
    var speed: Double
    var born: Double
    var life: Double
    var width: Double

    static func make(count: Int) -> [Spark] {
        (0..<count).map { _ in
            let u = Double.random(in: -1...1)
            // Outer sparks fan sideways, inner ones mostly fall.
            let angle = .pi / 2 - u * 1.0 + .random(in: -0.45...0.45)
            return Spark(u: u, angle: angle, speed: .random(in: 110...420), born: 0.12 + .random(in: 0...0.1),
                         life: .random(in: 0.55...1.25), width: .random(in: 1.1...2.2))
        }
    }
}

/// Shockwave rings, impact flash and spark shower, drawn over the whole panel.
struct BurstCanvas: View {
    var burst: AlertBurst
    var t: Double
    var target: CGSize   // the banner-sized notch the effects radiate from

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let W = target.width, H = target.height
            let tint = burst.tint

            for delay in [0.1, 0.26] {
                let p = (t - delay) / 0.9
                guard p > 0, p < 1 else { continue }
                let g = easeOut(p) * 110
                let rect = CGRect(x: cx - W / 2 - g, y: 0, width: W + 2 * g, height: H + g * 0.75)
                let path = NotchShape(top: earRadius + g * 0.25, bottom: 18 + g * 0.4, closed: false).path(in: rect)
                let a = pow(1 - p, 2)
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 6))
                    l.stroke(path, with: .color(tint.opacity(a)), lineWidth: 5)
                }
                ctx.stroke(path, with: .color(.white.opacity(a * 0.75)), lineWidth: max(0.5, 2.2 * (1 - p)))
            }

            // Impact flash under the banner.
            let f = clamp01(1 - abs(t - 0.14) / 0.14)
            if f > 0 {
                let r = W * 0.45
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: H - r * 0.25, width: 2 * r, height: r * 0.5)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.55 * f), tint.opacity(0.35 * f), .clear]),
                                               center: CGPoint(x: cx, y: H), startRadius: 0, endRadius: r))
            }

            let streaks = sparkPaths(cx: cx, W: W, H: H)
            guard !streaks.isEmpty else { return }
            ctx.blendMode = .plusLighter
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 3))
                for s in streaks { l.stroke(s.path, with: .color(s.color), style: StrokeStyle(lineWidth: s.width * 2.5, lineCap: .round)) }
            }
            for s in streaks { ctx.stroke(s.path, with: .color(s.color), style: StrokeStyle(lineWidth: s.width, lineCap: .round)) }
        }
    }

    private func sparkPaths(cx: Double, W: Double, H: Double) -> [(path: Path, color: Color, width: Double)] {
        let k = 2.4, gravity = 560.0
        let ramp = burst.ramp
        return burst.sparks.compactMap { s in
            let age = t - s.born
            guard age > 0, age < s.life else { return nil }
            let life = age / s.life
            let decay = exp(-k * age)
            let vx = s.speed * cos(s.angle), vy = s.speed * sin(s.angle)
            let x = cx + s.u * (W / 2 - 14) + vx * (1 - decay) / k
            let y = H - 3 + vy * (1 - decay) / k + gravity * age * age / 2
            let tail = 0.035
            let tx = x - vx * decay * tail, ty = y - (vy * decay + gravity * age) * tail
            var p = Path()
            p.move(to: CGPoint(x: tx, y: ty))
            p.addLine(to: CGPoint(x: x, y: y))
            let color = life < 0.35 ? ramp[0] : life < 0.7 ? ramp[1] : ramp[2]
            return (p, color.opacity(1 - life * life), s.width * (1 - life * 0.6))
        }
    }
}

/// Banner content under the physical notch: icon pop, blur-in title, wobble, countdown bar.
struct BurstBanner: View {
    var burst: AlertBurst
    var t: Double
    var width: CGFloat
    var motion: Bool

    var body: some View {
        let tint = burst.tint
        let reveal = easeOut((t - 0.1) / 0.35)
        let glow = burst.glow(t)
        HStack(spacing: 9) {
            Image(systemName: burst.alert.severity.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .shadow(color: tint, radius: 2 + 6 * glow)
                .scaleEffect(motion ? AlertBurst.pop(t) : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(burst.alert.title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .lineLimit(1).truncationMode(.middle)
                if let s = burst.alert.summary {
                    Text(s).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .opacity(reveal)
            .blur(radius: (1 - reveal) * 6)
            .offset(y: (1 - reveal) * -6)
            Spacer(minLength: 6)
            Text(burst.alert.count > 1 ? "×\(burst.alert.count)" : "NEW")
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tint.opacity(0.22), in: Capsule())
                .foregroundStyle(tint)
                .opacity(reveal)
        }
        .foregroundStyle(.white)
        .offset(x: motion ? AlertBurst.shake(t) : 0)
        .padding(.horizontal, 24)
        .frame(width: width, height: AlertBurst.bannerHeight - 6)
        .overlay(alignment: .bottom) {
            Capsule().fill(tint.opacity(0.55))
                .frame(width: max(0, (width - 80) * (1 - clamp01(t / burst.duration))), height: 2)
                .opacity(reveal)
        }
    }
}

/// Rim light that hugs the notch outline with a bright highlight sweeping across.
func rimGradient(_ tint: Color, _ t: Double) -> LinearGradient {
    let s = (t * 0.7).truncatingRemainder(dividingBy: 1.4) - 0.2
    let stops: [Gradient.Stop] = [
        .init(color: tint, location: 0),
        .init(color: tint, location: clamp01(s - 0.12)),
        .init(color: .white, location: clamp01(s)),
        .init(color: tint, location: clamp01(s + 0.12)),
        .init(color: tint, location: 1),
    ]
    return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
}
