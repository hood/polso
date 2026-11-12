import AppKit
import SwiftUI

// Deterministic frame renderer for the README clips (`Polso --film <dir>`).
// SwiftUI animations don't advance inside ImageRenderer, so every animated property here is an
// explicit function of the film clock, mirroring what RootView does live (same springs, same keyframes).

// MARK: motion

/// Step response of SwiftUI's `.spring(response:dampingFraction:)`, 0 → 1 (overshoots when underdamped).
func springStep(_ t: Double, response: Double, damping: Double) -> Double {
    guard t > 0 else { return 0 }
    let w0 = 2 * .pi / response
    if damping >= 1 { return 1 - exp(-w0 * t) * (1 + w0 * t) }
    let wd = w0 * sqrt(1 - damping * damping)
    return 1 - exp(-damping * w0 * t) * (cos(wd * t) + damping * w0 / wd * sin(wd * t))
}

private func smooth(_ x: Double) -> Double { let x = clamp01(x); return x * x * (3 - 2 * x) }

/// Piecewise keyframes: (value, duration) pairs starting from 0, like CubicKeyframe chains.
private func keyframes(_ t: Double, _ ks: [(Double, Double)]) -> Double {
    guard t > 0 else { return 0 }
    var from = 0.0, at = 0.0
    for (v, d) in ks {
        if t < at + d { return from + (v - from) * smooth((t - at) / d) }
        from = v; at += d
    }
    return from
}

/// Same curves as `refreshBlink` / `pingPulse`.
private func blink(_ dt: Double) -> Double { keyframes(dt, [(0.45, 0.08), (0, 0.42)]) }
private func pulse(_ dt: Double) -> Double { keyframes(dt, [(1, 0.12), (0.15, 0.3), (1, 0.12), (0, 0.6)]) }

// MARK: notch frame

/// Everything RootView animates, frozen at one instant.
struct NotchFrame {
    var size: CGSize
    var top: CGFloat
    var bottom: CGFloat
    var idleAlpha = 1.0
    var expandAlpha = 0.0
    var burst: AlertBurst?
    var bt = 0.0                 // seconds into the burst
    var live = true              // false while the banner retracts: no rim, no sparks
    var bannerAlpha = 1.0
    var comet: (p: Double, color: Color, reverse: Bool)?
    var blink: [Slot: Double] = [:]
    var pulse: [Slot: Double] = [:]
    var pulseColor = Health.crit.color
    var indicators: [Slot: String] = [:]
}

