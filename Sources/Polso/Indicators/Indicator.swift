import SwiftUI

/// What an indicator gets to draw one wing.
struct IndicatorInput {
    var state: SlotState
    var config: SlotConfig
    var health: Health
}

/// A wing meter style. Adding one = a new file with a conforming type + one line in `Indicators.all`.
protocol Indicator {
    static var id: String { get }      // what goes in config: "indicator": "<id>"
    static var label: String { get }   // shown in settings
    @MainActor static func view(_ input: IndicatorInput) -> AnyView
}

/// Registry entry. Plain values rather than `any Indicator.Type`, which crashes SILGen in Swift 6.4.
struct IndicatorKind {
    let id: String
    let label: String
    let view: @MainActor (IndicatorInput) -> AnyView
}

extension Indicator {
    static var kind: IndicatorKind { IndicatorKind(id: id, label: label, view: { view($0) }) }
}

enum Indicators {
    static let all: [IndicatorKind] = [LineIndicator.kind, GaugeIndicator.kind, DotsIndicator.kind]

    static func find(_ id: String) -> IndicatorKind? { all.first { $0.id == id } }
}

/// Glowing "now" dot; breathes only when critical so idle CPU stays ~0.
struct Dot: View {
    var color: Color
    var pulsing: Bool

    var body: some View {
        let dot = Circle().fill(color).frame(width: 6, height: 6)
        if pulsing {
            dot.phaseAnimator([false, true]) { v, on in
                v.shadow(color: color, radius: on ? 6 : 2).scaleEffect(on ? 1.5 : 1)
            } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            dot.shadow(color: color, radius: 3)
        }
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var floor: Double
    var lineWidth: CGFloat = 1.5
    var fill = false
    var guides: [(Double, Color)] = []

    /// Top of the y axis; the bottom is 0, or the minimum when values go negative.
    static func range(_ values: [Double], floor: Double) -> (lo: Double, hi: Double) {
        let lo = min(values.min() ?? 0, 0)
        let hi = max(values.max() ?? 0, floor * 1.15, lo + 1e-9)
        return (lo, hi)
    }

    static func y(_ v: Double, _ r: (lo: Double, hi: Double), height: CGFloat) -> CGFloat {
        height - CGFloat((v - r.lo) / (r.hi - r.lo)) * height
    }

    static func lastY(_ values: [Double], floor: Double, height: CGFloat) -> CGFloat {
        guard let last = values.last else { return height / 2 }
        return y(last, range(values, floor: floor), height: height)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let r = Sparkline.range(values + guides.map(\.0), floor: floor)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? w * CGFloat(i) / CGFloat(values.count - 1) : w,
                        y: Sparkline.y(v, r, height: h))
            }
            ZStack {
                ForEach(Array(guides.enumerated()), id: \.offset) { _, g in
                    let y = Sparkline.y(g.0, r, height: h)
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(g.1.opacity(0.45), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                }
                if pts.count > 1 {
                    if fill {
                        Path { p in
                            p.move(to: CGPoint(x: pts[0].x, y: h))
                            pts.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: pts.last!.x, y: h))
                        }
                        .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    }
                    Path { p in p.addLines(pts) }
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                } else {
                    Path { p in p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2)) }
                        .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
        }
    }
}

extension SlotConfig {
    /// Warn/crit dashed guides for sparklines.
    var guides: [(Double, Color)] {
        [warn.map { ($0, Health.warn.color) }, crit.map { ($0, Health.crit.color) }].compactMap { $0 }
    }
}
