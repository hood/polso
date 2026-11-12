import SwiftUI

/// Heartbeat line tinted by health, with a glowing "now" dot.
enum LineIndicator: Indicator {
    static let id = "line"
    static let label = "Line"
    static func view(_ i: IndicatorInput) -> AnyView { AnyView(LineMeter(input: i)) }
}

struct LineMeter: View {
    var input: IndicatorInput

    var body: some View {
        let values = input.state.history
        let floor = input.config.warn ?? 0
        let color = input.health.color
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Sparkline(values: values, color: color, floor: floor, lineWidth: 1.6, fill: true)
                    .padding(.trailing, 6)
                Dot(color: color, pulsing: input.health == .crit)
                    .position(x: geo.size.width - 3, y: Sparkline.lastY(values, floor: floor, height: geo.size.height))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }
}
