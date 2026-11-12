import SwiftUI

/// LED-style grid: the trend line rasterised onto a dot matrix, newest column glowing.
/// Lit dots are tinted by the value their row stands for (green → yellow at warn → red at crit).
enum DotsIndicator: Indicator {
    static let id = "dots"
    static let label = "Dot matrix"
    static func view(_ i: IndicatorInput) -> AnyView { AnyView(DotMatrix(input: i)) }
}

struct DotMatrix: View {
    var input: IndicatorInput

    static let pitch: CGFloat = 3.4
    static let dot: CGFloat = 2.2

    var body: some View {
        let values = input.state.history
        let cfg = input.config
        let floor = cfg.warn ?? 0
        let gray = input.health == .unknown
        Canvas { ctx, size in
            let cols = max(Int((size.width + Self.pitch - Self.dot) / Self.pitch), 2)
            let rows = max(Int((size.height + Self.pitch - Self.dot) / Self.pitch), 2)
            let ox = (size.width - CGFloat(cols - 1) * Self.pitch - Self.dot) / 2
            let oy = (size.height - CGFloat(rows - 1) * Self.pitch - Self.dot) / 2
            let lit = Self.raster(values, cols: cols, rows: rows, floor: floor)
            let r = Sparkline.range(values, floor: floor)
            let tint = (0..<rows).map { row -> Color in
                gray ? Health.unknown.color : Health.ramp(r.lo + Double(row) / Double(rows - 1) * (r.hi - r.lo), cfg)
            }
            for c in 0..<cols {
                for row in 0..<rows {
                    let color = tint[row]
                    let rect = CGRect(x: ox + CGFloat(c) * Self.pitch, y: oy + CGFloat(rows - 1 - row) * Self.pitch,
                                      width: Self.dot, height: Self.dot)
                    let on = lit[c].contains(row)
                    let shade: GraphicsContext.Shading = on
                        ? .color(color.opacity(c == cols - 1 ? 1 : 0.35 + 0.55 * Double(c) / Double(cols - 1)))
                        : .color(.white.opacity(0.08))
                    if on && c == cols - 1 {
                        var g = ctx
                        g.addFilter(.shadow(color: color, radius: 2.5))
                        g.fill(Path(ellipseIn: rect), with: shade)
                    } else {
                        ctx.fill(Path(ellipseIn: rect), with: shade)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    /// Lit rows per column: bucket-max resample, then fill vertical gaps so the line stays connected.
    static func raster(_ values: [Double], cols: Int, rows: Int, floor: Double) -> [Set<Int>] {
        guard !values.isEmpty else { return Array(repeating: [rows / 2], count: cols) }
        let r = Sparkline.range(values, floor: floor)
        let n = values.count
        let ys: [Int] = (0..<cols).map { c in
            let lo = c * n / cols, hi = max((c + 1) * n / cols, lo + 1)
            let v = values[min(lo, n - 1)..<min(hi, n)].max() ?? 0
            return min(max(Int(((v - r.lo) / (r.hi - r.lo) * Double(rows - 1)).rounded()), 0), rows - 1)
        }
        return ys.enumerated().map { c, y in
            // reach halfway to each neighbour so steep jumps read as a connected stroke
            let ends = [c > 0 ? (ys[c - 1] + y) / 2 : y, c < cols - 1 ? (ys[c + 1] + y) / 2 : y, y]
            return Set(ends.min()!...ends.max()!)
        }
    }
}
