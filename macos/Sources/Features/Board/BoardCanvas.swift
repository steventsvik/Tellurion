#if os(macOS)
import AppKit
import SwiftUI

/// The board itself: a scroll view you pan with two fingers (or by dragging empty space) and
/// zoom with a pinch or ⌘ and the scroll wheel. Zoom is the scroll view's magnification, so
/// every tile keeps its terminal size (columns and rows) at every zoom and only its picture
/// scales; the terminals size their drawing from the window's scale, not the zoom.
final class BoardCanvasView: NSScrollView {
    weak var controller: BoardController?
    weak var grid: BoardGridView?
    private var observers: [NSObjectProtocol] = []

    private var tiles: BoardTiles?
    private var scrollMonitor: Any?
    /// Whether the two-finger gesture under way moves the board (decided when it starts).
    private var panning = false

    init(controller: BoardController) {
        self.controller = controller
        super.init(frame: .zero)
        let board = BoardDocumentView(frame: CGRect(origin: .zero, size: BoardController.boardSize))
        board.controller = controller
        documentView = board
        tiles = BoardTiles(controller: controller, document: board)

        // The board runs under the transparent title bar, and tiles there take clicks.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        allowsMagnification = true
        minMagnification = 0.08
        maxMagnification = 1
        hasVerticalScroller = false
        hasHorizontalScroller = false
        usesPredominantAxisScrolling = false
        drawsBackground = false
        contentView.drawsBackground = false
        contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            self?.grid?.needsDisplay = true
            self?.controller?.updateVisibility()
        })
        for name in [NSScrollView.didEndLiveMagnifyNotification, NSScrollView.didEndLiveScrollNotification] {
            observers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                self?.controller?.zoomDidSettle()
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            controller?.canvasDidAttach(self)
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.route(event) ?? event
                }
            }
        } else if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    /// Two fingers over a tile move the board, like over empty board, unless you're working
    /// in that tile (it has the keyboard): then they scroll its terminal, list or note. Zoomed
    /// out, or with ⌘, they always move or zoom the board. A gesture keeps its target from the
    /// first touch to the end of its momentum, so passing over a tile doesn't catch it.
    private func route(_ event: NSEvent) -> NSEvent? {
        guard let window, let point = pointer(of: event, in: window) else { return event }
        let starts = event.phase.contains(.began) || event.phase.contains(.mayBegin)
            || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if starts { panning = shouldPan(at: point, command: event.modifierFlags.contains(.command), in: window) }
        guard panning else { return event }
        scrollWheel(with: event)
        return nil
    }

    /// Where the event is in this window. Events posted by other apps (scroll tools) can come
    /// without a window, with the pointer on the screen instead.
    private func pointer(of event: NSEvent, in window: NSWindow) -> CGPoint? {
        if let target = event.window { return target === window ? event.locationInWindow : nil }
        guard window.isVisible, window.frame.contains(event.locationInWindow) else { return nil }
        return window.convertPoint(fromScreen: event.locationInWindow)
    }

    private func shouldPan(at point: CGPoint, command: Bool, in window: NSWindow) -> Bool {
        guard let frame = window.contentView?.superview,
              let hit = frame.hitTest(frame.convert(point, from: nil)),
              hit.isDescendant(of: self) else { return false }
        var view: NSView? = hit
        while let current = view, !(current is BoardNodeView) { view = current.superview }
        guard let node = view as? BoardNodeView else { return false }
        if command || node.isHandle { return true }
        guard let responder = window.firstResponder as? NSView else { return true }
        return !responder.isDescendant(of: node)
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ and the wheel zooms around the pointer, like a pinch.
        guard event.modifierFlags.contains(.command), let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        let point = documentView.convert(event.locationInWindow, from: nil)
        let target = min(max(magnification * (1 + delta), minMagnification), maxMagnification)
        setMagnification(target, centeredAt: point)
        if event.phase == .ended || event.momentumPhase == .ended || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            controller?.zoomDidSettle()
        }
    }
}

