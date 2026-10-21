#if os(macOS)
import AppKit
import SwiftUI

/// What a click on the board does: select and move (the usual), or place something, or draw.
enum BoardTool: String, CaseIterable, Identifiable {
    case select, agent, group, terminal, text, pen, eraser, web, image, fit

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .agent: return "sparkle"
        case .group: return "square.grid.2x2"
        case .terminal: return "terminal"
        case .text: return "textformat"
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .web: return "globe"
        case .image: return "photo"
        case .fit: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select (V)"
        case .agent: return "Agent: click to start one (A)"
        case .group: return "Group… (G)"
        case .terminal: return "Terminal: click to place (T)"
        case .text: return "Text: click to place a label (X)"
        case .pen: return "Pen (P)"
        case .eraser: return "Eraser (E)"
        case .web: return "Web: drag a box (W)"
        case .image: return "Image… (I)"
        case .fit: return "Show everything (F)"
        }
    }

    var key: String {
        switch self {
        case .select: return "v"
        case .agent: return "a"
        case .group: return "g"
        case .terminal: return "t"
        case .text: return "x"
        case .pen: return "p"
        case .eraser: return "e"
        case .web: return "w"
        case .image: return "i"
        case .fit: return "f"
        }
    }

    /// Stays on after use (drawing); the others go back to Select.
    var sticky: Bool { self == .pen || self == .eraser }
}

extension BoardController {
    /// Picks a tool. Actions (group, image, fit) run at once; placing tools wait for a click.
    func choose(_ tool: BoardTool) {
        switch tool {
        case .group:
            model.groupComposerPreset = nil
            model.showGroupComposer = true
            model.tool = .select
        case .image:
            model.tool = .select
            chooseImage(at: nil)
        case .fit:
            model.tool = .select
            fitAll()
        default:
            model.tool = model.tool == tool && tool != .select ? .select : tool
        }
        canvas?.window?.invalidateCursorRects(for: canvas?.documentView ?? NSView())
    }

    /// A click on empty board with a placing tool. Returns whether it was used.
    func place(at point: CGPoint) -> Bool {
        switch model.tool {
        case .agent:
            model.tool = .select
            let agent = ToolPath.find("claude") != nil ? "claude" : ToolPath.find("codex") != nil ? "codex" : nil
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = workspace.folder
            addTile(config: config, command: agent.map { $0 + "\n" },
                    frame: freeSpot(size: Self.tileSize, near: nil, around: point))
            return true
        case .terminal:
            model.tool = .select
            addTile(frame: freeSpot(size: Self.tileSize, near: nil, around: point))
            return true
        case .text:
            model.tool = .select
            addLabel(at: point)
            return true
        default:
            return false
        }
    }

    /// Picks a picture and puts it on the board (as a sketch holding it).
    func chooseImage(at point: CGPoint?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
            let at = point ?? self.canvas.map { CGPoint(x: $0.documentVisibleRect.midX, y: $0.documentVisibleRect.midY) } ?? .zero
            _ = self.drop([], images: images, at: at)
        }
    }

    /// V, A, G, T, X, P, E, W, I, F pick tools and Escape goes back to Select, when the
    /// keyboard isn't in a terminal or a text field.
    func installToolKeys() {
        guard toolKeyMonitor == nil else { return }
        toolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return event }
            let responder = self.window?.firstResponder
            if responder is Ghostty.SurfaceView || responder is NSTextView || responder is NSTextField { return event }
            if event.keyCode == 53, self.model.tool != .select {
                self.model.tool = .select
                return nil
            }
            guard let key = event.charactersIgnoringModifiers?.lowercased(),
                  let tool = BoardTool.allCases.first(where: { $0.key == key }) else { return event }
            self.choose(tool)
            return nil
        }
    }
}

// MARK: - Left palette

