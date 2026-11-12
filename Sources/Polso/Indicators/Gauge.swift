import SwiftUI

/// 270° ring with warn/crit ticks and the current value (or the sender's label) beside it.
enum GaugeIndicator: Indicator {
    static let id = "gauge"
    static let label = "Gauge"
    static func view(_ i: IndicatorInput) -> AnyView { AnyView(GaugeMeter(input: i)) }
}

struct GaugeMeter: View {
    var input: IndicatorInput

    static let sweep = 0.75

    /// Full scale: explicit `max`, else 1.25 × the worse threshold, else the history peak.
    var top: Double {
        let c = input.config
        let t = c.max ?? Swift.max(c.warn ?? 0, c.crit ?? 0) * 1.25
        return Swift.max(t > 0 ? t : (input.state.history.max() ?? 1) * 1.1, 1e-9)
    }

    func frac(_ v: Double) -> Double { min(max(v / top, 0), 1) * Self.sweep }

    var body: some View {
        let c = input.config, h = input.health, value = input.state.value
        HStack(spacing: 5) {
            ZStack {
                ring(to: Self.sweep).stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                if let value {
                    ring(to: max(frac(value), 0.01))
                        .stroke(h.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .shadow(color: h.color.opacity(h == .crit ? 0.9 : 0.5), radius: h == .crit ? 4 : 2)
                }
                if let w = c.warn { tick(w, Health.warn.color) }
                if let k = c.crit { tick(k, Health.crit.color) }
            }
            .rotationEffect(.degrees(135))
            .aspectRatio(1, contentMode: .fit)
            Text(input.state.label ?? fmt(value, unit: c.unit))
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value == nil && input.state.label == nil ? .secondary : h.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
    }

    func ring(to t: Double) -> some Shape { Circle().trim(from: 0, to: t) }

    func tick(_ v: Double, _ color: Color) -> some View {
        let t = frac(v)
        return Circle().trim(from: t - 0.008, to: t + 0.008)
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 4.5))
    }
}
