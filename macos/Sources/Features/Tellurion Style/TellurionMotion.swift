#if os(macOS)
import AppKit
import Combine
import SwiftUI

// Keeping the chrome's motion cheap.
//
// Two rules, because SwiftUI re-lays-out the whole sidebar on every animation frame:
// 1. Endless motion (pulsing dots, spinners, activity bars) runs as Core Animation on
//    layers, which the system compositor animates without waking the app.
// 2. Motion that has to be SwiftUI (pixel-art sprites, the living sigil, the wordmark
//    glint) only runs while its window is on screen: `tellurionMotion` turns false for
//    background tabs, hidden and minimized windows, so they cost nothing.

// MARK: - Is this window on screen?

private struct TellurionMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the view's window isn't visible (a background tab, minimized, covered).
    var tellurionMotion: Bool {
        get { self[TellurionMotionKey.self] }
        set { self[TellurionMotionKey.self] = newValue }
    }
}

/// Tracks whether a window is actually on screen.
final class WindowMotion: ObservableObject {
    @Published private(set) var active = true
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification]
        observers = names.map { center.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in self?.update() } }
        update()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func update() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized && window.isVisible
        if visible != active { active = visible }
    }
}

/// Test hook: `TELLURION_TEST_NOANIM=comet,spinner,bar,dot,film,bracket` turns those off, to
/// measure what each costs the window server. Empty in release builds (see `TestHooks`).
enum MotionTest {
    static let off = TestHooks.motionOff
}

/// Frame rate for the chrome's smooth motion. At the display's full 120 Hz, a sweeping bar
/// makes the window server re-composite the whole window 120 times a second (and re-render
/// the clipped sprite avatars each time); at 30 it looks the same and costs a quarter.
enum Motion {
    static let chromeRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
}

// MARK: - Core Animation primitives

/// A layer-hosting view that doesn't clip its glow.
class MotionLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Animations are dropped when a layer leaves its window; put them back on return.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartAnimations() }
    }

    func restartAnimations() {}
}

private extension Color {
    var cg: CGColor { NSColor(self).cgColor }
}

/// A dot with a ring that radiates outward (scale 1 → `spread`, fading out) when `active`.
struct RadiateDotLayer: NSViewRepresentable {
    let color: Color
    let active: Bool
    let size: CGFloat
    var spread: CGFloat = 2.6
    var period: Double = 1.6

    final class View: MotionLayerView {
        let ring = CALayer()
        let dot = CALayer()
        var size: CGFloat = 8
        var active = false
        var spread: CGFloat = 2.6
        var period = 1.6

        override init(frame: NSRect) {
            super.init(frame: frame)
            dot.shadowOffset = .zero
            layer?.addSublayer(ring)
            layer?.addSublayer(dot)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let rect = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            for shape in [ring, dot] {
                shape.frame = rect
                shape.cornerRadius = size / 2
            }
            dot.shadowRadius = 3
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
        }

        override func restartAnimations() {
            ring.removeAnimation(forKey: "radiate")
            ring.isHidden = !active
            dot.shadowOpacity = active ? 0.8 : 0
            guard active, !MotionTest.off.contains("radiate") else { return }
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = spread
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = period
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.preferredFrameRateRange = Motion.chromeRate
            ring.add(group, forKey: "radiate")
        }
    }

    func makeNSView(context: Context) -> View {
        let side = size * spread
        return View(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.dot.backgroundColor = color.cg
        view.dot.shadowColor = color.cg
        view.ring.backgroundColor = NSColor(color).withAlphaComponent(0.55).cgColor
        CATransaction.commit()
        if view.size != size { view.size = size; view.needsLayout = true }
        if view.active != active || view.spread != spread || view.period != period {
            view.active = active
            view.spread = spread
            view.period = period
            view.restartAnimations()
        }
    }
}

/// A glowing dot that pulses (opacity 1 → 0.25) when `blinking`.
struct PulseDotLayer: NSViewRepresentable {
    let color: Color
    let blinking: Bool
    let size: CGFloat
    let interval: Double

    final class View: MotionLayerView {
        let dot = CALayer()
        var blinking = false
        var interval = 0.5

