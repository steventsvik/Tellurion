#if os(macOS)
import AppKit

/// Big text on the board itself ("General Development"), to name areas of it. Drag to move,
/// double-click to edit, right-click for size, color and font.
struct BoardLabelNode: Codable, Identifiable, Equatable {
    enum Font: String, Codable, CaseIterable {
        case sans, hand, mono

        var title: String {
            switch self {
            case .sans: return "Sans"
            case .hand: return "Handwritten"
            case .mono: return "Monospaced"
            }
        }
    }

    let id: UUID
    var text: String
    /// 0…3: L, XL, XXL, Huge.
    var size = 1
    /// An index into BoardInk.colors.
    var color = 0
    var font = Font.hand
    var frame: CGRect = .zero

    static let sizes: [(name: String, points: CGFloat)] = [("Large", 32), ("Extra Large", 52), ("Huge", 80), ("Giant", 120)]

    var nsFont: NSFont {
        let points = Self.sizes[min(max(size, 0), Self.sizes.count - 1)].points
        switch font {
        case .sans: return .systemFont(ofSize: points, weight: .semibold)
        case .mono: return .monospacedSystemFont(ofSize: points, weight: .medium)
        case .hand: return NSFont(name: "Noteworthy-Bold", size: points) ?? NSFont(name: "Marker Felt", size: points) ?? .systemFont(ofSize: points)
        }
    }

    /// The size the text needs, with a little room.
    func fitted(at origin: CGPoint) -> CGRect {
        let size = ((text.isEmpty ? "Label" : text) as NSString).size(withAttributes: [.font: nsFont])
        return CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + 16, height: ceil(size.height) + 8)
    }
}

extension BoardController {
    /// A new label at `point`, ready to type into.
    @discardableResult
    func addLabel(at point: CGPoint, text: String = "", edit: Bool = true) -> UUID {
        var label = BoardLabelNode(id: UUID(), text: text)
        label.frame = label.fitted(at: CGPoint(x: point.x, y: point.y - 30))
        // An empty one only becomes an undo step once something is typed into it.
        if text.isEmpty { undoManager?.disableUndoRegistration() }
        setLabels(model.labels + [label], action: "New Label")
        if text.isEmpty { undoManager?.enableUndoRegistration() }
        model.frames[label.id] = label.frame
        if !model.order.contains(label.id) { model.order.append(label.id) }
        if edit { DispatchQueue.main.async { [weak self] in self?.labelView(label.id)?.beginEditing() } }
        return label.id
    }

    func setLabels(_ labels: [BoardLabelNode], action: String, undoTo: [BoardLabelNode]? = nil) {
        let old = model.labels
        guard old != labels else { return }
        model.labels = labels
        // Labels that changed (an edit, or an undone move or resize) take their frame.
        for label in labels where model.frames[label.id] == nil || old.first(where: { $0.id == label.id }) != label {
            model.frames[label.id] = label.frame
        }
        for label in old where !labels.contains(where: { $0.id == label.id }) {
            model.frames[label.id] = nil
            model.order.removeAll { $0 == label.id }
        }
        for label in labels where !model.order.contains(label.id) { model.order.append(label.id) }
        let undo = undoTo ?? old
        if undo != labels { undoManager?.registerUndo(withTarget: self) { $0.setLabels(undo, action: action) } }
        undoManager?.setActionName(action)
        scheduleSave()
    }

    func updateLabel(_ id: UUID, action: String, _ change: (inout BoardLabelNode) -> Void) {
        guard let index = model.labels.firstIndex(where: { $0.id == id }) else { return }
        var labels = model.labels
        change(&labels[index])
        // It keeps its top-left; its size follows the text.
        let origin = model.frames[id]?.origin ?? labels[index].frame.origin
        labels[index].frame = labels[index].fitted(at: origin)
        model.frames[id] = labels[index].frame
        if labels[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            labels.remove(at: index)
        }
        // A label typed into for the first time: undoing it removes it, rather than leaving
        // an empty one behind.
        let fresh = model.labels[index].text.isEmpty
        setLabels(labels, action: fresh ? "New Label" : action,
                  undoTo: fresh ? model.labels.filter { $0.id != id } : nil)
    }

    func removeLabel(_ id: UUID) {
        setLabels(model.labels.filter { $0.id != id }, action: "Delete Label")
    }

