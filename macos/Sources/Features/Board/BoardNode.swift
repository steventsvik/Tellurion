#if os(macOS)
import AppKit

/// What every tile on the board shares, terminal or sketch: the title bar with its three
/// buttons, the resize corner, and the mouse. Dragging the title bar moves the tile (zoomed
/// out, anywhere on it does); it snaps to its neighbours' edges unless ⌘ is held, lifts while
/// dragged, and the board scrolls when it's held at the edge. Double-clicking the title bar
/// zooms in; the corner resizes.
class BoardNodeView: NSView {
    static let header: CGFloat = 30
    private static let corner: CGFloat = 16
    private static let button: CGFloat = 18

    weak var controller: BoardController?
    let nodeID: UUID
    /// The board's zoom, kept by `setZoom`.
    private(set) var zoom: CGFloat = 1

    private enum Drag { case move, resize, close, zoom, menu }
    private var drag: Drag?
    private var dragStart: (point: CGPoint, window: CGPoint, frame: CGRect)?
    private var dragMoved = false
    /// Where the pointer was at the last drag event, in the window.
    private var dragPointer: CGPoint = .zero
    private var dragSnaps = true
    /// Scrolls the board while a dragged tile is held at its edge.
    private var edgeTimer: Timer?

    init(controller: BoardController, id: UUID) {
        self.controller = controller
        self.nodeID = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: For subclasses

    /// The tile's menu (the title bar's … and a right-click on it).
    func nodeMenu() -> NSMenu? { nil }
    /// The title bar's × button.
    func nodeClose() {}
    /// Double-click on the title bar, or the zoom button: show the tile at full size.
    func nodeFocus() {}
    /// A click on the title bar that didn't move it.
    func nodeClick() {}

    /// Zoomed this far out, the tile's content is too small to use: the whole tile is a handle.
    var isHandle: Bool { zoom < 0.45 }

    func setZoom(_ zoom: CGFloat) {
        guard abs(self.zoom - zoom) > 0.001 else { return }
        self.zoom = zoom
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        if layer?.shadowOpacity ?? 0 > 0 { layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil) }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Mouse

    var closeRect: CGRect {
        CGRect(x: bounds.width - 10 - Self.button, y: (Self.header - Self.button) / 2, width: Self.button, height: Self.button)
    }

    var zoomRect: CGRect { closeRect.offsetBy(dx: -(Self.button + 8), dy: 0) }

    var menuRect: CGRect { zoomRect.offsetBy(dx: -(Self.button + 8), dy: 0) }

    /// About 16 points on screen whatever the zoom, and never more than a third of the tile.
    var cornerRect: CGRect {
        let size = min(max(Self.corner, Self.corner / max(zoom, 0.08)), bounds.width / 3, bounds.height / 3)
        return CGRect(x: bounds.width - size, y: bounds.height - size, width: size, height: size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // The title bar and the corner are the tile's; the rest is its content's.
        if isHandle || local.y < Self.header || cornerRect.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        if isHandle {
            addCursorRect(bounds, cursor: .openHand)
            return
        }
        addCursorRect(CGRect(x: 0, y: 0, width: menuRect.minX - 4, height: Self.header), cursor: .openHand)
        addCursorRect(cornerRect, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Right-click on the title bar: the tile's tools.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isHandle || convert(event.locationInWindow, from: nil).y < Self.header else { return super.menu(for: event) }
        return nodeMenu()
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        dragMoved = false
        dragPointer = event.locationInWindow
        // From the model's frame: the view's can be a fraction off after it slid.
        dragStart = (superview?.convert(event.locationInWindow, from: nil) ?? .zero, event.locationInWindow,
                     controller?.model.frames[nodeID] ?? frame)
        if isHandle {
            drag = .move
            controller?.raise(id: nodeID)
        } else if closeRect.contains(local) {
            drag = .close
        } else if zoomRect.contains(local) {
            drag = .zoom
        } else if menuRect.contains(local) {
            drag = .menu
        } else if cornerRect.contains(local) {
            drag = .resize
        } else {
            drag = .move
            controller?.raise(id: nodeID)
            if event.clickCount == 2 {
                nodeFocus()
                drag = nil
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragPointer = event.locationInWindow
        dragSnaps = !event.modifierFlags.contains(.command)
        applyDrag()
        if dragMoved { updateEdgeScroll() }
    }

    /// Moves or resizes the tile to follow the pointer (also after the board scrolls under it).
    private func applyDrag() {
        guard let start = dragStart, let controller, let superview, drag == .move || drag == .resize else { return }
        if !dragMoved {
            // A few points on screen, whatever the zoom, before a click becomes a drag.
            guard hypot(dragPointer.x - start.window.x, dragPointer.y - start.window.y) >= 3 else { return }
            dragMoved = true
            lift(true)
            if drag == .move { NSCursor.closedHand.push() }
        }
        let now = superview.convert(dragPointer, from: nil)
        let dx = now.x - start.point.x, dy = now.y - start.point.y
        var rect = drag == .move ? start.frame.offsetBy(dx: dx, dy: dy)
            : CGRect(x: start.frame.minX, y: start.frame.minY, width: start.frame.width + dx, height: start.frame.height + dy)
        var guides: [(CGPoint, CGPoint)] = []
        if dragSnaps { (rect, guides) = controller.snap(rect, for: nodeID, resizing: drag == .resize) }
        if drag == .move { controller.move(id: nodeID, to: rect) } else { controller.resize(id: nodeID, to: rect) }
        // Straight away, not on the next turn of the run loop, so the tile stays under the pointer.
        if let placed = controller.model.frames[nodeID], placed != frame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frame = placed
            CATransaction.commit()
        }
        controller.groupsView?.showGuides(guides)
    }

    /// Lifted while dragged: a soft shadow under the tile.
    private func lift(_ up: Bool) {
        guard let layer else { return }
        if up {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowRadius = 24
            layer.shadowOffset = CGSize(width: 0, height: -10)
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
        }
        let target: Float = up ? 0.55 : 0
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        fade.toValue = target
        fade.duration = up ? 0.12 : 0.22
        layer.add(fade, forKey: "lift")
        layer.shadowOpacity = target
    }

    /// Near the board's visible edge, the board scrolls that way, faster closer to the edge.
    private func updateEdgeScroll() {
        if edgeVelocity() == .zero {
            edgeTimer?.invalidate()
            edgeTimer = nil
        } else if edgeTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.edgeScrollStep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            edgeTimer = timer
        }
    }

    private func edgeVelocity() -> CGVector {
        guard let canvas = controller?.canvas else { return .zero }
        // The canvas already leaves out the list and the side panels.
        let area = canvas.convert(canvas.bounds, to: nil)
        let zone: CGFloat = 44, speed: CGFloat = 22
        func push(_ distance: CGFloat) -> CGFloat { distance < zone ? speed * (1 - max(distance, 0) / zone) : 0 }
        let p = dragPointer
        // Window points run up; the board's run down.
        let dx = push(area.maxX - p.x) - push(p.x - area.minX)
        let dy = push(p.y - area.minY) - push(area.maxY - p.y)
        return CGVector(dx: dx, dy: dy)
    }

    private func edgeScrollStep() {
        guard drag != nil, dragMoved, let canvas = controller?.canvas else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        let velocity = edgeVelocity()
        guard velocity != .zero else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        let zoom = max(canvas.magnification, 0.08)
        let visible = canvas.contentView.bounds
        var origin = CGPoint(x: visible.minX + velocity.dx / zoom, y: visible.minY + velocity.dy / zoom)
        origin.x = min(max(origin.x, 0), BoardController.boardSize.width - visible.width)
        origin.y = min(max(origin.y, 0), BoardController.boardSize.height - visible.height)
        canvas.contentView.scroll(to: origin)
        canvas.reflectScrolledClipView(canvas.contentView)
        applyDrag()
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; dragStart = nil }
        edgeTimer?.invalidate()
        edgeTimer = nil
        guard let controller else { return }
        let local = convert(event.locationInWindow, from: nil)
        if dragMoved {
            controller.groupsView?.showGuides([])
            lift(false)
            if drag == .move { NSCursor.pop() }
        }
        switch drag {
        case .close where closeRect.contains(local):
            nodeClose()
        case .zoom where zoomRect.contains(local):
            nodeFocus()
        case .menu where menuRect.contains(local):
            nodeMenu()?.popUp(positioning: nil, at: CGPoint(x: menuRect.minX, y: menuRect.maxY + 4), in: self)
        case .move where !dragMoved:
            // Zoomed out, a click goes to the tile.
            if isHandle { nodeFocus() } else { nodeClick() }
        case .move:
            controller.settleDrop(id: nodeID)
        case .resize:
            controller.tileDidSettle()
        default:
            break
        }
    }
}
#endif