struct FilmNotch: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    var f: NotchFrame

    var body: some View {
        let shape = NotchShape(top: f.top, bottom: f.bottom)
        let glow = f.live ? (f.burst?.glow(f.bt) ?? 0) : 0
        let tint = f.burst?.tint ?? .clear
        let exp = CGSize(width: store.config.expanded.width + 2 * earRadius, height: store.config.expanded.height)
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            if f.burst != nil, glow > 0 {
                RadialGradient(colors: [tint.opacity(0.32 * glow), .clear], center: .bottom, startRadius: 0, endRadius: f.size.width * 0.45)
                NotchShape(top: shape.top, bottom: shape.bottom, closed: false)
                    .stroke(rimGradient(tint, f.bt), lineWidth: 3)
                    .opacity(glow)
            }
            if f.idleAlpha > 0 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        wing(.left)
                        Spacer().frame(width: ui.notchWidth)
                        wing(.right)
                    }
                    .frame(height: ui.notchHeight)
                    if let b = f.burst {
                        BurstBanner(burst: b, t: f.bt, width: f.size.width, motion: true).opacity(f.bannerAlpha)
                    }
                }
                .padding(.horizontal, earRadius)
                .opacity(f.idleAlpha)
            }
            if f.expandAlpha > 0 {
                ExpandedView(store: store, ui: ui)
                    .padding(.horizontal, 24)
                    .frame(width: exp.width, height: exp.height)
                    .scaleEffect(0.96 + 0.04 * f.expandAlpha, anchor: .top)
                    .opacity(f.expandAlpha)
            }
        }
        .frame(width: f.size.width, height: f.size.height)
        .clipShape(shape)
        .shadow(color: tint.opacity(0.85 * glow), radius: 16)
        .shadow(color: .black.opacity(0.5 * f.expandAlpha), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if let b = f.burst, f.live { BurstCanvas(burst: b, t: f.bt, target: f.size) }
            if let c = f.comet {
                NotchComet(top: shape.top, bottom: shape.bottom, p: c.p, color: c.color, reverse: c.reverse)
                    .frame(width: f.size.width, height: f.size.height)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    func wing(_ s: Slot) -> some View {
        var c = store.config.slot(s)
        if let id = f.indicators[s] { c.indicator = id }
        let input = IndicatorInput(state: store.state(s), config: c, health: store.health(s))
        let p = f.pulse[s] ?? 0
        return (Indicators.find(c.indicator) ?? LineIndicator.kind).view(input)
            .shadow(color: f.pulseColor.opacity(p), radius: 5 * p)
            .brightness((f.blink[s] ?? 0) + 0.25 * p)
            .frame(width: store.config.wingWidth)
    }
}

/// Spring-driven shape morphs between idle, burst and expanded, plus the content cross-fades.
struct ModeTrack {
    enum Mode { case idle, burst, expanded }
    var cuts: [(at: Double, mode: Mode)] = [(0, .idle)]
    var idle: CGSize
    var expanded: CGSize

    func target(_ m: Mode) -> (CGSize, CGFloat, CGFloat) {
        switch m {
        case .idle: (idle, earRadius, 12)
        case .burst: (AlertBurst.size(idle: idle), earRadius, 18)
        case .expanded: (expanded, 14, 24)
        }
    }

    func spring(_ m: Mode, _ dt: Double) -> Double {
        switch m {
        case .burst: springStep(dt, response: 0.42, damping: 0.55)
        case .expanded: springStep(dt, response: 0.38, damping: 0.82)
        case .idle: springStep(dt, response: 0.32, damping: 1.0)
        }
    }

    /// Fills size, radii and the idle/expanded fades of `f` for time `t`.
    func apply(_ t: Double, to f: inout NotchFrame) -> (mode: Mode, from: Mode, s: Double) {
        let k = cuts.lastIndex { $0.at <= t } ?? 0
        let mode = cuts[k].mode, from = k > 0 ? cuts[k - 1].mode : mode
        let s = k > 0 ? spring(mode, t - cuts[k].at) : 1
        let (a, at, ab) = target(from), (b, bt, bb) = target(mode)
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * s }
        f.size = CGSize(width: lerp(a.width, b.width), height: lerp(a.height, b.height))
        f.top = lerp(at, bt)
        f.bottom = lerp(ab, bb)
        let e = clamp01(s)
        if mode == .expanded { f.expandAlpha = e; f.idleAlpha = 1 - e }
        else if from == .expanded { f.expandAlpha = 1 - e; f.idleAlpha = e }
        return (mode, from, s)
    }
}

// MARK: scenery

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.16, green: 0.07, blue: 0.27),
                                    Color(red: 0.38, green: 0.11, blue: 0.33)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                blob(Color(red: 0.2, green: 0.45, blue: 1), at: CGPoint(x: w * 0.12, y: h * 0.85), r: w * 0.45)
                blob(Color(red: 1, green: 0.35, blue: 0.45), at: CGPoint(x: w * 0.95, y: h * 0.25), r: w * 0.4)
                blob(Color(red: 0.55, green: 0.3, blue: 1), at: CGPoint(x: w * 0.55, y: h * 1.05), r: w * 0.35)
            }
        }
    }

    func blob(_ c: Color, at p: CGPoint, r: CGFloat) -> some View {
        RadialGradient(colors: [c.opacity(0.55), c.opacity(0)], center: .center, startRadius: 0, endRadius: r)
            .frame(width: 2 * r, height: 2 * r)
            .position(p)
    }
}

struct MenuBar: View {
    var height: CGFloat
    var items = true
    var body: some View {
        HStack(spacing: 16) {
            if items { content }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.black.opacity(0.3))
    }

    @ViewBuilder var content: some View {
            Text("Terminal").fontWeight(.bold)
            Text("Shell"); Text("Edit"); Text("View")
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("Fri 13 Nov  9:41")
    }
}

struct TermLine { var text: String; var output = false }

struct TerminalWindow: View {
    var lines: [TermLine]
    var caret: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 11, height: 11) }
                Spacer()
                Text("zsh — polso").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Color.clear.frame(width: 47, height: 1)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    HStack(spacing: 0) {
                        if !l.output { Text("❯ ").foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5)) }
                        Text(l.text).foregroundStyle(l.output ? Color(red: 0.45, green: 0.85, blue: 0.55).opacity(0.8) : .white)
                        if caret, i == lines.count - 1 { Rectangle().fill(.white.opacity(0.85)).frame(width: 7, height: 13) }
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

