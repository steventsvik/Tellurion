#if os(macOS)
import AppKit
import SwiftUI

// The sidebar's continuous animations, played by Core Animation.
//
// A SwiftUI timeline makes SwiftUI lay out the whole sidebar on every frame. These play in
// the system compositor instead, so the app does no work per frame:
// - `FilmStrip` renders a SwiftUI view's loop once (one image per frame, cached) and plays
//   the images as a layer animation: the agent sprites and the living sigil look exactly
//   as their SwiftUI drawing does.
// - `FrameLights` and `BracketLights` are the travelling lights and blinking corners,
//   drawn directly as layers.
// Every loop is phased to the wall clock, so animations stay in step with each other and
// pick up where they'd be if they had been running all along.

// MARK: - Shared helpers

private extension CALayer {
    /// Plays `animation` forever, phased so it's where it would be had it started at the
    /// reference date.
    func addLoop(_ animation: CAAnimation, duration: CFTimeInterval, key: String) {
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = Motion.chromeRate
        animation.isRemovedOnCompletion = false
        animation.beginTime = convertTime(CACurrentMediaTime(), from: nil)
        animation.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)
        add(animation, forKey: key)
    }
}

/// A glow around `layer`'s rectangle, from a known shape (no offscreen pass per frame).
private func glow(_ layer: CALayer, _ color: CGColor, _ opacity: CGFloat, _ radius: CGFloat) {
    layer.shadowColor = color
    layer.shadowOpacity = Float(opacity)
    layer.shadowRadius = radius
    layer.shadowOffset = .zero
    layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
}

private func discrete(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = values
    animation.calculationMode = .discrete
    return animation
}

private extension Color {
    var cgColor: CGColor { NSColor(self).cgColor }
}

// MARK: - Film strips

/// Renders `frame(i)` for each of `frames` frames once and plays them as a loop.
struct FilmStrip<Frame: View>: NSViewRepresentable {
    /// Identifies the loop's look (cached by it): change it when the look changes.
    let key: String
    let frames: Int
    let frameDuration: TimeInterval
    let size: CGSize
    @ViewBuilder let frame: (Int) -> Frame

    final class View: NSView {
        let film = CALayer()
        var loaded = ""
        private var playing: (images: [CGImage], scale: CGFloat, duration: TimeInterval)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            film.contentsGravity = .center
            film.magnificationFilter = .nearest
            layer?.addSublayer(film)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            film.frame = bounds
            CATransaction.commit()
        }

        func play(_ images: [CGImage], scale: CGFloat, duration: TimeInterval) {
            playing = (images, scale, duration)
            film.contentsScale = scale
            film.contents = images.first
            film.removeAnimation(forKey: "film")
            guard images.count > 1, !MotionTest.off.contains("film") else { return }
            film.addLoop(discrete("contents", images), duration: duration, key: "film")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Layers drop their animations when they leave a window: start the loop again.
            if window != nil, let playing { play(playing.images, scale: playing.scale, duration: playing.duration) }
        }
    }

    func makeNSView(context: Context) -> View { View(frame: NSRect(origin: .zero, size: size)) }

    func updateNSView(_ view: View, context: Context) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let id = "\(key)|\(Int(size.width))x\(Int(size.height))@\(scale)"
        guard id != view.loaded else { return }
        view.loaded = id
        view.play(FilmCache.images(id) {
            (0..<frames).compactMap { index in
                let renderer = ImageRenderer(content: frame(index).frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, .dark))
                renderer.scale = scale
                return renderer.cgImage.flatMap(gpuReady)
            }
        }, scale: scale, duration: Double(frames) * frameDuration)
    }
}

/// The image in the GPU's own format (8-bit premultiplied BGRA, sRGB). SwiftUI renders in
/// extended-range color; left that way, the window server converts the film's current frame
/// again every time the window is composited (120 times a second while anything else on
/// screen moves). Converted once here, it's uploaded once and reused.
private func gpuReady(_ image: CGImage) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage() ?? image
}

/// Rendered loops, shared by every view showing the same thing.
enum FilmCache {
    private static var store: [String: [CGImage]] = [:]
    private static var order: [String] = []

    static func images(_ key: String, render: () -> [CGImage]) -> [CGImage] {
        if let images = store[key] { return images }
        let images = render()
        store[key] = images
        order.append(key)
        // A few dozen loops at most (sprites in each mood, the sigil's states).
        if order.count > 80 { store.removeValue(forKey: order.removeFirst()) }
        return images
    }
}

// MARK: - The terminal frame's lights

/// The four corner brackets around the terminal. They pulse when `pulse` (an agent needs
/// you) and breathe slowly when `breathe` (an agent is working). Kept to the corners and
/// eased, so the terminal's edge stays calm.
struct FrameLights: NSViewRepresentable {
    let color: Color
    var length: CGFloat = 14
    var pulse = false
    var breathe = false

    final class View: NSView {
        struct Config {
            let color: CGColor
            let length: CGFloat
            let pulse: Bool
            let breathe: Bool

