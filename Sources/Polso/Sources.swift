import Foundation

/// Runs every enabled source on its own interval and hands parsed messages to `sink` on the main actor.
@MainActor
final class Poller {
    private var tasks: [Task<Void, Never>] = []

    func restart(_ sources: [SourceConfig], historyFor: @escaping (Slot) -> Int,
                 sink: @escaping (Int, Result<[Message], Error>) -> Void) {
        stop()
        tasks = sources.enumerated().filter { $0.element.isOn }.map { i, src in
            Task {
                var state = SourceState()
                while !Task.isCancelled {
                    let r: Result<[Message], Error>
                    do { r = .success(try await run(src, &state, history: src.slot.map(historyFor) ?? 30)) } catch { r = .failure(error) }
                    if Task.isCancelled { return }
                    sink(i, r)
                    try? await Task.sleep(for: .seconds(src.interval))
                }
            }
        }
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}

/// Per-source memory between polls.
struct SourceState {
    var backfilled = false
    var lastCounter: (value: Double, at: Date)?
}

/// One poll. `state` carries what a source needs across polls (counter for rates, backfill flag).
func run(_ s: SourceConfig, _ state: inout SourceState, history: Int) async throws -> [Message] {
    switch s.kind {
    case .exec:
        let out = try await shell(s.command ?? "", timeout: s.timeout ?? 10)
        return try Message.parse(out, defaultSlot: s.slot)

    case .prometheus:
        guard let slot = s.slot else { throw MessageError("no wing picked") }
        let prom = Prometheus(base: s.url ?? "", timeout: s.timeout ?? 10)
        let q = s.query ?? ""
        if !state.backfilled {
            state.backfilled = true
            let past = try? await prom.range(q, seconds: Int(s.interval) * history, step: Int(s.interval))
            if let past, !past.isEmpty {
                return [.value(slot, values: past, replace: true, label: nil, health: nil)]
            }
        }
        guard let v = try await prom.instant(q).first?.value else { throw MessageError("query returned no series") }
        return [.value(slot, values: [v], replace: false, label: nil, health: nil)]

    case .scrape:
        guard let slot = s.slot, let url = URL(string: s.url ?? "") else { throw MessageError("bad url or no wing") }
        var req = URLRequest(url: url)
        req.setValue("text/plain;version=0.0.4", forHTTPHeaderField: "Accept")
        req.timeoutInterval = s.timeout ?? 10
        let (data, resp) = try await session.data(for: req)
        try check(resp, url)
        let samples = parseExposition(String(decoding: data, as: UTF8.self), metric: s.metric ?? "", labels: s.labels ?? [:])
        guard !samples.isEmpty else { throw MessageError("no \(s.metric ?? "") series matched") }
        let sum = samples.reduce(0, +)
        guard s.rate == true else { return [.value(slot, values: [sum], replace: false, label: nil, health: nil)] }
        let now = Date()
        defer { state.lastCounter = (sum, now) }
        guard let prev = state.lastCounter, sum >= prev.value else { return [] }   // first poll or counter reset
        let dt = now.timeIntervalSince(prev.at)
        return dt > 0 ? [.value(slot, values: [(sum - prev.value) / dt], replace: false, label: nil, health: nil)] : []
    }
}

// MARK: exec

private let shellPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

/// `sh -c command` with a sane PATH (LaunchAgents get almost none), killed after `timeout`.
func shell(_ command: String, timeout: Double) async throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ((env["PATH"].map { [$0] } ?? []) + shellPath).joined(separator: ":")
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice

    return try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global().async {
            do { try p.run() } catch { cont.resume(throwing: error); return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            // Read before waiting so a chatty command can't fill the pipe and deadlock.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            if p.terminationReason == .uncaughtSignal {
                cont.resume(throwing: MessageError("timed out after \(Int(timeout))s"))
            } else if p.terminationStatus != 0 {
                let msg = String(decoding: errData, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
                cont.resume(throwing: MessageError("exit \(p.terminationStatus)" + (msg.map { ": \($0)" } ?? "")))
            } else {
                cont.resume(returning: data)
            }
        }
    }
}