/// The board's document: as big as the board, drawing nothing itself (the dots are behind
/// the scroll view), so it costs no backing store. The tiles are its subviews; a click that
/// reaches it is on empty board: drag to move around, double-click to see everything. Folders,
/// files and pictures dropped on it from Finder or anywhere else become tiles.
final class BoardDocumentView: NSView {
    weak var controller: BoardController?
    private var panStart: (pointer: CGPoint, origin: CGPoint)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = urls.isEmpty ? (NSImage(pasteboard: pasteboard).map { [$0] } ?? []) : []
        return controller.drop(urls, images: images, at: convert(sender.draggingLocation, from: nil))
    }

    /// Right-click on empty board.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("New Terminal Here", image: nil) { [weak controller] in
            guard let controller else { return }
            controller.addTile(frame: controller.freeSpot(size: BoardController.tileSize, near: nil, around: point))
        })
        menu.addItem(ClosureMenuItem("New Sketch Here", image: nil) { [weak controller] in
            controller?.addSketch(at: point)
        })
        for kind in BoardCard.Kind.allCases {
            menu.addItem(ClosureMenuItem("New \(kind.title) Here", image: nil) { [weak controller] in
                controller?.addCard(kind, at: point)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Arrange by Project", image: nil) { [weak controller] in controller?.arrangeByProject() })
        menu.addItem(ClosureMenuItem("Show Everything", image: nil) { [weak controller] in controller?.fitAll() })
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return }
        if event.clickCount == 2 {
            controller.fitAll()
            return
        }
        panStart = (event.locationInWindow, controller.cameraOrigin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panStart else { return }
        controller?.pan(from: panStart.pointer, origin: panStart.origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard panStart != nil else { return }
        panStart = nil
        NSCursor.pop()
        controller?.zoomDidSettle()
    }
}

/// The dots behind the board, the size of the window, not the board. They follow the camera
/// and thin out as you zoom out; redrawn when the camera moves.
final class BoardGridView: NSView {
    weak var canvas: BoardCanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Extreme.chrome.ink.nsColor.setFill()
        dirtyRect.fill()
        guard let canvas else { return }
        let zoom = canvas.magnification
        let origin = canvas.contentView.bounds.origin
        // Dots at least 18 points apart on screen, whatever the zoom.
        var spacing: CGFloat = 24
        while spacing * zoom < 18 { spacing *= 2 }
        let size: CGFloat = 1.5
        let firstX = ceil(origin.x / spacing) * spacing, firstY = ceil(origin.y / spacing) * spacing
        var rects: [CGRect] = []
        var y = firstY
        while (y - origin.y) * zoom <= bounds.height {
            var x = firstX
            while (x - origin.x) * zoom <= bounds.width {
                rects.append(CGRect(x: (x - origin.x) * zoom - size / 2, y: (y - origin.y) * zoom - size / 2,
                                    width: size, height: size))
                x += spacing
            }
            y += spacing
        }
        context.setFillColor(Extreme.chrome.line.nsColor.cgColor)
        context.fill(rects)
    }
}

/// The dots and the scroll view on top of them.
final class BoardCanvasContainer: NSView {
    let grid = BoardGridView()
    let canvas: BoardCanvasView

    init(canvas: BoardCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        grid.canvas = canvas
        canvas.grid = grid
        addSubview(grid)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        grid.frame = bounds
        canvas.frame = bounds
    }
}

/// Puts the AppKit canvas in the SwiftUI window.
struct BoardCanvasRepresentable: NSViewRepresentable {
    let controller: BoardController

    func makeNSView(context: Context) -> BoardCanvasContainer {
        BoardCanvasContainer(canvas: BoardCanvasView(controller: controller))
    }

    func updateNSView(_ view: BoardCanvasContainer, context: Context) {}
}
#endif
