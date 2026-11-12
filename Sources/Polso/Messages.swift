import Foundation

/// The wire protocol: one JSON object per message, a JSON array for a batch.
///
///   {"type":"value","slot":"left","value":42}
///   {"type":"value","slot":"left","values":[1,2,3]}           // replaces the history
///   {"type":"value","slot":"right","value":3,"label":"3 jobs","health":"warn"}
///   {"type":"ping","slot":"left","color":"#ff4433"}           // slot optional
///   {"type":"alert","title":"Deploy failed","summary":"api","severity":"crit","count":2,"url":"https://…"}
enum Message {
    case value(Slot, values: [Double], replace: Bool, label: String?, health: Health?)
    case ping(Slot?, color: String?)
    case alert(AlertPayload)
    case settings   // internal: a second `Polso --settings` asks the running one to open settings
}

struct MessageError: LocalizedError {
    var errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

extension Message {
    /// Parses a payload: a JSON object, a JSON array, or newline-delimited JSON.
    /// A bare number becomes a value for `defaultSlot` (what exec sources print most of the time).
    static func parse(_ data: Data, defaultSlot: Slot? = nil) throws -> [Message] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let n = Double(text) {
            guard let slot = defaultSlot else { throw MessageError("got a bare number but no slot to put it in") }
            return [.value(slot, values: [n], replace: false, label: nil, health: nil)]
        }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            return try decode(json, defaultSlot: defaultSlot)
        }
        // NDJSON: every non-empty line must be valid on its own
        return try text.split(whereSeparator: \.isNewline).flatMap { line -> [Message] in
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                throw MessageError("not JSON: \(line.prefix(60))")
            }
            return try decode(j, defaultSlot: defaultSlot)
        }
    }

    static func decode(_ json: Any, defaultSlot: Slot?) throws -> [Message] {
        if let arr = json as? [Any] { return try arr.flatMap { try decode($0, defaultSlot: defaultSlot) } }
        guard let o = json as? [String: Any] else { throw MessageError("expected an object or an array") }
        let type = o["type"] as? String ?? (o["value"] != nil || o["values"] != nil ? "value" : "")

        func slot(required: Bool) throws -> Slot? {
            guard let raw = o["slot"] else {
                if required, defaultSlot == nil { throw MessageError("\(type): missing \"slot\" (left|right)") }
                return defaultSlot
            }
            guard let s = (raw as? String).flatMap(Slot.init(rawValue:)) else {
                throw MessageError("\(type): slot must be \"left\" or \"right\"")
            }
            return s
        }

        switch type {
        case "value":
            let s = try slot(required: true)!
            var values: [Double] = []
            var replace = false
            if let v = o["value"] {
                guard let d = number(v) else { throw MessageError("value: \"value\" must be a number") }
                values = [d]
            } else if let vs = o["values"] {
                guard let arr = vs as? [Any] else { throw MessageError("value: \"values\" must be an array") }
                values = arr.compactMap(number)
                replace = true
            }
            let health = try (o["health"] as? String).map { h in
                guard let x = Health(rawValue: h) else { throw MessageError("value: health must be ok|warn|crit|unknown") }
                return x
            }
            let label = o["label"] as? String
            if values.isEmpty, label == nil, health == nil, !replace {
                throw MessageError("value: needs \"value\", \"values\", \"label\" or \"health\"")
            }
            return [.value(s, values: values, replace: replace, label: label, health: health)]

        case "ping":
            // no slot = whole notch, even from a source that has a default wing
            return [.ping(o["slot"] == nil ? nil : try slot(required: false), color: o["color"] as? String)]

        case "alert":
            guard let title = o["title"] as? String, !title.isEmpty else { throw MessageError("alert: missing \"title\"") }
            let sev = try (o["severity"] as? String).map { s in
                guard let x = Severity(rawValue: s) else { throw MessageError("alert: severity must be info|warn|crit") }
                return x
            } ?? .crit
            let count = (o["count"].flatMap(number)).map { max(1, Int($0)) } ?? 1
            return [.alert(AlertPayload(title: title, summary: o["summary"] as? String, severity: sev,
                                        count: count, url: o["url"] as? String))]

        case "settings":
            return [.settings]

        case "":
            throw MessageError("missing \"type\" (value|ping|alert)")
        default:
            throw MessageError("unknown type \"\(type)\" (value|ping|alert)")
        }
    }
}

/// JSON numbers, plus numeric strings since shell senders often quote everything.
private func number(_ v: Any) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}
