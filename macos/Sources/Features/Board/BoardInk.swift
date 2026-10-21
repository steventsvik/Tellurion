#if os(macOS)
import AppKit

/// Ink drawn straight on the board with the pen: over tiles, cards and empty space. A stroke
/// that starts on a tile or card is pinned to it and moves with it. The eraser takes whole
/// strokes. Saved with the board; ⌘Z undoes.
struct BoardInkStroke: Codable, Identifiable, Equatable {
    let id: UUID
    /// In board points, or relative to the anchor's top-left when it has one.
    var points: [CGPoint]
    var color: Int
    var width: CGFloat
    /// The tile or card it was drawn on.
    var anchor: UUID?
}

enum BoardInk {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.97, green: 0.45, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.81, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.93, green: 0.74, blue: 0.27, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.30, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.27, green: 0.80, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.66, green: 0.52, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.55, green: 0.59, blue: 0.66, alpha: 1),
    ]
    static let widths: [CGFloat] = [1.5, 2.5, 4, 6, 9]

    static func color(_ index: Int) -> NSColor { colors[min(max(index, 0), colors.count - 1)] }

    /// A smooth path through the points (midpoint quadratic curves).
    static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

extension BoardController {
    /// Where a stroke's points are on the board now (following its anchor).
    func inkPoints(_ stroke: BoardInkStroke) -> [CGPoint]? {
        guard let anchor = stroke.anchor else { return stroke.points }
        guard let frame = model.frames[anchor] else { return nil }
        return stroke.points.map { CGPoint(x: $0.x + frame.minX, y: $0.y + frame.minY) }
    }

    /// Replaces the ink; ⌘Z puts the old back.
    func setInk(_ ink: [BoardInkStroke], action: String) {
        let old = model.ink
        guard old != ink else { return }
        model.ink = ink
        undoManager?.registerUndo(withTarget: self) { $0.setInk(old, action: action) }
        undoManager?.setActionName(action)
        scheduleSave()
    }

    /// A finished stroke, pinned to the tile or card it started on.
    func addInk(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        let anchor = model.order.reversed().first { id in
            model.frames[id]?.contains(first) == true && model.labels.allSatisfy { $0.id != id }
        }
        let origin = anchor.flatMap { model.frames[$0]?.origin } ?? .zero
        let stroke = BoardInkStroke(id: UUID(), points: points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) },
                                    color: model.inkColor, width: model.inkWidth, anchor: anchor)
        setInk(model.ink + [stroke], action: "Draw")
    }

    /// Strokes passing within `radius` of a board point.
    func inkNear(_ point: CGPoint, radius: CGFloat) -> [UUID] {
        model.ink.compactMap { stroke in
            guard let points = inkPoints(stroke) else { return nil }
            let reach = radius + stroke.width
            return points.contains { hypot($0.x - point.x, $0.y - point.y) <= reach } ? stroke.id : nil
        }
    }

    /// Closed tiles take their ink with them.
    func pruneInk() {
        let ids = Set(model.nodeIDs)
        let ink = model.ink.filter { $0.anchor.map(ids.contains) ?? true }
        if ink != model.ink { model.ink = ink }
    }
}

/// Above every tile: draws the board's ink, and takes the mouse only while the pen or the
/// eraser is the tool.
final class BoardInkView: NSView {
    weak var controller: BoardController?
    private var layers: [UUID: CAShapeLayer] = [:]
    private var drawn: [UUID: (BoardInkStroke, [CGPoint])] = [:]
    /// The stroke being drawn.
    private let live = CAShapeLayer()
    private var points: [CGPoint] = []
    /// Strokes the eraser has gone over in this drag.
    private var erasing: Set<UUID> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for layer in [live] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer?.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var inking: Bool {
        let tool = controller?.model.tool
        return tool == .pen || tool == .eraser
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard inking, let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        guard inking else { return }
        addCursorRect(bounds, cursor: controller?.model.tool == .eraser ? .disappearingItem : .crosshair)
    }

    /// Draws `ink` where its anchors are now. Only strokes that moved or changed are redone.
    func update(_ ink: [BoardInkStroke]) {
        guard let controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ids = Set(ink.map(\.id))
        for (id, layer) in layers where !ids.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
            drawn[id] = nil
        }
        for stroke in ink {
            guard let points = controller.inkPoints(stroke) else {
                layers[stroke.id]?.isHidden = true
                continue
            }
            let layer = layers[stroke.id] ?? {
                let layer = CAShapeLayer()
                layer.fillColor = nil
                layer.lineCap = .round
                layer.lineJoin = .round
                self.layer?.insertSublayer(layer, below: live)
                layers[stroke.id] = layer
                return layer
            }()
            layer.isHidden = controller.collapsedTiles.contains(stroke.anchor ?? UUID())
            if let old = drawn[stroke.id], old.0 == stroke, old.1 == points { continue }
            drawn[stroke.id] = (stroke, points)
            layer.path = BoardInk.path(points)
            layer.strokeColor = BoardInk.color(stroke.color).cgColor
            layer.lineWidth = stroke.width
            layer.opacity = erasing.contains(stroke.id) ? 0.25 : 1
        }
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        let point = convert(event.locationInWindow, from: nil)
        if controller.model.tool == .eraser {
            erasing = []
            erase(at: point)
            return
        }
        points = [point]
        live.strokeColor = BoardInk.color(controller.model.inkColor).cgColor
        live.lineWidth = controller.model.inkWidth
        live.path = BoardInk.path(points)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if controller?.model.tool == .eraser {
            erase(at: point)
            return
        }
        // Skip points closer than a screen point apart.
        let zoom = max(controller?.model.zoom ?? 1, 0.08)
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 1 / zoom { return }
        points.append(point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = BoardInk.path(points)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        if controller.model.tool == .eraser {
            let gone = erasing
            erasing = []
            if !gone.isEmpty { controller.setInk(controller.model.ink.filter { !gone.contains($0.id) }, action: "Erase") }
            return
        }
        let stroke = points
        points = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = nil
        CATransaction.commit()
        if !stroke.isEmpty { controller.addInk(stroke) }
    }

    private func erase(at point: CGPoint) {
        guard let controller else { return }
        let zoom = max(controller.model.zoom, 0.08)
        let hit = controller.inkNear(point, radius: 8 / zoom).filter { !erasing.contains($0) }
        guard !hit.isEmpty else { return }
        erasing.formUnion(hit)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in hit { layers[id]?.opacity = 0.25 }
        CATransaction.commit()
    }
}
#endif