// MARK: prometheus

private let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 10
    return URLSession(configuration: c)
}()

private func check(_ resp: URLResponse, _ url: URL) throws {
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw MessageError("\(url.host ?? "?") HTTP \(code)") }
}

struct Prometheus {
    let base: String
    var timeout: Double = 10

    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> [[String: Any]] {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard var c = URLComponents(string: trimmed + path) else { throw MessageError("bad url: \(base)") }
        c.queryItems = items
        guard let url = c.url else { throw MessageError("bad url: \(base)") }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        try check(resp, url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let d = json?["data"] as? [String: Any], let result = d["result"] as? [[String: Any]] else {
            throw MessageError("not a Prometheus API response")
        }
        return result
    }

    func instant(_ q: String) async throws -> [(labels: [String: String], value: Double)] {
        try await get("/api/v1/query", [URLQueryItem(name: "query", value: q)]).compactMap { r in
            guard let v = r["value"] as? [Any], v.count == 2, let s = v[1] as? String, let d = Double(s), d.isFinite else { return nil }
            return (r["metric"] as? [String: String] ?? [:], d)
        }
    }

    /// First series of a range query, non-finite points dropped.
    func range(_ q: String, seconds: Int, step: Int) async throws -> [Double] {
        let end = Int(Date().timeIntervalSince1970)
        let result = try await get("/api/v1/query_range", [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "start", value: String(end - seconds)),
            URLQueryItem(name: "end", value: String(end)),
            URLQueryItem(name: "step", value: String(max(1, step))),
        ])
        let values = result.first?["values"] as? [[Any]] ?? []
        return values.compactMap { ($0.last as? String).flatMap(Double.init) }.filter(\.isFinite)
    }
}

// MARK: exposition format

/// Values of every sample named `metric` whose labels include all of `labels`.
/// Handles the text format Prometheus scrapes: `name{a="b",c="d"} 1.5 [timestamp]`.
func parseExposition(_ text: String, metric: String, labels want: [String: String]) -> [Double] {
    var out: [Double] = []
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.drop(while: { $0 == " " || $0 == "\t" })
        guard !line.isEmpty, line.first != "#", line.hasPrefix(metric) else { continue }
        var rest = line.dropFirst(metric.count)
        var labels: [String: String] = [:]
        if rest.first == "{" {
            guard let (parsed, after) = parseLabels(rest.dropFirst()) else { continue }
            labels = parsed
            rest = after
        }
        guard rest.first == " " || rest.first == "\t" else { continue }   // a longer metric name sharing the prefix
        guard want.allSatisfy({ labels[$0.key] == $0.value }) else { continue }
        let fields = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if let f = fields.first, let v = Double(f), v.isFinite { out.append(v) }
    }
    return out
}

/// Parses `a="b",c="d"}` (opening brace already consumed); returns the labels and what follows `}`.
private func parseLabels(_ s: Substring) -> ([String: String], Substring)? {
    var labels: [String: String] = [:]
    var i = s.startIndex
    func skipSpaces() { while i < s.endIndex, s[i] == " " || s[i] == "," { i = s.index(after: i) } }
    while true {
        skipSpaces()
        guard i < s.endIndex else { return nil }
        if s[i] == "}" { return (labels, s[s.index(after: i)...]) }
        let keyStart = i
        while i < s.endIndex, s[i] != "=" { i = s.index(after: i) }
        guard i < s.endIndex else { return nil }
        let key = s[keyStart..<i].trimmingCharacters(in: .whitespaces)
        i = s.index(after: i)
        guard i < s.endIndex, s[i] == "\"" else { return nil }
        i = s.index(after: i)
        var value = ""
        while i < s.endIndex, s[i] != "\"" {
            if s[i] == "\\", s.index(after: i) < s.endIndex {
                i = s.index(after: i)
                value.append(s[i] == "n" ? "\n" : s[i])
            } else {
                value.append(s[i])
            }
            i = s.index(after: i)
        }
        guard i < s.endIndex else { return nil }
        i = s.index(after: i)
        labels[key] = value
    }
}