struct Pointer: View {
    var body: some View {
        Path { p in
            p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.5, y: 13), CGPoint(x: 7.5, y: 19.5),
                        CGPoint(x: 10, y: 18.5), CGPoint(x: 7, y: 12.3), CGPoint(x: 12.5, y: 12.3)])
            p.closeSubpath()
        }
        .fill(Color.black)
        .overlay(Path { p in
            p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.5, y: 13), CGPoint(x: 7.5, y: 19.5),
                        CGPoint(x: 10, y: 18.5), CGPoint(x: 7, y: 12.3), CGPoint(x: 12.5, y: 12.3)])
            p.closeSubpath()
        }.stroke(.white, lineWidth: 1.3))
        .frame(width: 13, height: 20, alignment: .topLeading)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

// MARK: data

/// Smooth deterministic wiggle, so every render of the film is identical.
private func wave(_ i: Int, _ seed: Double) -> Double {
    let x = Double(i)
    return sin(x * 0.37 + seed) * 0.6 + sin(x * 0.11 + seed * 2.3) * 0.3 + sin(x * 1.3 + seed * 0.7) * 0.1
}

@MainActor
private func filmStore() -> Store {
    let s = Store()
    var c = Config.default
    c.left = SlotConfig(title: "load 1m", indicator: "line", unit: "", warn: 7, crit: 10, max: nil, invert: false,
                        history: 30, staleAfter: 0, blink: true)
    c.right = SlotConfig(title: "memory", indicator: "gauge", unit: "%", warn: 75, crit: 90, max: 100, invert: false,
                         history: 30, staleAfter: 0, blink: true)
    c.sources = []
    s.config = c
    s.configError = nil
    return s
}

// MARK: clips

private struct Clip {
    var name: String
    var size: CGSize
    var duration: Double
    var scale: CGFloat = 2
    var fps = 30.0
}

@MainActor
private func renderFrames(_ clip: Clip, into dir: String, _ frame: (Double) -> AnyView) {
    let out = "\(dir)/\(clip.name)"
    try? FileManager.default.removeItem(atPath: out)
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let n = Int(clip.duration * clip.fps)
    for i in 0..<n {
        let r = ImageRenderer(content: frame(Double(i) / clip.fps).frame(width: clip.size.width, height: clip.size.height))
        r.scale = clip.scale
        guard let cg = r.cgImage else { continue }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/%04d.png", out, i)))
    }
    print("\(out) (\(n) frames)")
}

@MainActor
func film(to dir: String) async {
    snapshotMode = true
    let ui = UIState()
    ui.notchWidth = 185
    ui.notchHeight = 38
    hero(dir, ui)
    indicatorsClip(dir, ui)
    alertsClip(dir, ui)
}

