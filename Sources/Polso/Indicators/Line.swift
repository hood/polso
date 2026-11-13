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
        // The line stops one dot radius short of the edge, and the dot sits exactly on its last point.
        let inset: CGFloat = 3
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Sparkline(values: values, color: color, floor: floor, lineWidth: 1.6, fill: true)
                    .padding(.trailing, inset)
                Dot(color: color, pulsing: input.health == .crit)
                    .position(x: geo.size.width - inset, y: Sparkline.lastY(values, floor: floor, height: geo.size.height))
            }
        }
        .padding(.horizontal, 8)
        // Just enough for the dot (radius 3) at the top and bottom of the range: the line gets the full wing height.
        .padding(.vertical, 4)
    }
}