    func labelView(_ id: UUID) -> BoardLabelView? {
        canvas?.documentView?.subviews.compactMap { $0 as? BoardLabelView }.first { $0.labelID == id }
    }
}

/// One label on the board.
final class BoardLabelView: NSView, NSTextFieldDelegate {
    weak var controller: BoardController?
    let labelID: UUID
    private let field = NSTextField(labelWithString: "")
    private var dragStart: (pointer: CGPoint, frame: CGRect)?
    private var moved = false

    init(controller: BoardController, label: BoardLabelNode) {
        self.controller = controller
        labelID = label.id
        super.init(frame: label.frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.delegate = self
        addSubview(field)
        apply(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Being typed into: the board leaves it alone until it's done.
    var isEditing: Bool { field.isEditable }

    func apply(_ label: BoardLabelNode) {
        guard !isEditing else { return }
        let text = label.text.isEmpty ? "Label" : label.text
        if field.stringValue != text { field.stringValue = text }
        if field.font != label.nsFont {
            field.font = label.nsFont
            needsLayout = true
        }
        field.textColor = BoardInk.color(label.color).withAlphaComponent(label.text.isEmpty ? 0.4 : 1)
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: 8, dy: 4)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, controller?.model.tool != .pen, controller?.model.tool != .eraser else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return field.isEditable ? super.hitTest(point) : self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: Editing

    func beginEditing() {
        guard let label = controller?.model.labels.first(where: { $0.id == labelID }) else { return }
        field.isEditable = true
        field.isSelectable = true
        field.stringValue = label.text
        field.textColor = BoardInk.color(label.color)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        // Grows as you type.
        guard let controller, var label = controller.model.labels.first(where: { $0.id == labelID }) else { return }
        label.text = field.stringValue
        frame = label.fitted(at: frame.origin)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        field.isEditable = false
        field.isSelectable = false
        let text = field.stringValue
        controller?.updateLabel(labelID, action: "Edit Label") { $0.text = text }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(controller?.canvas)
            return true
        }
        return false
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginEditing()
            return
        }
        dragStart = (event.locationInWindow, frame)
        moved = false
        controller?.raise(id: labelID)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let controller else { return }
        let zoom = max(controller.model.zoom, 0.08)
        let dx = (event.locationInWindow.x - start.pointer.x) / zoom, dy = -(event.locationInWindow.y - start.pointer.y) / zoom
        guard moved || hypot(dx, dy) * zoom >= 3 else { return }
        if !moved { NSCursor.closedHand.push() }
        moved = true
        controller.move(id: labelID, to: start.frame.offsetBy(dx: dx, dy: dy))
        if let placed = controller.model.frames[labelID] { frame = placed }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard moved, let controller else { return }
        NSCursor.pop()
        let frame = self.frame
        controller.updateLabel(labelID, action: "Move Label") { $0.frame = frame }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller, let label = controller.model.labels.first(where: { $0.id == labelID }) else { return nil }
        let id = labelID
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Edit", image: nil) { [weak self] in self?.beginEditing() })
        let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (index, option) in BoardLabelNode.sizes.enumerated() {
            let item = ClosureMenuItem(option.name, image: nil) { [weak controller] in
                controller?.updateLabel(id, action: "Label Size") { $0.size = index }
            }
            item.state = label.size == index ? .on : .off
            sizes.addItem(item)
        }
        size.submenu = sizes
        menu.addItem(size)
        let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for index in BoardInk.colors.indices {
            let item = ClosureMenuItem(BoardLabelView.colorNames[index], image: BoardLabelView.swatch(BoardInk.color(index))) { [weak controller] in
                controller?.updateLabel(id, action: "Label Color") { $0.color = index }
            }
            item.state = label.color == index ? .on : .off
            colors.addItem(item)
        }
        color.submenu = colors
        menu.addItem(color)
        let font = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let fonts = NSMenu()
        for option in BoardLabelNode.Font.allCases {
            let item = ClosureMenuItem(option.title, image: nil) { [weak controller] in
                controller?.updateLabel(id, action: "Label Font") { $0.font = option }
            }
            item.state = label.font == option ? .on : .off
            fonts.addItem(item)
        }
        font.submenu = fonts
        menu.addItem(font)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Label", image: nil) { [weak controller] in controller?.removeLabel(id) })
        return menu
    }

    static let colorNames = ["White", "Orange", "Green", "Gold", "Red", "Cyan", "Purple", "Slate"]

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
#endif
