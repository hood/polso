import SwiftUI

/// Uptime strip: one fixed-height pill per sample, coloured by that sample's health, newest on the right.
/// More samples than pills: each pill shows the worst of its bucket, so a short outage never averages away.
enum PillsIndicator: Indicator {
    static let id = "pills"
    static let label = "Health pills"
    static func view(_ i: IndicatorInput) -> AnyView { AnyView(PillStrip(input: i)) }
}

struct PillStrip: View {
    var input: IndicatorInput
    var slots: Int?   // fixed pill count spread over the width (the panel); nil = as many as fit at `pitch`

    static let pitch: CGFloat = 4
    static let width: CGFloat = 2.4

    var body: some View {
        let healths = input.state.samples.map { $0.health(input.config) }
        let gray = input.health == .unknown
        Canvas { ctx, size in
            let cols = slots.map { max($0, 1) } ?? max(Int((size.width + Self.pitch - Self.width) / Self.pitch), 1)
            let pitch = slots == nil ? Self.pitch : size.width / CGFloat(cols)
            let pw = slots == nil ? Self.width : max(Self.width, pitch * 0.5)
            let ox = (size.width - CGFloat(cols - 1) * pitch - pw) / 2
            let pills = Self.buckets(healths, cols: cols)
            for c in 0..<cols {
                let rect = CGRect(x: ox + CGFloat(c) * pitch, y: 0, width: pw, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: pw / 2)
                guard let h = pills[c] else {
                    ctx.fill(path, with: .color(.white.opacity(0.08)))
                    continue
                }
                let color = gray ? Health.unknown.color : h.color
                if c == cols - 1 {
                    var g = ctx
                    g.addFilter(.shadow(color: color, radius: 2.5))
                    g.fill(path, with: .color(color))
                } else {
                    ctx.fill(path, with: .color(color.opacity(0.35 + 0.55 * Double(c) / Double(max(cols - 1, 1)))))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    /// Right-aligned: with fewer samples than pills the left ones stay empty (nil).
    static func buckets(_ hs: [Health], cols: Int) -> [Health?] {
        let n = hs.count
        guard n > cols else { return Array(repeating: nil, count: cols - n) + hs.map { $0 } }
        return (0..<cols).map { c in
            hs[c * n / cols..<(c + 1) * n / cols].max { severity($0) < severity($1) }
        }
    }

    static func severity(_ h: Health) -> Int {
        switch h { case .ok: 0; case .unknown: 1; case .warn: 2; case .crit: 3 }
    }
}
