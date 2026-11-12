import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var config: Config
    @Published var configError: String?
    @Published var left = SlotState()
    @Published var right = SlotState()
    @Published var beats: [Slot: Int] = [:]        // bumped per new value; drives the wing blink
    @Published var wingPings: [Slot: Int] = [:]    // bumped per ping aimed at a wing; drives its glow
    @Published var pings = 0                       // bumped per ping; drives the comet
    @Published var lastPing = PingEvent(slot: nil, color: Health.crit.color)
    @Published var burst: AlertBurst?
    @Published var log: [LogEntry] = []
    @Published var stale: Set<Slot> = []
    @Published var lastUpdate: Date?
    @Published var sourceErrors: [Int: String] = [:]
    @Published var serverError: String?

    var onSettings: (() -> Void)?

    private var queue: [AlertPayload] = []
    private let poller = Poller()
    private var server: SocketServer?
    private var timer: Timer?
    private var configMtime: Date?

    init() {
        (config, configError) = Config.load()
        configMtime = Config.mtime()
    }

    // MARK: lifecycle

    func start() {
        startServer()
        restartSources()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadConfigIfChanged()
                self?.checkStale()
            }
        }
    }

    func stop() {
        poller.stop()
        server?.stop()
    }

    private func startServer() {
        server?.stop()
        let s = SocketServer(path: config.socketPath) { [weak self] data in
            do {
                let msgs = try Message.parse(data)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(msgs) } }
                return "ok"
            } catch {
                return "error: \(describe(error))"
            }
        }
        do {
            try s.start()
            server = s
            serverError = nil
        } catch {
            server = nil
            serverError = "socket: \(describe(error))"
        }
    }

    private func restartSources() {
        sourceErrors = [:]
        poller.restart(config.sources, historyFor: { [config] in config.slot($0).history }) { [weak self] i, r in
            guard let self else { return }
            switch r {
            case let .success(msgs):
                sourceErrors[i] = nil
                handle(msgs)
            case let .failure(e):
                let name = i < config.sources.count ? config.sources[i].title : "source \(i + 1)"
                sourceErrors[i] = "\(name): \(describe(e))"
            }
        }
    }

    /// Persists a config edited in the settings window and applies it immediately.
    func apply(_ c: Config) throws {
        try Config.save(c)
        configMtime = Config.mtime()
        configError = nil
        use(c)
    }

    func reloadConfigIfChanged() {
        let m = Config.mtime()
        guard m != configMtime else { return }
        configMtime = m
        let (c, err) = Config.load()
        configError = err
        if err == nil { use(c) }
    }

    private func use(_ c: Config) {
        let old = config
        config = c
        if old.socketPath != c.socketPath || server == nil { startServer() }
        if old.sources != c.sources || old.left.history != c.left.history || old.right.history != c.right.history {
            restartSources()
        }
        for s in Slot.allCases {
            let cap = c.slot(s).history
            update(s) { if $0.history.count > cap { $0.history.removeFirst($0.history.count - cap) } }
        }
        if log.count > c.expanded.logSize { log.removeLast(log.count - c.expanded.logSize) }
        checkStale()
    }

    // MARK: state

    func state(_ s: Slot) -> SlotState { s == .left ? left : right }

    private func update(_ s: Slot, _ f: (inout SlotState) -> Void) {
        if s == .left { f(&left) } else { f(&right) }
    }

    func health(_ s: Slot) -> Health {
        let st = state(s)
        if stale.contains(s) { return .unknown }
        return st.health ?? Health.of(st.value, config.slot(s))
    }

    var worst: Health {
        let hs = Slot.allCases.map(health)
        for h in [Health.crit, .warn, .ok] where hs.contains(h) { return h }
        return .unknown
    }

    private func checkStale() {
        let now = Date()
        let s = Set(Slot.allCases.filter { slot in
            let after = config.slot(slot).staleAfter
            guard after > 0, let t = state(slot).updated else { return false }
            return now.timeIntervalSince(t) > after
        })
        if s != stale { stale = s }
    }

    // MARK: messages

    func handle(_ msgs: [Message]) {
        for m in msgs {
            switch m {
            case let .value(slot, values, replace, label, health):
                let cfg = config.slot(slot)
                update(slot) { st in
                    st.push(values, replace: replace, cap: cfg.history)
                    // A sample carries its own label/health; a bare label/health message only patches those.
                    if !values.isEmpty || replace {
                        st.label = label
                        st.health = health
                    } else {
                        if let label { st.label = label }
                        if let health { st.health = health }
                    }
                    st.updated = Date()
                }
                if cfg.blink { beats[slot, default: 0] &+= 1 }
                stale.remove(slot)
                lastUpdate = Date()
            case let .ping(slot, color):
                ping(slot, color: parseColor(color))
            case let .alert(a):
                announce(a)
            case .settings:
                onSettings?()
            }
        }
    }

    func ping(_ slot: Slot?, color: Color? = nil) {
        let c = config.ping
        lastPing = PingEvent(slot: slot, color: color ?? parseColor(c.color) ?? Health.crit.color)
        pings &+= 1
        for s in slot.map({ [$0] }) ?? Slot.allCases { wingPings[s, default: 0] &+= 1 }
        if !c.sound.isEmpty { NSSound(named: c.sound)?.play() }
        record(.ping(lastPing))
    }

    func announce(_ a: AlertPayload) {
        record(.alert(a))
        if !config.alert.sound.isEmpty { NSSound(named: config.alert.sound)?.play() }
        guard config.alert.queue, burst != nil else { return show(a) }
        // Same title as what's on screen or waiting: bump its count instead of replaying it.
        if burst?.alert.title == a.title {
            burst?.alert.count += a.count
        } else if let i = queue.firstIndex(where: { $0.title == a.title }) {
            queue[i].count += a.count
        } else {
            queue.append(a)
            if queue.count > 20 { queue.removeFirst() }
        }
    }

    private func show(_ a: AlertPayload) {
        let b = AlertBurst(alert: a, duration: max(1.5, config.alert.duration))
        burst = b
        Task {
            try? await Task.sleep(for: .seconds(b.duration))
            guard burst?.id == b.id else { return }
            burst = nil
            guard !queue.isEmpty else { return }
            try? await Task.sleep(for: .seconds(0.45))   // let the banner retract before the next one drops
            if burst == nil, !queue.isEmpty { show(queue.removeFirst()) }
        }
    }

    /// Hovering opens the panel, which lists everything anyway, so pending banners are dropped.
    func dismissBursts() {
        burst = nil
        queue.removeAll()
    }

    private func record(_ k: LogEntry.Kind) {
        log.insert(LogEntry(kind: k), at: 0)
        if log.count > config.expanded.logSize { log.removeLast() }
    }

    func clearLog() { log.removeAll() }

    // MARK: demo

    func demoAlert(_ sev: Severity = .crit) {
        announce(AlertPayload(title: "Deploy failed", summary: "api-gateway · rollout stuck at 2/5 pods",
                              severity: sev, count: 1, url: nil))
    }
}