/// The full story: data ticking, two pings typed in a terminal, an alert, then hover to expand.
@MainActor
private func hero(_ dir: String, _ ui: UIState) {
    let store = filmStore()
    let c = store.config
    let clip = Clip(name: "hero", size: CGSize(width: 760, height: 450), duration: 12.6)
    let idle = CGSize(width: ui.notchWidth + 2 * c.wingWidth + 2 * earRadius, height: ui.notchHeight)
    let expanded = CGSize(width: c.expanded.width + 2 * earRadius, height: c.expanded.height)

    let pingL = 1.3, pingR = 2.8, alertAt = 4.4, alertDur = 3.6
    let hoverAt = 8.7, leaveAt = 11.3
    var track = ModeTrack(idle: idle, expanded: expanded)
    track.cuts += [(alertAt, .burst), (alertAt + alertDur, .idle), (hoverAt, .expanded), (leaveAt, .idle)]
    let burst = AlertBurst(alert: AlertPayload(title: "Deploy failed", summary: "api rollout stuck",
                                               severity: .crit, count: 1, url: nil), duration: alertDur)
    let info = Severity.info.color

    let commands: [(at: Double, text: String)] = [
        (pingL, #"echo '{"type":"ping","slot":"left"}' | nc -U $SOCK"#),
        (pingR, #"echo '{"type":"ping","slot":"right","color":"info"}' | nc -U $SOCK"#),
        (alertAt, #"echo '{"type":"alert","title":"Deploy failed","summary":"api rollout stuck"}' | nc -U $SOCK"#),
    ]

    // Wing data: a value every 0.9s; load spikes into warn after the alert, memory creeps up.
    let tick = 0.9
    let load = (0..<80).map { i in 3.6 + 1.1 * wave(i, 0.4) + (i > 38 ? min(Double(i - 38) * 0.45, 3.6) : 0) }
    let mem = (0..<80).map { i in 60 + 4 * wave(i, 2.1) + Double(max(0, i - 30)) * 0.55 }
    var pushed = -1
    func feed(upTo t: Double) {
        let k = 29 + Int(t / tick)
        while pushed < k {
            pushed += 1
            store.handle([.value(.left, values: [load[pushed]], replace: false, label: nil, health: nil),
                          .value(.right, values: [mem[pushed]], replace: false, label: nil, health: nil)])
        }
    }
    feed(upTo: 0)

    renderFrames(clip, into: dir) { t in
        feed(upTo: t)
        // Log entries appear when their event fires, timestamped as if it happened that long ago.
        let events: [(Double, LogEntry.Kind)] = [
            (pingL, .ping(PingEvent(slot: .left, color: Health.crit.color))),
            (pingR, .ping(PingEvent(slot: .right, color: info))),
            (alertAt, .alert(burst.alert)),
        ]
        // Ages are computed against the wall clock, so pin every timestamp to the film clock each frame.
        let now = Date()
        store.log = events.filter { $0.0 <= t }.reversed().map { LogEntry(kind: $0.1, at: now.addingTimeInterval($0.0 - t)) }
        let lastTick = now.addingTimeInterval(-(t + 0.0001).truncatingRemainder(dividingBy: tick))
        store.lastUpdate = lastTick
        store.left.updated = lastTick
        store.right.updated = lastTick

        var f = NotchFrame(size: idle, top: earRadius, bottom: 12)
        let (mode, from, s) = track.apply(t, to: &f)
        if mode == .burst {
            f.burst = burst; f.bt = t - alertAt
        } else if from == .burst, mode == .idle, s < 1 {
            f.burst = burst; f.bt = alertDur; f.live = false; f.bannerAlpha = 1 - clamp01(s * 1.6)
        }
        let sinceTick = (t + 0.0001).truncatingRemainder(dividingBy: tick)
        f.blink = [.left: blink(sinceTick), .right: blink(sinceTick - 0.05)]
        if t >= pingR { f.pulseColor = info }
        f.pulse = [.left: pulse(t - pingL), .right: pulse(t - pingR)]
        for (at, reverse, color) in [(pingL, false, Health.crit.color), (pingR, true, info)] where t >= at && t < at + 0.4 {
            f.comet = (smooth((t - at) / 0.4), color, reverse)
        }

        // Terminal: each command types out just before its event; "ok" comes back when it fires.
        var lines = [TermLine(text: "export SOCK=~/.config/polso/sock")]
        var caret = false
        for cmd in commands {
            let start = cmd.at - 1.0, end = cmd.at - 0.15
            guard t >= start else { break }
            let n = t >= end ? cmd.text.count : Int(Double(cmd.text.count) * (t - start) / (end - start))
            lines.append(TermLine(text: String(cmd.text.prefix(n))))
            if t >= cmd.at { lines.append(TermLine(text: "ok", output: true)) } else { caret = true }
        }
        if !caret, Int(t * 2) % 2 == 0 { lines.append(TermLine(text: "")); caret = true }

        // Cursor glides from the terminal up to the notch, waits, then leaves.
        let home = CGPoint(x: 560, y: 410), notch = CGPoint(x: 430, y: 22), away = CGPoint(x: 610, y: 330)
        let inP = smooth((t - (hoverAt - 0.75)) / 0.6), outP = smooth((t - (leaveAt - 0.3)) / 0.6)
        let cursor = CGPoint(x: home.x + (notch.x - home.x) * inP + (away.x - notch.x) * outP,
                             y: home.y + (notch.y - home.y) * inP + (away.y - notch.y) * outP)

        return AnyView(ZStack(alignment: .top) {
            Wallpaper()
            TerminalWindow(lines: Array(lines.suffix(6)), caret: caret)
                .frame(width: 700, height: 150)
                .position(x: clip.size.width / 2, y: 362)
            MenuBar(height: ui.notchHeight).frame(maxHeight: .infinity, alignment: .top)
            FilmNotch(store: store, ui: ui, f: f)
            Pointer().position(x: cursor.x + 6, y: cursor.y + 10)
        })
    }
}

/// The three idle styles side by side, ticking, with a ping each.
@MainActor
private func indicatorsClip(_ dir: String, _ ui: UIState) {
    let store = filmStore()
    let c = store.config
    let idle = CGSize(width: ui.notchWidth + 2 * c.wingWidth + 2 * earRadius, height: ui.notchHeight)
    let rows = ["line", "gauge", "dots"]
    let rowH: CGFloat = 76
    let clip = Clip(name: "indicators", size: CGSize(width: 470, height: rowH * 3 + 8), duration: 4.8, scale: 2.5)
    let tick = 0.6
    let load = (0..<60).map { i in 5.2 + 2.6 * wave(i, 1.1) }
    let mem = (0..<60).map { i in 74 + 12 * wave(i, 3.3) }
    var pushed = -1
    func feed(upTo t: Double) {
        let k = 29 + Int(t / tick)
        while pushed < k {
            pushed += 1
            store.handle([.value(.left, values: [load[pushed]], replace: false, label: nil, health: nil),
                          .value(.right, values: [mem[pushed]], replace: false, label: nil, health: nil)])
        }
    }
    feed(upTo: 0)
    let pings: [(row: Int, at: Double, slot: Slot)] = [(0, 0.9, .left), (1, 2.1, .right), (2, 3.3, .left)]

    func rowFrame(_ r: Int, _ id: String, _ t: Double, _ sinceTick: Double) -> NotchFrame {
        var f = NotchFrame(size: idle, top: earRadius, bottom: 12)
        f.indicators = [.left: id, .right: id]
        f.blink = [.left: blink(sinceTick), .right: blink(sinceTick - 0.05)]
        for p in pings where p.row == r {
            f.pulse[p.slot] = pulse(t - p.at)
            if t >= p.at, t < p.at + 0.4 { f.comet = (smooth((t - p.at) / 0.4), Health.crit.color, p.slot == .right) }
        }
        return f
    }

    renderFrames(clip, into: dir) { t in
        feed(upTo: t)
        let sinceTick = (t + 0.0001).truncatingRemainder(dividingBy: tick)
        return AnyView(ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, id in
                    let f = rowFrame(r, id, t, sinceTick)
                    ZStack(alignment: .top) {
                        MenuBar(height: ui.notchHeight, items: false)
                        FilmNotch(store: store, ui: ui, f: f).frame(height: rowH - 18)
                        Text(id.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.5)
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 6)
                    }
                    .frame(height: rowH)
                }
            }
        })
    }
}

