import SwiftUI

enum Health: String, Codable {
    case ok, warn, crit, unknown

    static func of(_ v: Double?, _ c: SlotConfig) -> Health {
        guard let v else { return .unknown }
        if c.invert {
            if let k = c.crit, v <= k { return .crit }
            if let w = c.warn, v <= w { return .warn }
        } else {
            if let k = c.crit, v >= k { return .crit }
            if let w = c.warn, v >= w { return .warn }
        }
        return .ok
    }

    static let green = (0.19, 0.82, 0.35), yellow = (1.0, 0.78, 0.04), red = (1.0, 0.27, 0.23)

    var color: Color {
        switch self {
        case .ok: rgb(Self.green)
        case .warn: rgb(Self.yellow)
        case .crit: rgb(Self.red)
        case .unknown: Color.gray.opacity(0.6)
        }
    }

    var label: String {
        switch self { case .ok: "OK"; case .warn: "WARN"; case .crit: "CRIT"; case .unknown: "N/A" }
    }

    /// Continuous ok→warn→crit colour: green far from trouble, yellow at warn, red at crit and beyond.
    static func ramp(_ v: Double, _ c: SlotConfig) -> Color {
        guard let (w, k) = thresholds(c) else { return Health.ok.color }
        // badness: 0 = comfortably fine, 1 = at warn, 2 = at crit
        let b: Double = c.invert
            ? (v >= w ? clamp01(1 - (v - w) / Swift.max(w - k, 1e-9)) : 1 + (w - v) / Swift.max(w - k, 1e-9))
            : (v <= w ? v / Swift.max(w, 1e-9) : 1 + (v - w) / Swift.max(k - w, 1e-9))
        return b <= 1 ? mix(green, yellow, b) : mix(yellow, red, b - 1)
    }

    /// Both thresholds, filling a missing one so the ramp still has two stops.
    static func thresholds(_ c: SlotConfig) -> (warn: Double, crit: Double)? {
        switch (c.warn, c.crit) {
        case let (w?, k?): return (w, k)
        case let (w?, nil): return (w, c.invert ? w * 0.75 : w * 1.25)
        case let (nil, k?): return (c.invert ? k * 1.25 : k * 0.8, k)
        default: return nil
        }
    }
}

enum Severity: String, Codable {
    case info, warn, crit

    var color: Color {
        switch self {
        case .info: Color(red: 0.35, green: 0.68, blue: 1.0)
        case .warn: Health.warn.color
        case .crit: Health.crit.color
        }
    }

    /// Spark colour ramp, hot to cool.
    var ramp: [Color] {
        switch self {
        case .info: [Color(red: 0.9, green: 0.97, blue: 1), Color(red: 0.45, green: 0.8, blue: 1), Color(red: 0.2, green: 0.45, blue: 1)]
        case .warn: [Color(red: 1, green: 1, blue: 0.85), Color(red: 1, green: 0.85, blue: 0.2), Color(red: 1, green: 0.55, blue: 0.05)]
        case .crit: [Color(red: 1, green: 0.95, blue: 0.7), Color(red: 1, green: 0.55, blue: 0.15), Color(red: 1, green: 0.18, blue: 0.2)]
        }
    }

    var icon: String {
        switch self {
        case .info: "info.circle.fill"
        case .warn, .crit: "exclamationmark.triangle.fill"
        }
    }
}

/// What one wing currently shows.
struct SlotState {
    var value: Double?
    var history: [Double] = []
    var label: String?        // sender-provided text, replaces the formatted value
    var health: Health?       // sender override of the threshold colour
    var updated: Date?

    mutating func push(_ vs: [Double], replace: Bool, cap: Int) {
        let vs = vs.filter(\.isFinite)
        guard !vs.isEmpty else { return }
        history = replace ? vs : history + vs
        if history.count > cap { history.removeFirst(history.count - cap) }
        value = vs.last
    }
}

struct AlertPayload: Identifiable {
    let id = UUID()
    var title: String
    var summary: String?
    var severity: Severity
    var count: Int
    var url: String?
}

struct PingEvent {
    var slot: Slot?
    var color: Color
}

/// A row in the expanded panel's "recent" list.
struct LogEntry: Identifiable {
    enum Kind { case ping(PingEvent), alert(AlertPayload) }
    let id = UUID()
    var kind: Kind
    var at = Date()
}

// MARK: helpers

func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }

private func rgb(_ c: (Double, Double, Double)) -> Color { Color(red: c.0, green: c.1, blue: c.2) }

private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
    let t = clamp01(t)
    return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
}

/// `ok|warn|crit|info`, `#rgb`/`#rrggbb`, or a few plain names. Unknown strings fall back to crit red.
func parseColor(_ s: String?) -> Color? {
    guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
    if let h = Health(rawValue: s), h != .unknown { return h.color }
    if let sev = Severity(rawValue: s) { return sev.color }
    let named: [String: Color] = ["red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint,
                                  "teal": .teal, "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple,
                                  "pink": .pink, "white": .white]
    if let c = named[s] { return c }
    var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
    return Color(red: Double(n >> 16 & 0xff) / 255, green: Double(n >> 8 & 0xff) / 255, blue: Double(n & 0xff) / 255)
}

func fmt(_ v: Double?, unit: String) -> String {
    guard let v, v.isFinite else { return "–" }
    if v > 0, v < 0.01 { return "<0.01" + (unit == "%" ? "%" : unit.hasPrefix("/") ? unit : unit.isEmpty ? "" : " " + unit) }
    switch unit {
    case "%":
        return v < 1 ? String(format: "%.2f%%", v) : String(format: "%.1f%%", v)
    case "ms":
        return v >= 1000 ? String(format: "%.2fs", v / 1000) : String(format: "%.0fms", v)
    case "s":
        return v >= 1 ? String(format: "%.2fs", v) : String(format: "%.0fms", v * 1000)
    default:
        let a = abs(v)
        let n = a >= 100 ? String(format: "%.0f", v) : a >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return unit.isEmpty ? n : "\(n)\(unit.hasPrefix("/") ? "" : " ")\(unit)"
    }
}

func age(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = Int(Date().timeIntervalSince(d))
    return s >= 86400 ? "\(s / 86400)d" : s >= 3600 ? "\(s / 3600)h" : s >= 60 ? "\(s / 60)m" : "\(max(1, s))s"
}
