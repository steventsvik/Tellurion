#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The drawing surface of a sketch tile. Draw with the pen or highlighter; drag out boxes,
/// ellipses, diamonds and databases; draw arrows from one box to another (they stay attached
/// when the boxes move); double-click anything to label it, or empty space to write. Pictures
/// come in by dropping, pasting, or from an iPhone or iPad (Continuity Camera and Sketch).
final class SketchCanvasView: NSView, NSTextViewDelegate, NSServicesMenuRequestor, NSMenuItemValidation {
    enum Tool: String, CaseIterable {
        case select, pen, highlighter, rectangle, ellipse, diamond, database, arrow, line, text, eraser

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .diamond: return "diamond"
            case .database: return "cylinder"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .text: return "textformat"
            case .eraser: return "eraser"
            }
        }

        var name: String {
            switch self {
            case .select: return "Select"
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .rectangle: return "Box"
            case .ellipse: return "Ellipse"
            case .diamond: return "Decision"
            case .database: return "Database"
            case .arrow: return "Arrow"
            case .line: return "Line"
            case .text: return "Text"
            case .eraser: return "Eraser"
            }
        }

        /// Pressed without modifiers while the sketch has the keyboard.
        var key: Character {
            switch self {
            case .select: return "v"
            case .pen: return "p"
            case .highlighter: return "h"
            case .rectangle: return "r"
            case .ellipse: return "o"
            case .diamond: return "d"
            case .database: return "b"
            case .arrow: return "a"
            case .line: return "l"
            case .text: return "t"
            case .eraser: return "e"
            }
        }

        var kind: SketchElement.Kind? {
            switch self {
            case .pen: return .pen
            case .highlighter: return .highlighter
            case .rectangle: return .rectangle
            case .ellipse: return .ellipse
            case .diamond: return .diamond
            case .database: return .database
            case .arrow: return .arrow
            case .line: return .line
            case .text: return .text
            case .select, .eraser: return nil
            }
        }
    }

    private enum Gesture {
        case drawing(SketchElement, origin: CGPoint)
        case moving(from: CGPoint, original: [SketchElement], moved: Bool)
        case resizing(UUID, original: [SketchElement], bounds: CGRect)
        case endpoint(UUID, index: Int, original: [SketchElement])
        case marquee(from: CGPoint, to: CGPoint, base: Set<UUID>)
        case erasing(original: [SketchElement])
    }

    static let pasteboardType = NSPasteboard.PasteboardType("com.steventsvik.ghostty-extreme.sketch-elements")

    private(set) var elements: [SketchElement]
    var tool: Tool = .pen { didSet { if tool != .select { selection = [] }; onToolChange?(); window?.invalidateCursorRects(for: self) } }
    var color = 0 { didSet { recolorSelection() } }
    var width: CGFloat = 2.5 { didSet { rewidthSelection() } }
    /// The board's zoom, so handles and slop stay the same size on screen.
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Called with the elements after every change, to save them.
    var onChange: (([SketchElement]) -> Void)?
    var onToolChange: (() -> Void)?

    private var selection: Set<UUID> = [] {
        didSet {
            guard selection != oldValue else { return }
            needsDisplay = true
            onSelectionChange?()
        }
    }
    /// The selection changed (the style panel follows it).
    var onSelectionChange: (() -> Void)?

    var selectedElements: [SketchElement] { elements.filter { selection.contains($0.id) } }

    /// Changes the selected elements' style as one undoable step.
    func styleSelection(_ action: String, _ change: (inout SketchElement) -> Void) {
        guard !selection.isEmpty else { return }
        let old = elements
        for index in elements.indices where selection.contains(elements[index].id) {
            change(&elements[index])
            // A text's box follows its new font and size.
            if elements[index].kind == .text {
                let element = elements[index]
                elements[index].frame.size.height = textHeight(element.text ?? "", width: element.frame.width,
                                                               font: SketchStyle.font(element, label: false))
            }
        }
        commit(from: old, action)
    }

    func bringForward() { restack(front: true) }
    func sendBackward() { restack(front: false) }
    func deleteSelected() { deleteSelection() }
    private var gesture: Gesture?
    /// The elements before the current gesture, for undoing it as one step.
    private var undoBase: [SketchElement] = []
    private var hoverTarget: UUID?
    private var editor: NSTextView?
    private var editing: UUID?
    private let undo = UndoManager()

    init(elements: [SketchElement]) {
        self.elements = elements.map(\.repaired)
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff, Self.pasteboardType])
        _ = Self.registerReturnTypes
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { undo }

    private var slop: CGFloat { 5 / max(zoom, 0.1) }

    // MARK: Changes

    /// Makes a change undoable and saves it.
    private func commit(from old: [SketchElement], _ action: String) {
        guard old != elements else { return }
        undo.registerUndo(withTarget: self) { canvas in
            let now = canvas.elements
            canvas.elements = old
            canvas.selection = canvas.selection.filter { id in old.contains { $0.id == id } }
            canvas.commit(from: now, action)
            canvas.needsDisplay = true
        }
        undo.setActionName(action)
        onChange?(elements)
        needsDisplay = true
    }

    /// Adds elements (pictures, pasted things) as one undoable step and selects them.
    func insert(_ new: [SketchElement], action: String) {
        guard !new.isEmpty else { return }
        endEditing()
        let old = elements
        elements += new
        tool = .select
        selection = Set(new.map(\.id))
        commit(from: old, action)
    }

    private func recolorSelection() {
        guard !selection.isEmpty else { return }
        let old = elements
        for i in elements.indices where selection.contains(elements[i].id) { elements[i].color = color }
        commit(from: old, "Change Color")
    }

    private func rewidthSelection() {
        guard !selection.isEmpty else { return }
        let old = elements
        for i in elements.indices where selection.contains(elements[i].id) && elements[i].kind != .text && elements[i].kind != .image {
            elements[i].width = width
        }
        commit(from: old, "Change Line Width")
    }

    /// Removes elements; arrows attached to them keep their place, unattached.
    private func remove(_ ids: Set<UUID>) {
        let snapshot = elements
        for i in elements.indices where elements[i].kind.isConnector {
            let (a, b) = elements[i].connectorEnds(in: snapshot)
            if let start = elements[i].start, ids.contains(start) { elements[i].start = nil; elements[i].points[0] = a }
            if let end = elements[i].end, ids.contains(end) { elements[i].end = nil; elements[i].points[1] = b }
        }
        elements.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Faint dots, like the board's.
        let spacing: CGFloat = 24
        context.setFillColor(NSColor.tertiaryLabelColor.withAlphaComponent(0.35).cgColor)
        var y = floor(dirtyRect.minY / spacing) * spacing
        var dots: [CGRect] = []
        while y <= dirtyRect.maxY {
            var x = floor(dirtyRect.minX / spacing) * spacing
            while x <= dirtyRect.maxX {
                dots.append(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                x += spacing
            }
            y += spacing
        }
        context.fill(dots)

        var shown = elements
        if case .drawing(let element, _) = gesture { shown.append(element) }
        SketchRenderer.draw(shown, images: BoardSketchImages.image, in: context, editing: editing)
        drawSelection(in: context, shown: shown)
    }

    private func drawSelection(in context: CGContext, shown: [SketchElement]) {
        let accent = NSColor.controlAccentColor
        let line = 1.5 / max(zoom, 0.1)
        if let target = hoverTarget, let element = shown.first(where: { $0.id == target }) {
            context.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(line * 2)
            context.addPath(SketchRenderer.shapePath(element.kind == .ellipse || element.kind == .diamond ? element.kind : .rectangle,
                                                     element.frame.insetBy(dx: -4, dy: -4)))
            context.strokePath()
        }
        if case .marquee(let from, let to, _) = gesture {
            let rect = CGRect(from: from, to: to)
            context.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            context.fill(rect)
            context.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(line)
            context.stroke(rect)
        }
        for element in shown where selection.contains(element.id) {
            context.setStrokeColor(accent.cgColor)
            context.setLineWidth(line)
            if element.kind.isConnector {
                let (a, b) = element.connectorEnds(in: shown)
                for point in [a, b] { drawHandle(point, in: context) }
            } else {
                let rect = element.bounds(in: shown).insetBy(dx: -3, dy: -3)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.strokePath()
                if selection.count == 1 { drawHandle(CGPoint(x: rect.maxX, y: rect.maxY), in: context) }
            }
        }
    }

    private func drawHandle(_ point: CGPoint, in context: CGContext) {
        let r = 5 / max(zoom, 0.1)
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / max(zoom, 0.1))
        context.strokeEllipse(in: rect)
    }

    override func resetCursorRects() {
        switch tool {
        case .select: addCursorRect(bounds, cursor: .arrow)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    // MARK: Finding things

    private func element(at point: CGPoint, kinds: ((SketchElement.Kind) -> Bool)? = nil) -> SketchElement? {
        elements.reversed().first { (kinds?($0.kind) ?? true) && $0.hit(point, slop: slop, in: elements) }
    }

    /// The box an arrow end at `point` attaches to.
    private func target(at point: CGPoint, except: UUID? = nil) -> UUID? {
        element(at: point) { $0.isTarget }.flatMap { $0.id == except ? nil : $0.id }
    }

    /// The selected element's resize handle or connector end under `point`.
    private func handle(at point: CGPoint) -> (UUID, Int?)? {
        let reach = 8 / max(zoom, 0.1)
        for element in elements.reversed() where selection.contains(element.id) {
            if element.kind.isConnector {
                let (a, b) = element.connectorEnds(in: elements)
                if hypot(point.x - a.x, point.y - a.y) <= reach { return (element.id, 0) }
                if hypot(point.x - b.x, point.y - b.y) <= reach { return (element.id, 1) }
            } else if selection.count == 1 {
                let rect = element.bounds(in: elements).insetBy(dx: -3, dy: -3)
                if hypot(point.x - rect.maxX, point.y - rect.maxY) <= reach { return (element.id, nil) }
            }
        }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let wasEditing = editor != nil
        endEditing()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        undoBase = elements

        if event.clickCount == 2, tool == .select || tool.kind?.isBox == true || tool == .text {
            if let hit = element(at: point), hit.kind != .image, !hit.kind.isStroke {
                beginEditing(hit.id)
            } else if element(at: point) == nil {
                addText(at: point)
            }
            return
        }

        switch tool {
        case .select:
            if let (id, index) = handle(at: point) {
                if let index {
                    gesture = .endpoint(id, index: index, original: elements)
                } else {
                    gesture = .resizing(id, original: elements,
                                        bounds: elements.first { $0.id == id }?.bounds(in: elements) ?? .zero)
                }
            } else if let hit = element(at: point) {
                if event.modifierFlags.contains(.shift) {
                    if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                } else if !selection.contains(hit.id) {
                    selection = [hit.id]
                }
                var original = elements
                // ⌥-drag leaves a copy behind.
                if event.modifierFlags.contains(.option), !selection.isEmpty {
                    let copies = duplicates(of: selection, offset: .zero)
                    original += copies.elements
                    elements = original
                    selection = copies.ids
                    original = elements
                    gesture = .moving(from: point, original: original, moved: true)
                    return
                }
                gesture = .moving(from: point, original: original, moved: false)
            } else {
                gesture = .marquee(from: point, to: point, base: event.modifierFlags.contains(.shift) ? selection : [])
                if !event.modifierFlags.contains(.shift) { selection = [] }
            }
        case .text:
            if !wasEditing { addText(at: point) }
        case .eraser:
            gesture = .erasing(original: elements)
            erase(at: point)
        default:
            guard let kind = tool.kind else { return }
            var element = SketchElement(kind: kind, color: color, width: width)
            if kind.isStroke {
                element.points = [point]
            } else if kind.isConnector {
                element.points = [point, point]
                element.start = target(at: point)
            } else {
                element.frame = CGRect(origin: point, size: .zero)
            }
            gesture = .drawing(element, origin: point)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let gesture else { return }
        switch gesture {
        case .drawing(var element, let origin):
            if element.kind.isStroke {
                if let last = element.points.last, hypot(point.x - last.x, point.y - last.y) >= 1.2 / max(zoom, 0.1) {
                    element.points.append(point)
                }
            } else if element.kind.isConnector {
                element.points[1] = point
                element.end = target(at: point, except: element.start)
                hoverTarget = element.end
            } else {
                var rect = CGRect(from: origin, to: point)
                if event.modifierFlags.contains(.shift) {
                    let side = max(rect.width, rect.height)
                    rect = CGRect(x: point.x < origin.x ? origin.x - side : origin.x,
                                  y: point.y < origin.y ? origin.y - side : origin.y, width: side, height: side)
                }
                element.frame = rect
            }
            self.gesture = .drawing(element, origin: origin)
        case .moving(let from, let original, _):
            let delta = CGSize(width: point.x - from.x, height: point.y - from.y)
            elements = original.map { element in
                guard selection.contains(element.id) else { return element }
                var moved = element
                // An arrow attached at both ends goes where its boxes go.
                if moved.kind.isConnector, moved.start != nil, moved.end != nil { return moved }
                moved.offset(by: delta)
                return moved
            }
            self.gesture = .moving(from: from, original: original, moved: true)
        case .resizing(let id, let original, let bounds):
            guard let index = original.firstIndex(where: { $0.id == id }) else { break }
            var element = original[index]
            let minimum: CGFloat = 12
            let rect = CGRect(x: bounds.minX, y: bounds.minY,
                              width: max(point.x - bounds.minX, minimum), height: max(point.y - bounds.minY, minimum))
            if element.kind.isBox {
                var frame = CGRect(x: element.frame.minX, y: element.frame.minY,
                                   width: rect.width - 3, height: rect.height - 3)
                if element.kind == .image || event.modifierFlags.contains(.shift) {
                    // Pictures keep their shape.
                    let aspect = element.frame.height > 0 ? element.frame.width / element.frame.height : 1
                    frame.size.height = frame.width / aspect
                }
                if element.kind == .text {
                    frame.size.height = textHeight(element.text ?? "", width: frame.width, font: SketchStyle.font(element, label: false))
                }
                element.frame = frame
            } else {
                element.scalePoints(from: bounds, to: rect)
            }
            elements = original
            elements[index] = element
        case .endpoint(let id, let index, let original):
            guard let i = original.firstIndex(where: { $0.id == id }) else { break }
            var element = original[i]
            let other = index == 0 ? element.end : element.start
            let attach = target(at: point, except: other)
            element.points[index] = point
            if index == 0 { element.start = attach } else { element.end = attach }
            hoverTarget = attach
            elements = original
            elements[i] = element
        case .marquee(let from, _, let base):
            let rect = CGRect(from: from, to: point)
            selection = base.union(elements.filter { rect.intersects($0.bounds(in: elements)) }.map(\.id))
            self.gesture = .marquee(from: from, to: point, base: base)
        case .erasing:
            erase(at: point)
        }
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            hoverTarget = nil
            needsDisplay = true
        }
        guard let gesture else { return }
        switch gesture {
        case .drawing(var element, let origin):
            let old = elements
            if element.kind.isStroke {
                element.points = SketchElement.simplify(element.points, tolerance: 0.5 / max(zoom, 0.1))
                elements.append(element)
                commit(from: old, "Draw")
            } else if element.kind.isConnector {
                guard let a = element.points.first, hypot(element.points[1].x - a.x, element.points[1].y - a.y) > 6 else { return }
                elements.append(element)
                commit(from: old, element.kind == .arrow ? "Draw Arrow" : "Draw Line")
                tool = .select
                selection = [element.id]
            } else {
                // A click with a shape tool puts down a shape of the usual size.
                if element.frame.width < 8 || element.frame.height < 8 {
                    let size = element.kind == .database ? CGSize(width: 120, height: 140) : CGSize(width: 160, height: 96)
                    element.frame = CGRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                                           width: size.width, height: size.height)
                }
                elements.append(element)
                commit(from: old, "Draw Shape")
                tool = .select
                selection = [element.id]
            }
        case .moving(_, let original, let moved):
            if moved || original != undoBase { commit(from: undoBase, "Move") }
        case .resizing(_, let original, _):
            commit(from: original, "Resize")
        case .endpoint(_, _, let original):
            commit(from: original, "Move Arrow")
        case .marquee:
            break
        case .erasing(let original):
            commit(from: original, "Erase")
        }
    }

    private func erase(at point: CGPoint) {
        let hit = elements.filter { $0.hit(point, slop: slop * 1.5, in: elements) }.map(\.id)
        if !hit.isEmpty { remove(Set(hit)) }
    }

    // MARK: Text

    private func addText(at point: CGPoint) {
        var element = SketchElement(kind: .text, color: color, width: width)
        element.frame = CGRect(x: point.x, y: point.y - 11, width: 40, height: textHeight("", width: 40))
        element.text = ""
        let old = elements
        elements.append(element)
        commit(from: old, "Add Text")
        tool = .select
        beginEditing(element.id)
    }

    private func textHeight(_ text: String, width: CGFloat, font: NSFont = SketchStyle.textFont) -> CGFloat {
        let string = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        return ceil(string.boundingRect(with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
    }

    /// Where the editor sits for an element: over a text, inside a box, on an arrow's middle.
    private func editorFrame(for element: SketchElement) -> CGRect {
        switch element.kind {
        case .text:
            return element.frame
        case .line, .arrow:
            let (a, b) = element.connectorEnds(in: elements)
            return CGRect(x: (a.x + b.x) / 2 - 90, y: (a.y + b.y) / 2 - 12, width: 180, height: 24)
        default:
            let inner = element.frame.insetBy(dx: 10, dy: 8)
            let height = min(inner.height, textHeight(element.text ?? "", width: inner.width, font: SketchStyle.font(element, label: true)))
            return CGRect(x: inner.minX, y: inner.midY - height / 2, width: inner.width, height: height)
        }
    }

    func beginEditing(_ id: UUID) {
        guard let element = elements.first(where: { $0.id == id }) else { return }
        endEditing()
        selection = [id]
        let text = NSTextView(frame: editorFrame(for: element))
        text.delegate = self
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        let isText = element.kind == .text
        text.font = element.kind.isConnector ? SketchStyle.labelFont(13) : SketchStyle.font(element, label: !isText)
        text.textColor = isText ? SketchStyle.color(element.color) : .labelColor
        text.alignment = element.alignment(default: isText ? .left : .center)
        text.insertionPointColor = .controlAccentColor
        text.string = element.text ?? ""
        text.selectAll(nil)
        addSubview(text)
        editor = text
        editing = id
        window?.makeFirstResponder(text)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let editor, let id = editing, let index = elements.firstIndex(where: { $0.id == id }) else { return }
        if elements[index].kind == .text {
            // A text grows as you type, up to a column, then wraps.
            let font = SketchStyle.font(elements[index], label: false)
            let line = NSAttributedString(string: editor.string, attributes: [.font: font]).size().width + 8
            let width = min(max(line, 40), max(elements[index].frame.width, 420))
            elements[index].frame.size = CGSize(width: width, height: textHeight(editor.string, width: width, font: font))
            editor.frame = elements[index].frame
        } else {
            var element = elements[index]
            element.text = editor.string
            editor.frame = editorFrame(for: element)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        endEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Escape, or ⌘Return, finishes; Return makes a new line in a text.
        if selector == #selector(cancelOperation(_:)) || (selector == #selector(insertNewline(_:))
            && (NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    private func endEditing() {
        guard let editor, let id = editing else { return }
        self.editor = nil
        editing = nil
        let words = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        let old = elements
        if elements[index].kind == .text && words.isEmpty {
            elements.remove(at: index)
            selection.remove(id)
        } else {
            elements[index].text = words.isEmpty ? nil : editor.string
        }
        commit(from: old, "Edit Text")
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            deleteSelection()
            return
        case 53: // Escape
            if !selection.isEmpty { selection = [] } else { tool = .select }
            return
        case 36, 76: // Return: label the selected box
            if selection.count == 1, let id = selection.first,
               let element = elements.first(where: { $0.id == id }), element.kind != .image, !element.kind.isStroke {
                beginEditing(id)
                return
            }
        case 123, 124, 125, 126: // Arrows nudge
            guard !selection.isEmpty else { break }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGSize
            switch event.keyCode {
            case 123: delta = CGSize(width: -step, height: 0)
            case 124: delta = CGSize(width: step, height: 0)
            case 125: delta = CGSize(width: 0, height: step)
            default: delta = CGSize(width: 0, height: -step)
            }
            let old = elements
            for i in elements.indices where selection.contains(elements[i].id) { elements[i].offset(by: delta) }
            commit(from: old, "Move")
            return
        default:
            break
        }
        if flags.isEmpty, let key = characters.first, let match = Tool.allCases.first(where: { $0.key == key }) {
            tool = match
            return
        }
        if flags.isEmpty, let digit = Int(characters), (1...SketchStyle.colors.count).contains(digit) {
            color = digit - 1
            onToolChange?()
            return
        }
        super.keyDown(with: event)
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let old = elements
        remove(selection)
        commit(from: old, "Delete")
    }

    @objc func delete(_ sender: Any?) { deleteSelection() }

    override func selectAll(_ sender: Any?) {
        tool = .select
        selection = Set(elements.map(\.id))
    }

    // MARK: Copy and paste

    /// Copies of elements with new ids, attachments between them kept.
    private func duplicates(of ids: Set<UUID>, offset: CGSize) -> (elements: [SketchElement], ids: Set<UUID>) {
        var map: [UUID: UUID] = [:]
        for element in elements where ids.contains(element.id) { map[element.id] = UUID() }
        let copies = elements.filter { ids.contains($0.id) }.map { element -> SketchElement in
            var copy = element
            copy.id = map[element.id] ?? UUID()
            copy.start = element.start.flatMap { map[$0] }
            copy.end = element.end.flatMap { map[$0] }
            if element.kind.isConnector {
                let (a, b) = element.connectorEnds(in: elements)
                copy.points = [a, b]
            }
            copy.offset(by: offset)
            return copy
        }
        return (copies, Set(copies.map(\.id)))
    }

    @objc func copy(_ sender: Any?) {
        let chosen = selection.isEmpty ? Set(elements.map(\.id)) : selection
        let picked = duplicates(of: chosen, offset: .zero).elements
        guard !picked.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? JSONEncoder().encode(picked) { pasteboard.setData(data, forType: Self.pasteboardType) }
        // A picture too, for pasting anywhere else.
        if let image = SketchRenderer.image(of: picked, images: BoardSketchImages.image, appearance: effectiveAppearance),
           let png = SketchRenderer.png(image) {
            pasteboard.setData(png, forType: .png)
        }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        read(from: NSPasteboard.general, at: nil)
    }

    @objc func duplicate(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        insert(duplicates(of: selection, offset: CGSize(width: 24, height: 24)).elements, action: "Duplicate")
    }

    /// Elements, pictures or text from a pasteboard, at `point` or in the middle of what's shown.
    @discardableResult
    func read(from pasteboard: NSPasteboard, at point: CGPoint?) -> Bool {
        let center = point ?? CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let pasted = (try? JSONDecoder().decode([SketchElement].self, from: data))?.map(\.repaired), !pasted.isEmpty {
            let first = pasted[0].bounds(in: pasted)
            let all = pasted.dropFirst().reduce(first) { $0.union($1.bounds(in: pasted)) }
            var copies: [SketchElement] = []
            var map: [UUID: UUID] = [:]
            for element in pasted { map[element.id] = UUID() }
            for element in pasted {
                var copy = element
                copy.id = map[element.id] ?? UUID()
                copy.start = element.start.flatMap { map[$0] }
                copy.end = element.end.flatMap { map[$0] }
                copy.offset(by: CGSize(width: center.x - all.midX, height: center.y - all.midY))
                copies.append(copy)
            }
            insert(copies, action: "Paste")
            return true
        }
        var images: [NSImage] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false }
                .compactMap { NSImage(contentsOf: $0) }
        }
        if images.isEmpty, let image = NSImage(pasteboard: pasteboard) { images = [image] }
        if !images.isEmpty {
            let placed = BoardSketchImages.elements(for: images, largest: 480, at: center, centered: true)
            insert(placed, action: images.count == 1 ? "Add Picture" : "Add Pictures")
            return !placed.isEmpty
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            var element = SketchElement(kind: .text, color: color)
            element.text = string
            let width = min(NSAttributedString(string: string, attributes: [.font: SketchStyle.textFont]).size().width + 8, 420)
            element.frame = CGRect(x: center.x - width / 2, y: center.y, width: width, height: textHeight(string, width: width))
            insert([element], action: "Paste")
            return true
        }
        return false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return !elements.isEmpty
        case #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)): return !selection.isEmpty
        case #selector(paste(_:)):
            let pasteboard = NSPasteboard.general
            return pasteboard.availableType(from: [Self.pasteboardType, .png, .tiff, .fileURL, .string]) != nil
        default: return true
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff, Self.pasteboardType]) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        read(from: sender.draggingPasteboard, at: convert(sender.draggingLocation, from: nil))
    }

    // MARK: From an iPhone or iPad (Continuity Camera and Sketch)

    /// macOS only offers an iPhone's camera, scanner or sketch to an app that has said it
    /// takes pictures back; until then "Import from iPhone or iPad" stays dimmed. Text stays
    /// registered too, for the terminals' Services.
    private static let registerReturnTypes: Void = {
        let text: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
        let pictures = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        NSApp.registerServicesMenuSendTypes(text, returnTypes: text + pictures)
    }()

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        read(from: pasteboard, at: nil)
    }

    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = element(at: point), !selection.contains(hit.id) { selection = [hit.id] }
        let menu = NSMenu()
        if !selection.isEmpty {
            if selection.count == 1, let id = selection.first, let element = elements.first(where: { $0.id == id }),
               element.kind != .image, !element.kind.isStroke {
                menu.addItem(ClosureMenuItem(element.kind == .text ? "Edit Text" : "Edit Label", image: nil) { [weak self] in
                    self?.beginEditing(id)
                })
            }
            let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            colors.submenu = Self.colorMenu(current: nil) { [weak self] index in self?.color = index }
            menu.addItem(colors)
            menu.addItem(ClosureMenuItem("Bring to Front", image: nil) { [weak self] in self?.restack(front: true) })
            menu.addItem(ClosureMenuItem("Send to Back", image: nil) { [weak self] in self?.restack(front: false) })
            menu.addItem(.separator())
            menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            menu.addItem(ClosureMenuItem("Duplicate", image: nil) { [weak self] in self?.duplicate(nil) })
            menu.addItem(ClosureMenuItem("Delete", image: nil) { [weak self] in self?.deleteSelection() })
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(ClosureMenuItem("Insert Picture…", image: nil) { [weak self] in self?.choosePicture() })
        // Filled in by macOS with the iPhones and iPads nearby: take a photo, scan, or sketch.
        let device = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Select All", image: nil) { [weak self] in self?.selectAll(nil) })
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        return menu
    }

    static func colorMenu(current: Int?, pick: @escaping (Int) -> Void) -> NSMenu {
        let menu = NSMenu()
        for (index, entry) in SketchStyle.colors.enumerated() {
            let item = ClosureMenuItem(entry.name, image: swatch(entry.color)) { pick(index) }
            item.state = index == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    static func swatch(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    private func restack(front: Bool) {
        let old = elements
        let chosen = elements.filter { selection.contains($0.id) }
        let rest = elements.filter { !selection.contains($0.id) }
        elements = front ? rest + chosen : chosen + rest
        commit(from: old, front ? "Bring to Front" : "Send to Back")
    }

    func choosePicture() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let pasteboard = NSPasteboard(name: .init("com.steventsvik.ghostty-extreme.sketch-insert"))
            pasteboard.clearContents()
            pasteboard.writeObjects(panel.urls as [NSURL])
            self.read(from: pasteboard, at: nil)
        }
    }

    /// The whole sketch as a picture.
    func picture() -> NSImage? {
        SketchRenderer.image(of: elements, images: BoardSketchImages.image, appearance: effectiveAppearance)
    }
}

private extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
#endif