        override init(frame: NSRect) {
            super.init(frame: frame)
            dot.shadowOpacity = 0.85
            dot.shadowOffset = .zero
            layer?.addSublayer(dot)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
            dot.shadowRadius = bounds.width * 0.6
            // Glows drawn from a known shape skip an offscreen render pass every frame.
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
        }

        override func restartAnimations() {
            dot.removeAnimation(forKey: "pulse")
            guard blinking, !MotionTest.off.contains("dot") else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = interval
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.preferredFrameRateRange = Motion.chromeRate
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }

    func makeNSView(context: Context) -> View { View(frame: NSRect(x: 0, y: 0, width: size, height: size)) }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.dot.backgroundColor = color.cg
        view.dot.shadowColor = color.cg
        CATransaction.commit()
        if view.blinking != blinking || view.interval != interval {
            view.blinking = blinking
            view.interval = interval
            view.restartAnimations()
        }
    }
}

/// A glowing arc turning: "working".
struct SpinnerLayer: NSViewRepresentable {
    let color: Color
    let diameter: CGFloat

    final class View: MotionLayerView {
        let spin = CALayer()
        let gradient = CAGradientLayer()
        let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            ring.fillColor = nil
            ring.strokeColor = NSColor.white.cgColor
            ring.lineCap = .round
            ring.strokeStart = 0.12
            gradient.mask = ring
            spin.addSublayer(gradient)
            spin.shadowOpacity = 0.6
            spin.shadowRadius = 2
            spin.shadowOffset = .zero
            layer?.addSublayer(spin)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spin.frame = bounds
            gradient.frame = spin.bounds
            ring.frame = spin.bounds
            let line = max(1.4, bounds.width * 0.17)
            ring.lineWidth = line
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
            spin.shadowPath = ring.path?.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 1)
            CATransaction.commit()
            if spin.animation(forKey: "spin") == nil { restartAnimations() }
        }

        override func restartAnimations() {
            spin.removeAnimation(forKey: "spin")
            if MotionTest.off.contains("spinner") { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Double.pi * 2
            turn.duration = 0.85
            turn.repeatCount = .infinity
            turn.preferredFrameRateRange = Motion.chromeRate
            spin.add(turn, forKey: "spin")
        }
    }

    func makeNSView(context: Context) -> View { View(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter)) }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.gradient.colors = [NSColor(color).withAlphaComponent(0).cgColor, color.cg]
        view.spin.shadowColor = color.cg
        CATransaction.commit()
    }
}

/// A soft glow that breathes (dim and tight, then bright and wide) behind whatever it's the
/// background of.
struct BreathingGlowLayer: NSViewRepresentable {
    let color: Color
    var period: Double = 1.6

    final class View: MotionLayerView {
        let glow = CALayer()
        var period = 1.6

        override init(frame: NSRect) {
            super.init(frame: frame)
            glow.shadowOffset = .zero
            glow.shadowOpacity = 0.2
            glow.shadowRadius = 4
            layer?.addSublayer(glow)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            // The glow of a known shape: no offscreen pass, and nothing else is drawn.
            glow.shadowPath = CGPath(ellipseIn: bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2), transform: nil)
            CATransaction.commit()
            if glow.animation(forKey: "breathe") == nil { restartAnimations() }
        }

        override func restartAnimations() {
            glow.removeAnimation(forKey: "breathe")
            guard bounds.width > 0, !MotionTest.off.contains("glow") else { return }
            let brighten = CABasicAnimation(keyPath: "shadowOpacity")
            brighten.fromValue = 0.2
            brighten.toValue = 0.6
            let widen = CABasicAnimation(keyPath: "shadowRadius")
            widen.fromValue = 4
            widen.toValue = 14
            let group = CAAnimationGroup()
            group.animations = [brighten, widen]
            group.duration = period
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.preferredFrameRateRange = Motion.chromeRate
            glow.add(group, forKey: "breathe")
        }
    }

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.glow.shadowColor = color.cg
        CATransaction.commit()
        if view.period != period {
            view.period = period
            view.restartAnimations()
        }
    }
}

/// An SF Symbol turning steadily: "checking".
struct TurningSymbolLayer: NSViewRepresentable {
    let symbol: String
    let color: Color
    var period: Double = 2.5

