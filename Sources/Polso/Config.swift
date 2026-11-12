import Foundation

enum Slot: String, Codable, CaseIterable, Hashable {
    case left, right
}

/// How one wing turns numbers into a meter and a health colour.
struct SlotConfig: Codable, Equatable {
    var title: String
    var indicator: String     // id from `Indicators.all`
    var unit: String          // "%", "ms", "s", "/s" or anything (shown verbatim)
    var warn: Double?
    var crit: Double?
    var max: Double?          // gauge full scale; default 1.25 × the worse threshold
    var invert: Bool          // low values are bad (battery, throughput…)
    var history: Int          // samples kept for the sparkline / dot matrix
    var staleAfter: Double    // seconds without data before the wing goes gray; 0 = never
    var blink: Bool           // flash the wing on every new value
}

struct PingConfig: Codable, Equatable {
    var comet: Bool           // red dot running along the notch outline
    var pulse: Bool           // glow on the target wing
    var color: String         // ok|warn|crit|info or #rrggbb
    var sound: String         // NSSound name, "" = silent
}

struct AlertConfig: Codable, Equatable {
    var duration: Double
    var sound: String
    var queue: Bool           // false: a new alert replaces the one on screen
}

struct ExpandedConfig: Codable, Equatable {
    var enabled: Bool
    var width: Double
    var height: Double
    var logSize: Int          // recent pings/alerts kept for the panel
}

enum SourceKind: String, Codable, CaseIterable {
    case exec, prometheus, scrape

    var label: String {
        switch self {
        case .exec: "Command"
        case .prometheus: "PromQL"
        case .scrape: "Scrape /metrics"
        }
    }
}

/// Something polso polls on its own. Every field but `kind` is optional so configs stay short.
struct SourceConfig: Codable, Equatable {
    var kind: SourceKind
    var name: String?
    var slot: Slot?           // where plain values go; JSON output may target anything
    var every: Double?        // seconds, default 15
    var enabled: Bool?
    var timeout: Double?      // seconds, default 10
    // exec
    var command: String?
    // prometheus
    var url: String?
    var query: String?
    // scrape (uses `url` too)
    var metric: String?
    var labels: [String: String]?
    var rate: Bool?           // per-second rate of a counter instead of its raw value

    var interval: Double { Swift.max(1, every ?? 15) }
    var isOn: Bool { enabled ?? true }
    var title: String { name ?? command ?? query ?? metric ?? kind.rawValue }
}

struct Config: Codable, Equatable {
    var socket: String
    var wingWidth: Double
    var left: SlotConfig
    var right: SlotConfig
    var ping: PingConfig
    var alert: AlertConfig
    var expanded: ExpandedConfig
    var sources: [SourceConfig]

    func slot(_ s: Slot) -> SlotConfig { s == .left ? left : right }

    static let `default`: Config = {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        return Config(
            socket: "~/.config/polso/sock",
            wingWidth: 64,
            left: SlotConfig(title: "load 1m", indicator: "line", unit: "", warn: (cores * 0.7).rounded(), crit: cores,
                             max: nil, invert: false, history: 30, staleAfter: 60, blink: true),
            right: SlotConfig(title: "memory", indicator: "gauge", unit: "%", warn: 75, crit: 90,
                              max: 100, invert: false, history: 30, staleAfter: 60, blink: true),
            ping: PingConfig(comet: true, pulse: true, color: "crit", sound: ""),
            alert: AlertConfig(duration: 5, sound: "", queue: true),
            expanded: ExpandedConfig(enabled: true, width: 560, height: 360, logSize: 50),
            sources: [
                SourceConfig(kind: .exec, name: "load average", slot: .left, every: 5,
                             command: "sysctl -n vm.loadavg | awk '{print $2}'"),
                SourceConfig(kind: .exec, name: "memory used", slot: .right, every: 10,
                             command: "memory_pressure -Q | awk -F': ' '/percentage/{print 100-$2}'"),
            ])
    }()

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/polso")
    }
    static var fileURL: URL { dir.appendingPathComponent("config.json") }

    var socketPath: String { (socket as NSString).expandingTildeInPath }

    private static var encoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }

    /// Loads the user file deep-merged on top of the defaults, so partial configs work.
    static func load() -> (Config, String?) {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? save(.default)
            return (.default, nil)
        }
        do {
            let defaults = try JSONSerialization.jsonObject(with: encoder.encode(Config.default)) as! [String: Any]
            let user = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            let merged = deepMerge(defaults, user)
            let cfg = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
            return (cfg, nil)
        } catch {
            return (.default, "config: \(describe(error))")
        }
    }

    static func save(_ c: Config) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(c).write(to: fileURL, options: .atomic)
    }

    static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    /// Returns a problem description, or nil when the config is usable.
    func validate() -> String? {
        for s in Slot.allCases {
            let c = slot(s)
            if let w = c.warn, let k = c.crit {
                if !c.invert, w >= k { return "\(s.rawValue): warn must be below crit" }
                if c.invert, w <= k { return "\(s.rawValue): inverted, so warn must be above crit" }
            }
            if c.history < 2 { return "\(s.rawValue): keep at least 2 samples" }
            if Indicators.find(c.indicator) == nil { return "\(s.rawValue): unknown indicator \"\(c.indicator)\"" }
        }
        if socket.trimmingCharacters(in: .whitespaces).isEmpty { return "Socket path can't be empty" }
        if socketPath.utf8.count > 103 { return "Socket path is too long (max 103 bytes)" }
        for (i, s) in sources.enumerated() {
            let n = "source \(i + 1)"
            switch s.kind {
            case .exec:
                if (s.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return "\(n): command is empty" }
            case .prometheus:
                if URL(string: s.url ?? "")?.scheme == nil { return "\(n): not a valid URL" }
                if (s.query ?? "").isEmpty { return "\(n): query is empty" }
                if s.slot == nil { return "\(n): pick a wing" }
            case .scrape:
                if URL(string: s.url ?? "")?.scheme == nil { return "\(n): not a valid URL" }
                if (s.metric ?? "").isEmpty { return "\(n): metric is empty" }
                if s.slot == nil { return "\(n): pick a wing" }
            }
        }
        return nil
    }
}

private func deepMerge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
    var out = a
    for (k, v) in b {
        if let av = a[k] as? [String: Any], let bv = v as? [String: Any] {
            out[k] = deepMerge(av, bv)
        } else {
            out[k] = v
        }
    }
    return out
}

/// DecodingError's localizedDescription is useless ("data couldn't be read"); say which key broke.
func describe(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return error.localizedDescription }
    func path(_ c: DecodingError.Context) -> String {
        c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
    switch e {
    case let .keyNotFound(k, c): return "missing \(path(c)).\(k.stringValue)"
    case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c): return "bad value at \(path(c))"
    @unknown default: return e.localizedDescription
    }
}
