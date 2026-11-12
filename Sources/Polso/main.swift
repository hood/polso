import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let ui = UIState()
    var panel: NotchPanel!
    var hoverTimer: Timer?
    var hoverSince: Date?
    var outSince: Date?
    var configSink: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = editMenu()
        panel = NotchPanel()
        let host = NSHostingView(rootView: RootView(store: store, ui: ui))
        host.sizingOptions = []
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()
        store.onSettings = { [weak self] in self?.openSettings() }
        store.start()

        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(hoverTimer!, forMode: .common)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // Panel size depends on config; @Published fires in willSet, so hop a runloop.
        configSink = store.$config.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.layout() }
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    func applicationWillTerminate(_ n: Notification) { store.stop() }

    /// Launching the app again (Finder, Spotlight, `open`) opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func openSettings() {
        setExpanded(false)
        SettingsWindow.shared.show(store: store)
    }

    /// Accessory apps have no menu bar, but key equivalents (⌘C/⌘V/⌘A/⌘W) still route through mainMenu.
    func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu!.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu!.addItem(withTitle: "Quit Polso", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    /// The screen with a camera housing, else the main one.
    var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func layout() {
        let s = screen
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            ui.notchWidth = s.frame.width - l.width - r.width
            ui.notchHeight = s.safeAreaInsets.top
        } else {
            ui.notchWidth = 160
            ui.notchHeight = NSStatusBar.system.thickness
        }
        let c = store.config
        let idleW = ui.notchWidth + 2 * c.wingWidth + 2 * AlertBurst.extraWidth
        let w = max(c.expanded.width, idleW) + 2 * earRadius + 60 // room for shadow and sparks
        let h = max(c.expanded.height, 260) + 40
        panel.setFrame(NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h), display: true)
    }

    func trackMouse() {
        let c = store.config
        guard c.expanded.enabled else { return setExpanded(false) }
        let m = NSEvent.mouseLocation
        let s = screen.frame
        let idleW = ui.notchWidth + 2 * c.wingWidth + 2 * earRadius
        // While a burst banner is down, hovering it expands too.
        let idleSz = store.burst.map { _ in AlertBurst.size(idle: CGSize(width: idleW, height: ui.notchHeight)) }
            ?? CGSize(width: idleW, height: ui.notchHeight)
        let idle = NSRect(x: s.midX - idleSz.width / 2, y: s.maxY - idleSz.height, width: idleSz.width, height: idleSz.height + 2)
        let expW = c.expanded.width + 2 * earRadius + 16
        let expanded = NSRect(x: s.midX - expW / 2, y: s.maxY - c.expanded.height - 8, width: expW, height: c.expanded.height + 10)
        let now = Date()

        if !ui.expanded {
            if idle.contains(m) {
                hoverSince = hoverSince ?? now
                if now.timeIntervalSince(hoverSince!) > 0.12 { setExpanded(true) }
            } else {
                hoverSince = nil
            }
        } else {
            if expanded.contains(m) {
                outSince = nil
            } else {
                outSince = outSince ?? now
                if now.timeIntervalSince(outSince!) > 0.25 { setExpanded(false) }
            }
        }
    }

    func setExpanded(_ e: Bool) {
        hoverSince = nil
        outSince = nil
        guard ui.expanded != e else { return }
        if e {
            store.reloadConfigIfChanged()
            layout()
            store.dismissBursts()
        }
        ui.expanded = e
        panel.ignoresMouseEvents = !e
    }
}

// MARK: snapshots

/// Renders the notch in every state with synthetic data, for eyeballing changes without a notch.
@MainActor
func snapshot(to dir: String) async {
    snapshotMode = true
    let store = Store()
    let ui = UIState()
    ui.notchWidth = 185
    ui.notchHeight = 38
    let wave = (0..<30).map { i in 3 + 2 * sin(Double(i) / 4) + Double(i) / 12 }
    store.handle([.value(.left, values: wave, replace: true, label: nil, health: nil),
                  .value(.right, values: wave.map { $0 * 14 }, replace: true, label: nil, health: nil)])

    func write(_ view: some View, _ name: String, scale: CGFloat) {
        let r = ImageRenderer(content: view.background(Color(white: 0.85)))
        r.scale = scale
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let path = "\(dir)/\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
    }

    let c = store.config
    let idle = CGSize(width: ui.notchWidth + 2 * c.wingWidth + 2 * earRadius, height: ui.notchHeight)

    for ind in Indicators.all {
        store.config.left.indicator = ind.id
        store.config.right.indicator = ind.id
        write(RootView(store: store, ui: ui).frame(width: idle.width + 40, height: idle.height + 20), "idle-\(ind.id)", scale: 3)
    }
    store.config.left.indicator = c.left.indicator
    store.config.right.indicator = c.right.indicator

    for (slot, color) in [(Slot.left, Health.crit.color), (.right, Severity.info.color)] {
        for p in [0.3, 0.7] {
            let shape = NotchShape(top: earRadius, bottom: 12)
            write(ZStack(alignment: .top) {
                shape.fill(Color.black).frame(width: idle.width, height: idle.height)
                NotchComet(top: shape.top, bottom: shape.bottom, p: p, color: color, reverse: slot == .right)
                    .frame(width: idle.width, height: idle.height)
            }.frame(width: idle.width + 40, height: idle.height + 20, alignment: .top), "comet-\(slot.rawValue)-\(p)", scale: 3)
        }
    }

    for sev in [Severity.crit, .info] {
        for t in [0.2, 0.9, 2.5] {
            store.burst = AlertBurst(alert: AlertPayload(title: "Deploy failed", summary: "api-gateway · rollout stuck",
                                                         severity: sev, count: 3, url: nil),
                                     start: Date().addingTimeInterval(-t))
            write(RootView(store: store, ui: ui).frame(width: c.expanded.width + 2 * earRadius + 60, height: 220),
                  "burst-\(sev.rawValue)-\(t)", scale: 2)
        }
    }
    store.burst = nil

    store.ping(.left)
    store.announce(AlertPayload(title: "Disk almost full", summary: "/Volumes/data 94%", severity: .warn, count: 1, url: "https://example.com"))
    store.ping(nil, color: Severity.info.color)
    store.dismissBursts()
    ui.expanded = true
    write(RootView(store: store, ui: ui).frame(width: c.expanded.width + 2 * earRadius + 40, height: c.expanded.height + 20),
          "expanded", scale: 2)
    ui.expanded = false

    // Settings tabs, rendered offscreen (Form controls are AppKit-backed, so cacheDisplay not ImageRenderer).
    let model = SettingsModel(store: store)
    model.addSource(.scrape)
    let host = NSHostingView(rootView: SettingsView(m: model) {})
    let win = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 640, height: 620),
                       styleMask: [.titled], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = host
    for tab in SettingsModel.tabs {
        model.tab = tab
        try? await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = "\(dir)/settings-\(tab).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}

// MARK: entry

signal(SIGPIPE, SIG_IGN)
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let dir = args[i + 1]
    Task { @MainActor in
        await snapshot(to: dir)
        exit(0)
    }
    RunLoop.main.run()
} else if let reply = SocketServer.send(args.contains("--settings") ? #"{"type":"settings"}"# : "",
                                        to: Config.load().0.socketPath) {
    // Already running: hand off instead of spawning a second notch.
    if !args.contains("--settings") { print("polso is already running") }
    _ = reply
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
