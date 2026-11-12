import AppKit
import SwiftUI

final class UIState: ObservableObject {
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
}

let earRadius: CGFloat = 8

/// Black notch extension: concave "ears" at the top, rounded bottom corners.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var closed = true   // false: skip the top edge, for strokes hugging the outline

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        if closed { p.closeSubpath() }
        return p
    }
}

struct RootView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    enum Mode { case idle, burst, expanded }

    var idleSize: CGSize {
        CGSize(width: ui.notchWidth + 2 * store.config.wingWidth + 2 * earRadius, height: ui.notchHeight)
    }
    var expandedSize: CGSize {
        CGSize(width: store.config.expanded.width + 2 * earRadius, height: store.config.expanded.height)
    }

    var body: some View {
        let burst = ui.expanded ? nil : store.burst
        // Ticks at display rate only while a burst plays; paused otherwise so idle CPU stays ~0.
        TimelineView(.animation(minimumInterval: nil, paused: burst == nil)) { tl in
            notch(burst: burst, t: burst.map { tl.date.timeIntervalSince($0.start) } ?? 0)
        }
    }

    func notch(burst: AlertBurst?, t: Double) -> some View {
        let mode: Mode = ui.expanded ? .expanded : burst != nil ? .burst : .idle
        let size = switch mode {
        case .idle: idleSize
        case .burst: AlertBurst.size(idle: idleSize)
        case .expanded: expandedSize
        }
        let shape = NotchShape(top: mode == .expanded ? 14 : earRadius, bottom: mode == .expanded ? 24 : mode == .burst ? 18 : 12)
        let glow = burst?.glow(t) ?? 0
        let tint = burst?.tint ?? .clear
        return ZStack(alignment: .top) {
            shape.fill(Color.black)
            if burst != nil {
                RadialGradient(colors: [tint.opacity(0.32 * glow), .clear], center: .bottom, startRadius: 0, endRadius: size.width * 0.45)
                NotchShape(top: shape.top, bottom: shape.bottom, closed: false)
                    .stroke(rimGradient(tint, t), lineWidth: 3)
                    .opacity(glow)
            }
            if mode == .expanded {
                ExpandedView(store: store, ui: ui)
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                VStack(spacing: 0) {
                    IdleView(store: store, ui: ui)
                    if let burst {
                        BurstBanner(burst: burst, t: t, width: size.width, motion: !reduceMotion)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, earRadius)
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .shadow(color: tint.opacity(0.85 * glow), radius: 16)
        .shadow(color: .black.opacity(ui.expanded ? 0.5 : 0), radius: 18, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if let burst, !reduceMotion {
                BurstCanvas(burst: burst, t: t, target: size).allowsHitTesting(false)
            }
            if mode == .idle, !reduceMotion, store.config.ping.comet {
                let ping = store.lastPing
                Color.clear
                    .keyframeAnimator(initialValue: 0.0, trigger: store.pings) { _, p in
                        NotchComet(top: shape.top, bottom: shape.bottom, p: p, color: ping.color, reverse: ping.slot == .right)
                            .frame(width: size.width, height: size.height)
                    } keyframes: { _ in
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: 0.4, timingCurve: .easeInOut)
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(Self.spring(to: mode), value: mode)
        .preferredColorScheme(.dark)
    }

    static func spring(to mode: Mode) -> Animation {
        switch mode {
        // Bouncy drop: overshoot only grows the banner, so it never exposes the hardware notch.
        case .burst: .spring(response: 0.42, dampingFraction: 0.55)
        case .expanded: .spring(response: 0.38, dampingFraction: 0.82)
        // Closing must not overshoot: an underdamped spring would briefly shrink the panel below the notch.
        case .idle: .spring(response: 0.32, dampingFraction: 1.0)
        }
    }
}

/// Head with a fading tail walking the notch outline ear to ear; `p` 0...1, invisible at both ends.
/// `reverse` runs it right to left, so a ping on the right wing starts from the right.
struct NotchComet: View {
    var top: CGFloat
    var bottom: CGFloat
    var p: Double
    var color: Color
    var reverse = false

    static let tail = 0.3
    static let segments = 16
    static let gap: CGFloat = 3   // ride outside the outline so the bottom run clears the hardware notch
    static let pad: CGFloat = 10  // Canvas clips to its bounds; bleed past the notch frame for the offset path + glow

    var body: some View {
        Canvas { ctx, full in
            guard p > 0, p < 1 else { return }
            // Offset outward by `gap`: concave ears shrink, convex bottom corners grow, so the run stays parallel.
            let d = Self.gap
            let path = NotchShape(top: top - d, bottom: bottom + d, closed: false)
                .path(in: CGRect(x: Self.pad, y: 0, width: full.width - 2 * Self.pad, height: full.height - Self.pad + d))
            let head = p * (1 + Self.tail)
            // Positions along the path, mirrored when running backwards.
            func at(_ x: Double) -> Double { reverse ? 1 - x : x }
            func trim(_ a: Double, _ b: Double) -> Path {
                reverse ? path.trimmedPath(from: at(b), to: at(a)) : path.trimmedPath(from: a, to: b)
            }
            var g = ctx
            g.addFilter(.shadow(color: color, radius: 3))
            g.drawLayer { l in
                // Stacked butt-capped layers, longer = thinner: they pile up into a smooth taper toward the head.
                let b = clamp01(head)
                for i in 0..<Self.segments {
                    let k = 1 - Double(i) / Double(Self.segments)
                    let a = clamp01(head - Self.tail * Double(i + 1) / Double(Self.segments))
                    guard b > a else { continue }
                    l.stroke(trim(a, b), with: .color(color.opacity(0.22)),
                             style: StrokeStyle(lineWidth: 0.6 + 2.2 * k, lineCap: .butt))
                }
                if head <= 1 {
                    let pt = path.trimmedPath(from: 0, to: at(head)).currentPoint ?? .zero
                    l.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)), with: .color(color))
                    l.fill(Path(ellipseIn: CGRect(x: pt.x - 1.2, y: pt.y - 1.2, width: 2.4, height: 2.4)), with: .color(.white))
                }
            }
        }
        .padding(.horizontal, -Self.pad)
        .padding(.bottom, -Self.pad)
    }
}

// MARK: idle

struct IdleView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            wing(.left)
            Spacer().frame(width: ui.notchWidth)
            wing(.right)
        }
        .frame(height: ui.notchHeight)
    }

    func wing(_ s: Slot) -> some View {
        let c = store.config.slot(s)
        let input = IndicatorInput(state: store.state(s), config: c, health: store.health(s))
        return (Indicators.find(c.indicator) ?? LineIndicator.kind).view(input)
            .refreshBlink(store.beats[s] ?? 0, enabled: c.blink && !reduceMotion)
            .pingPulse(store.wingPings[s] ?? 0, color: store.lastPing.color,
                       enabled: store.config.ping.pulse && !reduceMotion)
            .frame(width: store.config.wingWidth)
    }
}

extension View {
    /// One-shot brightness flash when `beat` changes. The animator only re-applies the filter on the
    /// placeholder content, so the meter (Canvas included) isn't redrawn per frame; idle cost stays 0.
    @ViewBuilder func refreshBlink(_ beat: Int, enabled: Bool) -> some View {
        if enabled {
            keyframeAnimator(initialValue: 0.0, trigger: beat) { content, v in
                content.brightness(v)
            } keyframes: { _ in
                CubicKeyframe(0.45, duration: 0.08)
                CubicKeyframe(0, duration: 0.42)
            }
        } else {
            self
        }
    }

    /// Two glow pulses on a wing when a ping targets it. Same one-shot animator trick as the blink.
    @ViewBuilder func pingPulse(_ trigger: Int, color: Color, enabled: Bool) -> some View {
        if enabled {
            keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, v in
                content.shadow(color: color.opacity(v), radius: 5 * v).brightness(0.25 * v)
            } keyframes: { _ in
                CubicKeyframe(1, duration: 0.12); CubicKeyframe(0.15, duration: 0.3)
                CubicKeyframe(1, duration: 0.12); CubicKeyframe(0, duration: 0.6)
            }
        } else {
            self
        }
    }
}
