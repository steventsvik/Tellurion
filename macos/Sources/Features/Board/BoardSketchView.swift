#if os(macOS)
import AppKit
import SwiftUI

/// A sketch on the board: a title bar like a terminal's, the drawing, and a floating toolbar.
final class BoardSketchView: BoardNodeView, NSDraggingSource, NSServicesMenuRequestor {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    let canvas: SketchCanvasView
    private let state = BoardSketchState()
    private let clip = FlippedView()
    private var headerView: NSView!
    private var overview: NSView!
    private let toolbar: SketchToolbar

    init(controller: BoardController, sketch: BoardSketch) {
        canvas = SketchCanvasView(elements: sketch.elements)
        toolbar = SketchToolbar()
        super.init(controller: controller, id: sketch.id)
        state.title = sketch.title

        clip.wantsLayer = true
        clip.layer?.cornerRadius = 9
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1.25
        clip.layer?.backgroundColor = Extreme.chrome.panel.nsColor.cgColor
        addSubview(clip)

        let header = PassiveHostingView(rootView: BoardSketchHeader(state: state))
        let overview = PassiveHostingView(rootView: BoardSketchOverview(state: state))
        header.sizingOptions = []
        overview.sizingOptions = []
        headerView = header
        self.overview = overview
        clip.addSubview(canvas)
        clip.addSubview(header)
        clip.addSubview(toolbar)
        clip.addSubview(overview)
        overview.isHidden = true

        let id = sketch.id
        canvas.onChange = { [weak controller] elements in controller?.updateSketch(id, elements: elements) }
        canvas.onToolChange = { [weak self] in self?.toolbar.sync() }
        toolbar.canvas = canvas
        toolbar.onShare = { [weak self] button in self?.share(from: button) }
        toolbar.onSend = { [weak self] in
            guard let self, let controller = self.controller else { return }
            controller.sendSketch(self.nodeID)
        }
        toolbar.sync()
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.header)
        canvas.frame = CGRect(x: 0, y: Self.header, width: bounds.width, height: max(0, bounds.height - Self.header))
        overview.frame = clip.bounds
        let size = toolbar.fittingSize(maxWidth: bounds.width - 24)
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12,
                               width: size.width, height: size.height)
    }

    func update(title: String, focused: Bool, zoom: CGFloat) {
        if state.title != title { state.title = title }
        if state.focused != focused { state.focused = focused }
        if abs(state.zoom - zoom) > 0.001 {
            state.zoom = zoom
            canvas.zoom = zoom
        }
        setZoom(zoom)
        overview.isHidden = zoom >= 0.45
        toolbar.isHidden = zoom < 0.45
        clip.layer?.borderColor = (focused ? NSColor.controlAccentColor.withAlphaComponent(0.85) : Extreme.chrome.lineStrong.nsColor).cgColor
        clip.layer?.borderWidth = focused ? 2 : 1.25
    }

    /// Puts the keyboard in the drawing.
    func focusCanvas() {
        window?.makeFirstResponder(canvas)
    }

    override func nodeMenu() -> NSMenu? {
        guard let controller else { return nil }
        // So "Import from iPhone or iPad" brings the picture here.
        focusCanvas()
        return BoardSketchMenu.menu(for: self, in: controller)
    }

    override func nodeClose() { controller?.removeSketch(nodeID) }

    // MARK: Dragging the sketch out

    /// The title bar's sketch symbol: drag it into Finder, Mail, Messages or any app to drop
    /// the sketch there as a picture.
    private var dragOutRect: CGRect { CGRect(x: 4, y: 0, width: 26, height: Self.header) }
    private var draggingOut = false

    override func resetCursorRects() {
        super.resetCursorRects()
        if !isHandle { addCursorRect(dragOutRect, cursor: .dragCopy) }
    }

    override func mouseDown(with event: NSEvent) {
        draggingOut = !isHandle && dragOutRect.contains(convert(event.locationInWindow, from: nil))
        if !draggingOut { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingOut else {
            super.mouseDragged(with: event)
            return
        }
        draggingOut = false
        guard let controller, let url = controller.exportSketch(nodeID), let image = NSImage(contentsOf: url) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // A small picture of the sketch follows the pointer.
        let longest = max(image.size.width, image.size.height, 1)
        let size = CGSize(width: image.size.width * 160 / longest, height: image.size.height * 160 / longest)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                              contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if draggingOut {
            draggingOut = false
            return
        }
        super.mouseUp(with: event)
    }

    override func nodeFocus() {
        controller?.zoom(toNode: nodeID)
        focusCanvas()
    }

    override func nodeClick() { focusCanvas() }

    // The title bar's menu asks the sketch, not its drawing, whether it takes a picture from
    // an iPhone or iPad; it does, and the picture goes into the drawing.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        canvas.validRequestor(forSendType: sendType, returnType: returnType) as? SketchCanvasView === canvas
            ? self : super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        canvas.readSelection(from: pasteboard)
    }

    func share(from view: NSView) {
        guard let url = controller?.exportSketch(nodeID) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// What the sketch's SwiftUI parts show.
final class BoardSketchState: ObservableObject {
    @Published var title = "Sketch"
    @Published var focused = false
    @Published var zoom: CGFloat = 1
}

private struct BoardSketchHeader: View {
    @ObservedObject var state: BoardSketchState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scribble.variable").font(.system(size: 11, weight: .medium)).foregroundColor(Extreme.muted)
            Text(state.title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
            Spacer(minLength: 4)
            glyph("ellipsis")
            glyph("arrow.up.left.and.arrow.down.right")
            glyph("xmark")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.focused ? Extreme.raised : Extreme.panel)
        .overlay(Rectangle().fill(Extreme.line).frame(height: 1), alignment: .bottom)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundColor(Extreme.muted)
            .frame(width: 18, height: 18)
    }
}

