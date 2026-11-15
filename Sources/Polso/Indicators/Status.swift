import SwiftUI

/// Health light: a dot in the wing's health colour plus the label (or the formatted value).
enum StatusIndicator: Indicator {
    static let id = "status"
    static let label = "Status light"
    static func view(_ i: IndicatorInput) -> AnyView { AnyView(StatusLight(input: i)) }
}

struct StatusLight: View {
    var input: IndicatorInput

    var body: some View {
        let h = input.health, st = input.state
        HStack(spacing: 6) {
            Dot(color: h.color, pulsing: h == .crit)
            Text(st.label ?? fmt(st.value, unit: input.config.unit))
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(st.value == nil && st.label == nil ? .secondary : h.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hides a wing, for setups that only need one.
enum NoneIndicator: Indicator {
    static let id = "none"
    static let label = "Nothing"
    static func view(_ i: IndicatorInput) -> AnyView { AnyView(Color.clear) }
}
