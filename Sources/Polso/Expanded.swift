import AppKit
import SwiftUI

struct ExpandedView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(spacing: 10) {
            // header row lives beside the physical notch
            HStack {
                HStack(spacing: 6) {
                    let w = store.worst
                    Circle().fill(w.color).frame(width: 7, height: 7).shadow(color: w.color, radius: 3)
                    Text("POLSO").font(.system(size: 11, weight: .bold, design: .rounded))
                }
                Spacer().frame(minWidth: ui.notchWidth + 20)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(store.lastUpdate.map { "\(age($0)) ago" } ?? "no data yet")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(height: ui.notchHeight)
            .padding(.horizontal, 4)

            HStack(alignment: .top, spacing: 10) {
                ForEach(Slot.allCases, id: \.self) { s in
                    KPICard(config: store.config.slot(s), state: store.state(s), health: store.health(s))
                }
            }

            PanelSection(title: "Recent · \(store.log.count)", empty: "no pings or alerts yet", isEmpty: store.log.isEmpty,
                         trailing: {
                             if !store.log.isEmpty {
                                 Button("CLEAR") { store.clearLog() }
                                     .buttonStyle(.plain).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                             }
                         }) {
                Scroll {
                    VStack(spacing: 2) {
                        ForEach(store.log) { LogRow(entry: $0) }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Footer(store: store)
        }
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }
}

struct KPICard: View {
    var config: SlotConfig
    var state: SlotState
    var health: Health

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(config.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(health.label).font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(health.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(health.color)
            }
            Text(state.label ?? fmt(state.value, unit: config.unit))
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(health.color)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.5)
            Sparkline(values: state.history, color: health.color, floor: config.warn ?? 0, lineWidth: 1.5, fill: true,
                      guides: config.guides)
                .frame(height: 36)
            HStack {
                Text("\(state.history.count) samples"); Spacer()
                Text(thresholds); Spacer()
                Text(state.updated.map { age($0) } ?? "–")
            }
            .font(.system(size: 8.5)).foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var thresholds: String {
        [config.warn.map { "warn \(fmt($0, unit: config.unit))" }, config.crit.map { "crit \(fmt($0, unit: config.unit))" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct LogRow: View {
    var entry: LogEntry

    var body: some View {
        Group {
            switch entry.kind {
            case let .ping(p):
                row(icon: "dot.radiowaves.left.and.right", color: p.color,
                    title: "ping", detail: p.slot.map { "\($0.rawValue) wing" } ?? "whole notch", count: 1)
            case let .alert(a):
                if let u = a.url.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(u) } label: {
                        row(icon: a.severity.icon, color: a.severity.color, title: a.title, detail: a.summary,
                            count: a.count, link: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(u.absoluteString)
                } else {
                    row(icon: a.severity.icon, color: a.severity.color, title: a.title, detail: a.summary, count: a.count)
                }
            }
        }
    }

    func row(icon: String, color: Color, title: String, detail: String?, count: Int, link: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(title).lineLimit(1).truncationMode(.middle)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if count > 1 { Text("×\(count)").monospacedDigit().foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                Text(age(entry.at)).monospacedDigit().foregroundStyle(.secondary)
            }
            if link { Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// ImageRenderer can't draw ScrollView contents, so snapshots render them flat and clipped.
nonisolated(unsafe) var snapshotMode = false

struct Scroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if snapshotMode {
            Color.clear.overlay(alignment: .top) { content }.mask(Rectangle())
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}

struct PanelSection<Content: View, Trailing: View>: View {
    var title: String
    var empty: String
    var isEmpty: Bool
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.bottom, 1)
            if isEmpty {
                Text(empty).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 6)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct Footer: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 14) {
            if let e = problems.first {
                Text(e).foregroundStyle(Health.crit.color).lineLimit(1).truncationMode(.tail)
                    .help(problems.joined(separator: "\n"))
            }
            Spacer()
            link("gearshape", "settings") { SettingsWindow.shared.show(store: store) }
            link("power", "quit") { NSApp.terminate(nil) }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    var problems: [String] {
        [store.configError, store.serverError].compactMap { $0 } + store.sourceErrors.sorted { $0.key < $1.key }.map(\.value)
    }

    func link(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(text, systemImage: icon) }.buttonStyle(.plain)
    }
}
