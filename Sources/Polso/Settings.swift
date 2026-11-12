import AppKit
import SwiftUI

/// Editable draft of the config. Plain ObservableObject (no @State/@Observable) so it builds
/// with the Command Line Tools too, which ship without the SwiftUI macro plugin.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var draft: Config
    @Published var labelsText: [String]   // scrape label matchers, one string per source
    @Published var results: [Int: String] = [:]
    @Published var problem: String?
    @Published var tab = "General"
    let store: Store

    static let tabs = ["General", "Left", "Right", "Sources"]

    init(store: Store) {
        self.store = store
        draft = store.config
        labelsText = store.config.sources.map { Self.format($0.labels) }
        // `--settings <Tab>` preselects a tab at launch.
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--settings"), i + 1 < a.count, Self.tabs.contains(a[i + 1]) { tab = a[i + 1] }
    }

    func resetToDefaults() {
        draft = .default
        labelsText = draft.sources.map { Self.format($0.labels) }
        results = [:]
        problem = nil
    }

    func addSource(_ kind: SourceKind) {
        var s = SourceConfig(kind: kind, slot: .left, every: 15)
        switch kind {
        case .exec: s.command = "echo 42"
        case .prometheus: s.url = "http://localhost:9090"; s.query = "up"
        case .scrape: s.url = "http://localhost:9100/metrics"; s.metric = "node_load1"
        }
        draft.sources.append(s)
        labelsText.append("")
    }

    func removeSource(_ i: Int) {
        guard i < draft.sources.count else { return }
        draft.sources.remove(at: i)
        labelsText.remove(at: i)
        results = [:]
    }

    /// The draft with text fields cleaned up and matcher strings parsed back into dictionaries.
    var cleaned: Config {
        var c = draft
        for i in c.sources.indices {
            c.sources[i].command = c.sources[i].command.map(plainQuotes)
            c.sources[i].query = c.sources[i].query.map(plainQuotes)
            let labels = Self.parse(i < labelsText.count ? labelsText[i] : "")
            c.sources[i].labels = c.sources[i].kind == .scrape && !labels.isEmpty ? labels : nil
            if c.sources[i].name?.isEmpty == true { c.sources[i].name = nil }
        }
        return c
    }

    func save() -> Bool {
        let c = cleaned
        if let p = c.validate() { problem = p; return false }
        do {
            try store.apply(c)
            problem = nil
            return true
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Runs one source once and summarises what it produced.
    func test(_ i: Int) {
        guard i < draft.sources.count else { return }
        let src = cleaned.sources[i]
        let history = draft.slot(src.slot ?? .left).history
        results[i] = "running…"
        Task {
            var state = SourceState(backfilled: true)
            do {
                var msgs = try await run(src, &state, history: history)
                if src.kind == .scrape, src.rate == true, msgs.isEmpty {
                    results[i] = "counter read, measuring rate…"
                    try await Task.sleep(for: .seconds(2))
                    msgs = try await run(src, &state, history: history)
                }
                results[i] = "ok · " + (msgs.isEmpty ? "no output" : msgs.map(Self.summary).joined(separator: ", "))
            } catch {
                results[i] = "✗ \(describe(error))"
            }
        }
    }

    static func summary(_ m: Message) -> String {
        switch m {
        case let .value(s, vs, _, label, _): "\(s.rawValue) ← \(label ?? vs.last.map { fmt($0, unit: "") } ?? "–")"
        case let .ping(s, _): "ping \(s?.rawValue ?? "")"
        case let .alert(a): "alert \"\(a.title)\""
        case .settings: "settings"
        }
    }

    static func format(_ l: [String: String]?) -> String {
        (l ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: ", ")
    }

    /// `code="500", method=GET` → ["code": "500", "method": "GET"]
    static func parse(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in plainQuotes(s).split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            out[kv[0]] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return out
    }
}

/// macOS text views may turn " into smart quotes, which breaks shell commands and PromQL.
func plainQuotes(_ s: String) -> String {
    s.replacingOccurrences(of: "[“”„]", with: "\"", options: .regularExpression)
        .replacingOccurrences(of: "[‘’]", with: "'", options: .regularExpression)
}

// MARK: window

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(store: Store) {
        if window == nil {
            let model = SettingsModel(store: store)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Polso Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(m: model) { [weak self] in self?.window?.close() })
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop the draft on close so reopening starts from the saved config.
    func windowWillClose(_ notification: Notification) { window = nil }
}

// MARK: views

let systemSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $m.tab) {
                ForEach(SettingsModel.tabs, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 14)

            Group {
                switch m.tab {
                case "Left": SlotForm(slot: .left, config: $m.draft.left, socket: m.draft.socket)
                case "Right": SlotForm(slot: .right, config: $m.draft.right, socket: m.draft.socket)
                case "Sources": SourcesForm(m: m)
                default: general
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                if let p = m.problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Reset to defaults") { m.resetToDefaults() }
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") { if m.save() { close() } }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 620)
    }

    var general: some View {
        Form {
            Section("Notch") {
                TextField("Wing width (pt)", value: $m.draft.wingWidth, format: .number)
                Toggle("Expand on hover", isOn: $m.draft.expanded.enabled)
                TextField("Expanded width (pt)", value: $m.draft.expanded.width, format: .number)
                TextField("Expanded height (pt)", value: $m.draft.expanded.height, format: .number)
                TextField("Recent events kept", value: $m.draft.expanded.logSize, format: .number)
            }
            Section {
                TextField("Socket path", text: $m.draft.socket)
            } header: {
                Text("Socket")
            } footer: {
                Text("Newline-delimited JSON, one reply line per message. Example:\n`echo '{\"type\":\"ping\"}' | nc -U \(m.draft.socket)`")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("Pings") {
                Toggle("Comet along the notch outline", isOn: $m.draft.ping.comet)
                Toggle("Glow on the target wing", isOn: $m.draft.ping.pulse)
                TextField("Default colour (ok, warn, crit, info, #rrggbb)", text: $m.draft.ping.color)
                SoundPicker(title: "Sound", sound: $m.draft.ping.sound)
                HStack {
                    Text("Preview")
                    Spacer()
                    ForEach([Slot?.some(.left), nil, .some(.right)], id: \.self) { s in
                        Button(s?.rawValue ?? "whole") { m.store.ping(s, color: parseColor(m.draft.ping.color)) }
                            .controlSize(.small)
                    }
                }
            }
            Section("Alerts") {
                TextField("Banner duration (s)", value: $m.draft.alert.duration, format: .number)
                Toggle("Queue alerts (off: newest replaces the one on screen)", isOn: $m.draft.alert.queue)
                SoundPicker(title: "Sound", sound: $m.draft.alert.sound)
                HStack {
                    Text("Preview")
                    Spacer()
                    ForEach([Severity.info, .warn, .crit], id: \.self) { sev in
                        Button(sev.rawValue) { m.store.demoAlert(sev) }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SoundPicker: View {
    var title: String
    @Binding var sound: String

    var body: some View {
        Picker(title, selection: $sound) {
            Text("None").tag("")
            ForEach(systemSounds, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: sound) { _, s in if !s.isEmpty { NSSound(named: s)?.play() } }
    }
}

struct SlotForm: View {
    var slot: Slot
    @Binding var config: SlotConfig
    var socket: String

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $config.title)
                Picker("Indicator", selection: $config.indicator) {
                    ForEach(Indicators.all, id: \.id) { k in Text(k.label).tag(k.id) }
                }
                TextField("Unit (%, ms, s, /s… or anything)", text: $config.unit)
            }
            Section {
                TextField("Warn at", value: $config.warn, format: .number, prompt: Text("none"))
                TextField("Crit at", value: $config.crit, format: .number, prompt: Text("none"))
                Toggle("Low values are bad (warn above crit)", isOn: $config.invert)
                TextField("Gauge full scale", value: $config.max, format: .number, prompt: Text("auto"))
            } header: {
                Text("Health")
            } footer: {
                Text("Leave thresholds empty to always show green. Senders can override with \"health\".")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Samples kept", value: $config.history, format: .number)
                TextField("Gray out after (s, 0 = never)", value: $config.staleAfter, format: .number)
                Toggle("Blink on every new value", isOn: $config.blink)
            } header: {
                Text("Data")
            } footer: {
                Text("`echo '{\"type\":\"value\",\"slot\":\"\(slot.rawValue)\",\"value\":42}' | nc -U \(socket)`")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct SourcesForm: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        Form {
            ForEach(m.draft.sources.indices, id: \.self) { i in
                Section {
                    source(i)
                } header: {
                    HStack {
                        Text("\(i + 1) · \(m.draft.sources[i].kind.label)")
                        Spacer()
                        Toggle("on", isOn: enabled(i)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        Button(role: .destructive) { m.removeSource(i) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                HStack {
                    ForEach(SourceKind.allCases, id: \.self) { k in
                        Button { m.addSource(k) } label: { Label(k.label, systemImage: "plus") }
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Commands print a number (goes to the picked wing) or protocol JSON (one object, an array, or one per line), so they can ping and alert too.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder func source(_ i: Int) -> some View {
        let s = src(i)
        TextField("Name", text: opt(s.name), prompt: Text("optional"))
        Picker("Wing", selection: s.slot) {
            Text("None").tag(Slot?.none)
            ForEach(Slot.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Slot?.some($0)) }
        }
        TextField("Every (s)", value: s.every, format: .number, prompt: Text("15"))
        switch s.wrappedValue.kind {
        case .exec:
            VStack(alignment: .leading) {
                Text("Command (sh -c)")
                CodeEditor(text: opt(s.command), minHeight: 40)
            }
        case .prometheus:
            TextField("Prometheus URL", text: opt(s.url))
            VStack(alignment: .leading) {
                Text("PromQL (first series is used)")
                CodeEditor(text: opt(s.query), minHeight: 40)
            }
        case .scrape:
            TextField("Metrics URL", text: opt(s.url))
            TextField("Metric name", text: opt(s.metric))
            TextField("Label matchers", text: labels(i), prompt: Text("code=\"500\", method=\"GET\""))
            Toggle("Per-second rate (counters)", isOn: Binding(get: { s.wrappedValue.rate ?? false },
                                                              set: { s.wrappedValue.rate = $0 ? true : nil }))
        }
        HStack {
            if let r = m.results[i] {
                Text(r).font(.caption).foregroundStyle(r.hasPrefix("✗") ? .red : .secondary)
                    .lineLimit(2).truncationMode(.tail).textSelection(.enabled)
            }
            Spacer()
            Button("Test") { m.test(i) }.controlSize(.small)
        }
    }

    /// Bounds-checked: a row being removed can't crash a stale binding.
    private func src(_ i: Int) -> Binding<SourceConfig> {
        Binding(get: { i < m.draft.sources.count ? m.draft.sources[i] : SourceConfig(kind: .exec) },
                set: { if i < m.draft.sources.count { m.draft.sources[i] = $0 } })
    }

    private func enabled(_ i: Int) -> Binding<Bool> {
        Binding(get: { i < m.draft.sources.count ? m.draft.sources[i].isOn : false },
                set: { if i < m.draft.sources.count { m.draft.sources[i].enabled = $0 ? nil : false } })
    }

    private func labels(_ i: Int) -> Binding<String> {
        Binding(get: { i < m.labelsText.count ? m.labelsText[i] : "" },
                set: { if i < m.labelsText.count { m.labelsText[i] = $0 } })
    }

    private func opt(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

struct CodeEditor: View {
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight, maxHeight: 80)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}