    final class View: MotionLayerView {
        let icon = CALayer()
        var period = 2.5
        var symbol = ""
        var color = NSColor.labelColor
        private var drawn: (symbol: String, color: NSColor, scale: CGFloat)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            // At its own size, like the symbol as an image: not stretched to the frame.
            icon.contentsGravity = .center
            layer?.addSublayer(icon)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            icon.frame = bounds
            CATransaction.commit()
            redraw()
            if icon.animation(forKey: "turn") == nil { restartAnimations() }
        }

        override func restartAnimations() {
            icon.removeAnimation(forKey: "turn")
            if MotionTest.off.contains("spinner") { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Double.pi * 2
            turn.duration = period
            turn.repeatCount = .infinity
            turn.preferredFrameRateRange = Motion.chromeRate
            icon.add(turn, forKey: "turn")
        }

        /// Draws the symbol into the layer, once per look.
        func redraw() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            if let drawn, drawn.symbol == symbol, drawn.color == color, drawn.scale == scale { return }
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            icon.contentsScale = scale
            icon.contents = image.layerContents(forContentsScale: scale)
            CATransaction.commit()
            drawn = (symbol, color, scale)
        }
    }

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        view.symbol = symbol
        view.color = NSColor(color)
        view.redraw()
        if view.period != period {
            view.period = period
            view.restartAnimations()
        }
    }
}

/// A thin track with a light sweeping along it: an agent at work.
struct ActivityBarLayer: NSViewRepresentable {
    let color: Color

    final class View: MotionLayerView {
        let track = CALayer()
        let sweep = CAGradientLayer()
        private var width: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer?.masksToBounds = true
            sweep.startPoint = CGPoint(x: 0, y: 0.5)
            sweep.endPoint = CGPoint(x: 1, y: 0.5)
            layer?.addSublayer(track)
            layer?.addSublayer(sweep)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.cornerRadius = bounds.height / 2
            track.frame = bounds
            sweep.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.35, height: bounds.height)
            sweep.position = CGPoint(x: -bounds.width, y: bounds.midY)
            CATransaction.commit()
            if bounds.width != width {
                width = bounds.width
                restartAnimations()
            }
        }

        override func restartAnimations() {
            sweep.removeAnimation(forKey: "sweep")
            guard bounds.width > 0, !MotionTest.off.contains("bar") else { return }
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -bounds.width * 0.175
            move.toValue = bounds.width * 1.175
            move.duration = 1.3
            move.repeatCount = .infinity
            move.preferredFrameRateRange = Motion.chromeRate
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sweep.add(move, forKey: "sweep")
        }
    }

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.track.backgroundColor = NSColor(color).withAlphaComponent(0.12).cgColor
        let solid = NSColor(color)
        view.sweep.colors = [solid.withAlphaComponent(0).cgColor, solid.cgColor, solid.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }
}

// MARK: - One clock for every animation

/// The sidebar's animations all tick on this one clock. Each tick of any SwiftUI timeline
/// lays out the whole sidebar; timelines that start at different moments tick at different
/// moments, so six agent sprites, the sigil, the bracket and the frame light used to cost
/// ~80 layouts a second. On a shared epoch and a common beat, their ticks coincide and
/// SwiftUI handles them in one pass: ~12 a second however many agents are working.
enum TellurionClock {
    /// Seconds per beat (12.5 a second). Slower animations use whole multiples of it.
    static let beat: TimeInterval = 0.08
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// A schedule on the shared beat; `every` is rounded to a whole number of beats.
    static func schedule(every seconds: TimeInterval) -> PeriodicTimelineSchedule {
        .periodic(from: epoch, by: max(1, (seconds / beat).rounded()) * beat)
    }
}

// MARK: - Sparse timelines

/// Ticks only for a short burst (`steps` frames across `burst` seconds) once every
/// `every` seconds, instead of continuously: for effects that move briefly then rest.
struct BurstSchedule: TimelineSchedule {
    let every: TimeInterval
    let burst: TimeInterval
    let steps: Int

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let start = startDate.timeIntervalSinceReferenceDate
        var cycle = (start / every).rounded(.down)
        var step = 0
        return AnyIterator {
            while true {
                if step > steps { step = 0; cycle += 1 }
                let date = cycle * every + burst * Double(step) / Double(steps)
                step += 1
                if date >= start - 0.001 { return Date(timeIntervalSinceReferenceDate: date) }
            }
        }
    }
}
#endif