            func matches(_ other: Config) -> Bool {
                color == other.color && length == other.length && pulse == other.pulse && breathe == other.breathe
            }
        }

        let corners = CALayer()
        var config: Config?
        var built: CGSize = .zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(corners)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if bounds.size != built { rebuild() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { rebuild() }
        }

        func rebuild() {
            guard let config, bounds.width > 0 else { return }
            let (color, length, pulse, breathe) = (config.color, config.length, config.pulse, config.breathe)
            built = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            corners.frame = bounds
            corners.sublayers?.forEach { $0.removeFromSuperlayer() }
            let w = bounds.width, h = bounds.height, t: CGFloat = 2
            for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] {
                let ox = dx > 0 ? x : x - t, oy = dy > 0 ? y : y - t
                for rect in [CGRect(x: dx > 0 ? ox : x - length, y: oy, width: length, height: t),
                             CGRect(x: ox, y: dy > 0 ? oy : y - length, width: t, height: length)] {
                    let bar = CALayer()
                    bar.frame = rect
                    bar.backgroundColor = color
                    corners.addSublayer(bar)
                }
            }
            corners.removeAnimation(forKey: "pulse")
            if (pulse || breathe) && !MotionTest.off.contains("frame") {
                // Needs you: a clear but smooth amber pulse. Working: a slow breath.
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = pulse ? 0.3 : 0.45
                animation.duration = pulse ? 0.9 : 1.8
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.preferredFrameRateRange = Motion.chromeRate
                corners.add(animation, forKey: "pulse")
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        let next = View.Config(color: color.cgColor, length: length, pulse: pulse, breathe: breathe)
        if let old = view.config, old.matches(next) { return }
        view.config = next
        view.rebuild()
    }
}

// MARK: - A project group's bracket

/// The spine and corner ticks down a project group's side; a run of pixels falls down it
/// while an agent works, and the corners blink while one needs you.
struct BracketLights: NSViewRepresentable {
    let color: Color
    let state: ProjectGroupSummary.State

    final class View: NSView {
        let spine = CALayer()
        let ticks = CALayer()
        let fall = CALayer()
        var config: (CGColor, ProjectGroupSummary.State)?
        var built: CGSize = .zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            [spine, ticks, fall].forEach { layer?.addSublayer($0) }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if bounds.size != built { rebuild() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { rebuild() }
        }

        func rebuild() {
            guard let (color, state) = config, bounds.height > 0 else { return }
            built = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let t: CGFloat = 2, tick: CGFloat = 8, h = bounds.height
            let shadow = state == .working ? NSColor(Extreme.core).cgColor : color
            spine.frame = CGRect(x: 0, y: 0, width: t, height: h)
            glow(spine, shadow, 0.5, 3)
            spine.backgroundColor = NSColor(cgColor: color)?.withAlphaComponent(0.55).cgColor
            ticks.frame = bounds
            ticks.sublayers?.forEach { $0.removeFromSuperlayer() }
            let tickColor = state == .waiting ? NSColor(Extreme.warn).cgColor : color
            for rect in [CGRect(x: 0, y: 0, width: tick, height: t), CGRect(x: 0, y: h - t, width: tick, height: t),
                         CGRect(x: 0, y: 0, width: t, height: tick), CGRect(x: 0, y: h - tick, width: t, height: tick)] {
                let bar = CALayer()
                bar.frame = rect
                bar.backgroundColor = tickColor
                glow(bar, shadow, 0.5, 3)
                ticks.addSublayer(bar)
            }
            ticks.removeAnimation(forKey: "blink")
            if state == .waiting {
                let animation = discrete("opacity", [1.0, 0.25])
                animation.keyTimes = [0, 0.5]
                ticks.addLoop(animation, duration: 0.6, key: "blink")
            }
            fall.frame = bounds
            fall.sublayers?.forEach { $0.removeFromSuperlayer() }
            if state == .working && h > 20 && !MotionTest.off.contains("bracket") {
                // Five pixels falling down the spine in steps, a lap every ~1.2 s or more.
                let segment: CGFloat = 6
                let lap = max(1.2, Double(h) / 110)
                let steps = Int((h + segment * 5) / segment) + 1
                for i in 0..<5 {
                    let piece = CALayer()
                    piece.anchorPoint = .zero
                    piece.frame = CGRect(x: 0, y: -segment, width: t, height: segment - 1)
                    piece.backgroundColor = NSColor(Extreme.core).withAlphaComponent(1 - CGFloat(i) / 5).cgColor
                    glow(piece, shadow, 0.5 * (1 - CGFloat(i) / 5), 3)
                    fall.addSublayer(piece)
                    let ys = (0..<steps).map { step -> NSValue in
                        let y = CGFloat(step) * segment - CGFloat(i) * segment
                        return NSValue(point: CGPoint(x: 0, y: y >= 0 && y < h ? y : -segment * 2))
                    }
                    piece.addLoop(discrete("position", ys), duration: lap, key: "fall")
                }
            }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        let next = (color.cgColor, state)
        if let old = view.config, old.0 == next.0, old.1 == next.1 { return }
        view.config = next
        view.rebuild()
    }
}
#endif