/// Info, warn and crit banners back to back, the way queued alerts play.
@MainActor
private func alertsClip(_ dir: String, _ ui: UIState) {
    let store = filmStore()
    let c = store.config
    let idle = CGSize(width: ui.notchWidth + 2 * c.wingWidth + 2 * earRadius, height: ui.notchHeight)
    let dur = 2.7, gap = 0.6
    let alerts = [
        AlertPayload(title: "Backup finished", summary: "412 GB · 18 min", severity: .info, count: 1, url: nil),
        AlertPayload(title: "Disk almost full", summary: "/Volumes/data at 91%", severity: .warn, count: 1, url: nil),
        AlertPayload(title: "Deploy failed", summary: "api rollout stuck at 2/5", severity: .crit, count: 3, url: nil),
    ].map { AlertBurst(alert: $0, duration: dur) }
    let starts = alerts.indices.map { 0.4 + Double($0) * (dur + gap) }
    var track = ModeTrack(idle: idle, expanded: idle)
    for s in starts { track.cuts += [(s, .burst), (s + dur, .idle)] }
    let clip = Clip(name: "alerts", size: CGSize(width: 640, height: 250), duration: starts.last! + dur + gap)
    store.handle([.value(.left, values: (0..<30).map { 4 + wave($0, 0.2) }, replace: true, label: nil, health: nil),
                  .value(.right, values: [63], replace: true, label: nil, health: nil)])

    renderFrames(clip, into: dir) { t in
        var f = NotchFrame(size: idle, top: earRadius, bottom: 12)
        let (mode, from, s) = track.apply(t, to: &f)
        if let i = starts.lastIndex(where: { $0 <= t }) {
            if mode == .burst { f.burst = alerts[i]; f.bt = t - starts[i] }
            else if from == .burst, s < 1 { f.burst = alerts[i]; f.bt = dur; f.live = false; f.bannerAlpha = 1 - clamp01(s * 1.6) }
        }
        return AnyView(ZStack(alignment: .top) {
            Wallpaper()
            MenuBar(height: ui.notchHeight).frame(maxHeight: .infinity, alignment: .top)
            FilmNotch(store: store, ui: ui, f: f)
        })
    }
}