private struct BoardSketchOverview: View {
    @ObservedObject var state: BoardSketchState

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 6) {
                Image(systemName: "scribble.variable").font(.system(size: 20, weight: .medium)).foregroundColor(Extreme.text)
                Text(state.title).font(Extreme.font(13, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 200)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Extreme.panel.opacity(0.92)))
            .scaleEffect(min(1 / max(state.zoom, 0.08), geo.size.width / 220))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Toolbar

/// The tools, floating over the bottom of the drawing on glass: a capsule of plain symbols,
/// the chosen one tinted, then the color and line width, then pictures, sharing and agents.
final class SketchToolbar: NSView {
    weak var canvas: SketchCanvasView?
    var onShare: ((NSView) -> Void)?
    var onSend: (() -> Void)?

    private let background: NSView
    private let stack = NSStackView()
    private var toolButtons: [SketchCanvasView.Tool: NSButton] = [:]
    private let colorButton = NSButton()
    private static let tools: [SketchCanvasView.Tool] = [.select, .pen, .highlighter, .eraser, .rectangle, .ellipse,
                                                         .diamond, .database, .arrow, .line, .text]

    override init(frame: CGRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 20
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 20
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            background = blur
        }
        super.init(frame: frame)
        addSubview(background)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.detachesHiddenViews = true
        for (index, tool) in Self.tools.enumerated() {
            let button = symbolButton(tool.symbol, "\(tool.name) (\(String(tool.key).uppercased()))") { [weak self] in
                self?.canvas?.tool = tool
                self?.sync()
            }
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
            // Tools further right drop off first when the sketch is narrow.
            stack.setVisibilityPriority(index < 5 ? .mustHold : NSStackView.VisibilityPriority(rawValue: Float(800 - index * 20)), for: button)
            if tool == .eraser { stack.addArrangedSubview(separator()) }
        }
        stack.addArrangedSubview(separator())
        colorButton.isBordered = false
        colorButton.imagePosition = .imageOnly
        colorButton.toolTip = "Color and line width"
        colorButton.target = self
        colorButton.action = #selector(showColors)
        colorButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        stack.addArrangedSubview(colorButton)
        stack.setVisibilityPriority(.mustHold, for: colorButton)
        let style = symbolButton("textformat", "Style the selection: font, size, alignment, opacity, order") { [weak self] in
            guard let self, let button = self.lastButton else { return }
            self.showStyle(from: button)
        }
        stack.addArrangedSubview(style)
        stack.setVisibilityPriority(.mustHold, for: style)
        stack.addArrangedSubview(separator())
        let picture = symbolButton("photo", "Insert picture…") { [weak self] in self?.canvas?.choosePicture() }
        let share = symbolButton("square.and.arrow.up", "Share…") { [weak self] in
            guard let self, let button = self.lastButton else { return }
            self.onShare?(button)
        }
        let send = symbolButton("paperplane", "Send to agent…") { [weak self] in self?.onSend?() }
        for (button, priority) in [(picture, 500), (share, 600), (send, 700)] {
            stack.addArrangedSubview(button)
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(priority)), for: button)
        }
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The button last pressed, to show a share sheet from.
    private var lastButton: NSButton?

    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let size = stack.fittingSize
        return CGSize(width: min(size.width, max(maxWidth, 120)), height: max(size.height, 40))
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        stack.frame = bounds
        if let glass = background as? NSVisualEffectView { glass.layer?.cornerRadius = bounds.height / 2 }
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView { glass.cornerRadius = bounds.height / 2 }
    }

    /// Shows the chosen tool and color.
    func sync() {
        guard let canvas else { return }
        for (tool, button) in toolButtons {
            let on = tool == canvas.tool
            button.contentTintColor = on ? .controlAccentColor : .labelColor
            button.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : nil
        }
        colorButton.image = Self.colorWell(SketchStyle.color(canvas.color), width: canvas.width)
    }

    private static func colorWell(_ color: NSColor, width: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.separatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            // The line width, as a bar across the middle.
            NSColor.white.withAlphaComponent(0.85).setFill()
            let bar = min(width, 5)
            NSBezierPath(roundedRect: CGRect(x: 5, y: rect.midY - bar / 2, width: 8, height: bar), xRadius: bar / 2, yRadius: bar / 2).fill()
            return true
        }
    }

    private func showStyle(from button: NSView) {
        guard let canvas else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SketchStylePanel(canvas: canvas))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    @objc private func showColors(_ sender: NSButton) {
        guard let canvas else { return }
        let menu = SketchCanvasView.colorMenu(current: canvas.color) { [weak self, weak canvas] index in
            canvas?.color = index
            self?.sync()
        }
        menu.addItem(.separator())
        for entry in SketchStyle.widths {
            let item = ClosureMenuItem(entry.name, image: nil) { [weak self, weak canvas] in
                canvas?.width = entry.width
                self?.sync()
            }
            item.state = canvas.width == entry.width ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func symbolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.onPress = { [weak self, weak button] in self?.lastButton = button }
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.cornerCurve = .continuous
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private let run: () -> Void
    var onPress: (() -> Void)?

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func fire() {
        onPress?()
        run()
    }
}

// MARK: - Menu

enum BoardSketchMenu {
    static func menu(for view: BoardSketchView, in board: BoardController) -> NSMenu {
        let id = view.nodeID
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show at Full Size", image: nil) { [weak view] in view?.nodeFocus() })
        menu.addItem(ClosureMenuItem("Rename Sketch…", image: nil) { [weak board] in board?.promptSketchTitle(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Send to Agent…", image: nil) { [weak board] in board?.sendSketch(id) })
        menu.addItem(ClosureMenuItem("Copy as Picture", image: nil) { [weak board] in board?.copySketch(id) })
        menu.addItem(ClosureMenuItem("Share…", image: nil) { [weak view] in
            guard let view else { return }
            view.share(from: view)
        })
        menu.addItem(ClosureMenuItem("Save as PNG…", image: nil) { [weak board] in board?.saveSketch(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Insert Picture…", image: nil) { [weak view] in view?.canvas.choosePicture() })
        let device = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Sketch", image: nil) { [weak board] in board?.removeSketch(id) })
        return menu
    }
}
#endif

#if os(macOS)
/// Styles the selected elements of a sketch: text color, font, size, alignment, opacity,
/// dashes, the hand-drawn look, and their order.
struct SketchStylePanel: View {
    let canvas: SketchCanvasView
    @State private var refresh = 0

    private var first: SketchElement? { canvas.selectedElements.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if first == nil {
                Text("Select something in the sketch to style it.").font(Extreme.font(12)).foregroundColor(Extreme.muted)
            } else {
                label("Color")
                HStack(spacing: 6) {
                    ForEach(SketchStyle.colors.indices, id: \.self) { index in
                        Button { apply("Change Color") { $0.color = index } } label: {
                            Circle().fill(Color(nsColor: SketchStyle.color(index))).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(first?.color == index ? Extreme.core : .clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(SketchStyle.colors[index].name)
                    }
                }
                label("Font")
                HStack(spacing: 4) {
                    ForEach(SketchStyle.fonts, id: \.id) { option in
                        chip(option.name, on: (first?.font ?? "sans") == option.id) { apply("Change Font") { $0.font = option.id } }
                    }
                }
                label("Size")
                HStack(spacing: 4) {
                    ForEach(SketchStyle.sizes.indices, id: \.self) { index in
                        chip(SketchStyle.sizes[index], on: (first?.fontSize ?? 1) == index) { apply("Change Size") { $0.fontSize = index } }
                    }
                }
                label("Alignment")
                HStack(spacing: 4) {
                    ForEach(["left", "center", "right"], id: \.self) { align in
                        chip(align.capitalized, symbol: "text.align\(align)", on: first?.align == align) { apply("Align") { $0.align = align } }
                    }
                }
                label("Opacity")
                HStack {
                    Slider(value: Binding(get: { first?.opacity ?? 1 }, set: { value in apply("Opacity") { $0.opacity = value } }), in: 0.1...1)
                    Text("\(Int(((first?.opacity ?? 1) * 100).rounded()))%").font(Extreme.mono(11)).foregroundColor(Extreme.muted).frame(width: 40)
                }
                HStack(spacing: 4) {
                    chip("Dashed", on: first?.dashed == true) { apply("Dashed") { $0.dashed = $0.dashed == true ? nil : true } }
                    chip("Hand-drawn", on: first?.hand == true) { apply("Hand-drawn") { $0.hand = $0.hand == true ? nil : true } }
                }
                Divider()
                HStack(spacing: 4) {
                    chip("Forward", symbol: "square.2.layers.3d.top.filled", on: false) { canvas.bringForward(); refresh += 1 }
                    chip("Backward", symbol: "square.2.layers.3d.bottom.filled", on: false) { canvas.sendBackward(); refresh += 1 }
                    chip("Duplicate", symbol: "plus.square.on.square", on: false) { canvas.duplicate(nil); refresh += 1 }
                    chip("Delete", symbol: "trash", on: false) { canvas.deleteSelected(); refresh += 1 }
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .id(refresh)
    }

    private func apply(_ action: String, _ change: (inout SketchElement) -> Void) {
        canvas.styleSelection(action, change)
        refresh += 1
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.6)
    }

    private func chip(_ title: String, symbol: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).help(title)
                } else {
                    Text(title).font(Extreme.font(11, weight: .medium))
                }
            }
            .foregroundColor(on ? Extreme.ink : Extreme.text)
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Extreme.core : Extreme.raised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
#endif