/// The tools, in a floating column at the board's left edge.
struct BoardToolPalette: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                ForEach(BoardTool.allCases) { tool in
                    if tool == .text || tool == .web || tool == .fit {
                        Rectangle().fill(Extreme.line).frame(width: 18, height: 1).padding(.vertical, 3)
                    }
                    Button { controller.choose(tool) } label: {
                        Image(systemName: tool.symbol).font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(model.tool == tool ? Extreme.ink : Extreme.text.opacity(0.85))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(model.tool == tool ? Extreme.core : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                    .accessibilityLabel(tool.title)
                }
            }
            .padding(5)
            .background(Capsule(style: .continuous).fill(Extreme.panel.opacity(0.96)))
            .overlay(Capsule(style: .continuous).strokeBorder(Extreme.lineStrong))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            if model.tool == .pen { inkFlyout }
        }
    }

    /// The pen's color and width.
    private var inkFlyout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLOR").font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.6)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 4), spacing: 6) {
                ForEach(BoardInk.colors.indices, id: \.self) { index in
                    Button { model.inkColor = index } label: {
                        Circle().fill(Color(nsColor: BoardInk.color(index))).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(model.inkColor == index ? Extreme.text : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(BoardLabelView.colorNames[index])
                }
            }
            Text("WIDTH").font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.6)
            HStack(spacing: 6) {
                ForEach(BoardInk.widths.indices, id: \.self) { index in
                    let width = BoardInk.widths[index]
                    Button { model.inkWidth = width } label: {
                        Circle().fill(Extreme.text).frame(width: 3 + width, height: 3 + width)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(model.inkWidth == width ? Extreme.core : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Width \(index + 1)")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Extreme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Extreme.lineStrong))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .transition(.opacity)
    }
}

// MARK: - Right palette

/// Board-wide tools, in a floating column at the board's right edge.
struct BoardSidePalette: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel
    @State private var showLayers = false

    var body: some View {
        VStack(spacing: 2) {
            button("square.3.layers.3d", "Layers") { showLayers.toggle() }
                .popover(isPresented: $showLayers, arrowEdge: .leading) { BoardLayersList(controller: controller, model: model) }
            button("checklist", "Tasks") { showTasks() }
            ForEach(BoardSidePalette.extras, id: \.title) { extra in
                button(extra.symbol, extra.title) { extra.run(controller) }
            }
            button("folder", "Files and changes") { showFiles() }
            button("arrow.triangle.2.circlepath", "Review loop for the focused agent") { showLoops() }
        }
        .padding(5)
        .background(Capsule(style: .continuous).fill(Extreme.panel.opacity(0.96)))
        .overlay(Capsule(style: .continuous).strokeBorder(Extreme.lineStrong))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }

    /// Tools other parts of the board add (Mission Map, Documents, Diagrams).
    static var extras: [(symbol: String, title: String, run: (BoardController) -> Void)] = []

    private func button(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Extreme.text.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func showTasks() {
        let menu = NSMenu()
        for card in model.cards where card.kind == .kanban || card.kind == .checklist {
            menu.addItem(ClosureMenuItem(card.title, image: NSImage(systemSymbolName: card.kind.symbol, accessibilityDescription: nil)) {
                controller.raise(id: card.id)
                controller.zoom(toNode: card.id)
            })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("New Kanban", image: nil) { controller.addCard(.kanban) })
        menu.addItem(ClosureMenuItem("New Checklist", image: nil) { controller.addCard(.checklist) })
        popUp(menu)
    }

    private func showFiles() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Agent Map", image: nil) { controller.showAgentMap() })
        if let folder = (controller.focusedSurface ?? controller.model.focused?.value)?.pwd ?? controller.workspace.folder {
            menu.addItem(ClosureMenuItem("Show in Finder", image: nil) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
            })
        }
        if ExtremeSettings.isOn(.review) {
            menu.addItem(ClosureMenuItem("Review Changes", image: nil) { ReviewInbox.toggle() })
        }
        popUp(menu)
    }

    private func showLoops() {
        guard let surface = controller.focusedSurface ?? controller.model.focused?.value else {
            NSSound.beep()
            return
        }
        PipelineSetup.show(writer: surface, in: controller)
    }

    private func popUp(_ menu: NSMenu) {
        guard let window = controller.window, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

/// Everything on the board, to jump to.
private struct BoardLayersList: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("LAYERS").font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.6)
                    .padding(.horizontal, 8).padding(.top, 4)
                ForEach(rows, id: \.id) { row in
                    Button {
                        controller.raise(id: row.id)
                        controller.zoom(toNode: row.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.symbol).font(.system(size: 10.5)).foregroundColor(Extreme.muted).frame(width: 16)
                            Text(row.title).font(Extreme.font(12)).foregroundColor(Extreme.text).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(width: 240, height: min(CGFloat(rows.count) * 28 + 40, 420))
        .background(Extreme.panel)
    }

    /// Front to back.
    private var rows: [(id: UUID, title: String, symbol: String)] {
        model.order.reversed().compactMap { id in
            if let surface = model.surfaces.first(where: { $0.id == id }) {
                return (id, controller.tileLabel(surface), "terminal")
            }
            if let card = model.cards.first(where: { $0.id == id }) { return (id, card.title, card.kind.symbol) }
            if let sketch = model.sketches.first(where: { $0.id == id }) { return (id, sketch.title, "scribble") }
            if let label = model.labels.first(where: { $0.id == id }) { return (id, label.text, "textformat") }
            return nil
        }
    }
}

// MARK: - Radial menu

/// Right-click on empty board: a ring of quick actions around the pointer.
struct BoardRadialMenu: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel

    private struct Item {
        let symbol: String
        let title: String
        let run: (BoardController, CGPoint) -> Void
    }

    private static let items: [Item] = [
        Item(symbol: "square.grid.2x2", title: "Group…") { board, _ in board.choose(.group) },
        Item(symbol: "sparkle", title: "Agent") { board, point in
            board.model.tool = .agent
            _ = board.place(at: point)
        },
        Item(symbol: "globe", title: "Web") { board, point in board.addWebTile(at: point) },
        Item(symbol: "photo", title: "Image…") { board, point in board.chooseImage(at: point) },
        Item(symbol: "plus.square.on.square", title: "Duplicate") { board, _ in
            if let surface = board.focusedSurface ?? board.model.focused?.value { board.duplicateTile(surface) }
        },
        Item(symbol: "ellipsis", title: "More") { board, point in board.showCanvasMenu(at: point) },
    ]

    var body: some View {
        if let radial = model.radial {
            ZStack {
                // A click anywhere else closes it.
                Color.black.opacity(0.001)
                    .onTapGesture { model.radial = nil }
                ForEach(Self.items.indices, id: \.self) { index in
                    let item = Self.items[index]
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(Self.items.count)
                    Button {
                        model.radial = nil
                        item.run(controller, radial.board)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol).font(.system(size: 14, weight: .medium)).foregroundColor(Extreme.text)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Extreme.panel.opacity(0.97)))
                                .overlay(Circle().strokeBorder(Extreme.lineStrong))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                            Text(item.title).font(Extreme.font(10.5, weight: .medium)).foregroundColor(Extreme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .position(x: radial.window.x + CGFloat(cos(angle)) * 70, y: radial.window.y + CGFloat(sin(angle)) * 70)
                    .accessibilityLabel(item.title)
                }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .onExitCommand { model.radial = nil }
        }
    }
}
#endif
