#if os(macOS)
import AppKit

/// Notes, checklists and kanban boards beside the terminals. A checklist item or a kanban
/// card can be handed to an agent: it's typed into one on the board (or a new Claude Code or
/// Codex tile), and then follows that agent: Doing while it works, Done when it finishes.
struct BoardCard: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case note, checklist, kanban, map

        var title: String {
            switch self {
            case .note: return "Note"
            case .checklist: return "Checklist"
            case .kanban: return "Kanban"
            case .map: return "Agent Map"
            }
        }

        var symbol: String {
            switch self {
            case .note: return "note.text"
            case .checklist: return "checklist"
            case .kanban: return "rectangle.split.3x1"
            case .map: return "map"
            }
        }

        var size: CGSize {
            switch self {
            case .note: return CGSize(width: 340, height: 300)
            case .checklist: return CGSize(width: 380, height: 420)
            case .kanban: return CGSize(width: 900, height: 520)
            case .map: return CGSize(width: 980, height: 640)
            }
        }
    }

    let id: UUID
    var kind: Kind
    var title: String
    /// A note's tint (an index into SketchStyle.colors).
    var color = 4
    /// A note's words.
    var text = ""
    var items: [CardItem] = []
    /// An Agent Map's project folder.
    var folder: String?
    /// Where it sits on the board (kept in the board's frames while open).
    var frame: CGRect = .zero
}

/// A checklist line or a kanban card.
struct CardItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    /// Kanban column: 0 To Do, 1 Doing, 2 Done.
    var column = 0
    /// The tile whose agent is working on it.
    var agent: UUID?

    static let columns = ["To Do", "Doing", "Done"]
}

extension BoardController {
    @discardableResult
    func addCard(_ kind: BoardCard.Kind, at point: CGPoint? = nil) -> UUID {
        let taken = Set(model.cards.map(\.title))
        var title = kind.title
        var n = 2
        while taken.contains(title) {
            title = "\(kind.title) \(n)"
            n += 1
        }
        var card = BoardCard(id: UUID(), kind: kind, title: title)
        if kind == .checklist { card.items = [] }
        if kind == .map {
            card.folder = mapFolder(near: point)
            if let folder = card.folder { card.title = BoardProjects.name(folder) }
        }
        let frame: CGRect
        if let point {
            frame = freeSpot(size: kind.size, near: nil, around: point)
        } else {
            let anchor = (focusedSurface ?? model.focused?.value).flatMap { model.frames[$0.id] }
            frame = freeSpot(size: kind.size, near: anchor)
        }
        insertCard(card, frame: frame)
        undoManager?.registerUndo(withTarget: self) { $0.removeCard(card.id) }
        undoManager?.setActionName("New \(kind.title)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.raise(id: card.id)
            if let frame = self.model.frames[card.id] { self.revealRect(frame) }
            self.cardView(card.id)?.beginTyping()
        }
        return card.id
    }

    private func insertCard(_ card: BoardCard, frame: CGRect) {
        model.frames[card.id] = frame
        model.cards.append(card)
        if !model.order.contains(card.id) { model.order.append(card.id) }
        scheduleSave()
    }

    /// Closes a card; ⌘Z brings it back.
    func removeCard(_ id: UUID) {
        guard let index = model.cards.firstIndex(where: { $0.id == id }) else { return }
        let card = model.cards[index]
        let frame = model.frames[id] ?? .zero
        model.cards.remove(at: index)
        model.order.removeAll { $0 == id }
        undoManager?.registerUndo(withTarget: self) { board in
            board.insertCard(card, frame: frame)
            board.undoManager?.registerUndo(withTarget: board) { $0.removeCard(id) }
        }
        undoManager?.setActionName("Close \(card.kind.title)")
        scheduleSave()
    }

    // MARK: Agent Map

    /// The project an Agent Map shows: the nearest tile's to `point`, else the focused tile's,
    /// else the board's folder.
    private func mapFolder(near point: CGPoint?) -> String? {
        if let point {
            let nearest = model.surfaces.compactMap { surface in
                model.frames[surface.id].map { (surface, hypot($0.midX - point.x, $0.midY - point.y)) }
            }.min { $0.1 < $1.1 }?.0
            if let nearest, let project = model.projects[nearest.id] { return project }
        }
        if let surface = focusedSurface ?? model.focused?.value, let project = model.projects[surface.id] { return project }
        return BoardProjects.project(of: workspace.folder) ?? model.projects.values.first
    }

    /// Goes to the Agent Map of a tile's project (the focused tile's without one), adding one
    /// when the board has none for it.
    func showAgentMap(for surface: Ghostty.SurfaceView? = nil) {
        let project = (surface ?? focusedSurface ?? model.focused?.value).flatMap { model.projects[$0.id] } ?? mapFolder(near: nil)
        if let card = model.cards.first(where: { $0.kind == .map && (project == nil || $0.folder == project) }),
           let frame = model.frames[card.id] {
            raise(id: card.id)
            zoom(toFit: frame.insetBy(dx: -40, dy: -40), animated: true)
            return
        }
        let near = surface.flatMap { model.frames[$0.id] }.map { CGPoint(x: $0.maxX + BoardCard.Kind.map.size.width / 2, y: $0.midY) }
        let id = addCard(.map, at: near)
        if let project { updateCard(id) { $0.folder = project; $0.title = BoardProjects.name(project) } }
    }

    func setMapFolder(_ id: UUID, to folder: String) {
        updateCard(id) { card in
            card.folder = folder
            card.title = BoardProjects.name(folder)
        }
    }

    func updateCard(_ id: UUID, _ change: (inout BoardCard) -> Void) {
        guard let index = model.cards.firstIndex(where: { $0.id == id }) else { return }
        var card = model.cards[index]
        change(&card)
        guard card != model.cards[index] else { return }
        model.cards[index] = card
        scheduleSave()
    }

    func promptCardTitle(_ id: UUID) {
        guard let window, let card = model.cards.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(card.kind.title)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.stringValue = card.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !title.isEmpty else { return }
            self?.updateCard(id) { $0.title = title }
        }
    }

    func cardView(_ id: UUID) -> BoardCardView? {
        canvas?.documentView?.subviews.lazy.compactMap { $0 as? BoardCardView }.first { $0.nodeID == id }
    }

    /// Scrolls just enough to show a rect, keeping the zoom.
    func revealRect(_ frame: CGRect) {
        guard let canvas else { return }
        let visible = canvas.documentVisibleRect
        guard !visible.contains(frame) else { return }
        let origin = CGPoint(x: frame.midX - visible.width / 2, y: frame.midY - visible.height / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            canvas.contentView.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self] in
            canvas.reflectScrolledClipView(canvas.contentView)
            self?.updateVisibility()
        }
    }

    // MARK: Agents

    /// The agents on this board an item can go to, with their names.
    var boardAgents: [(surface: Ghostty.SurfaceView, name: String)] {
        model.surfaces.compactMap { surface in
            guard let info = VerticalTabsAgents.shared.info(for: surface), info.kind != .hermes, info.kind != .unknown else { return nil }
            return (surface, BoardTileTitle.title(surface, info, name: model.titles[surface.id]))
        }
    }

    /// A submenu for handing an item to an agent: one on the board, or a new tile.
    func agentMenu(for item: UUID, in card: UUID) -> NSMenu {
        let menu = NSMenu()
        for agent in boardAgents {
            menu.addItem(ClosureMenuItem(agent.name, image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)) { [weak self, weak surface = agent.surface] in
                guard let self, let surface else { return }
                self.hand(item, in: card, to: surface)
            })
        }
        if !boardAgents.isEmpty { menu.addItem(.separator()) }
        for (title, kind) in [("New Claude Code Tile", VerticalTabAgentKind.claude), ("New Codex Tile", .codex)] {
            menu.addItem(ClosureMenuItem(title, image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)) { [weak self] in
                self?.hand(item, in: card, newAgent: kind)
            })
        }
        return menu
    }

    private func prompt(for item: CardItem, in card: BoardCard) -> String {
        var text = item.text
        if card.kind == .checklist || card.kind == .kanban, card.title != card.kind.title {
            text += "\n\n(From “\(card.title)” on the board.)"
        }
        return text
    }

    func hand(_ itemID: UUID, in cardID: UUID, to surface: Ghostty.SurfaceView) {
        guard let card = model.cards.first(where: { $0.id == cardID }),
              let item = card.items.first(where: { $0.id == itemID }), !item.text.isEmpty else { return }
        deliver(prompt(for: item, in: card), to: surface)
        link(itemID, in: cardID, to: surface.id)
    }

    func hand(_ itemID: UUID, in cardID: UUID, newAgent kind: VerticalTabAgentKind) {
        guard let card = model.cards.first(where: { $0.id == cardID }),
              let item = card.items.first(where: { $0.id == itemID }), !item.text.isEmpty,
              let surface = startAgent(kind, prompt: prompt(for: item, in: card), near: model.frames[cardID]) else { return }
        link(itemID, in: cardID, to: surface.id)
    }

    private func link(_ itemID: UUID, in cardID: UUID, to surface: UUID) {
        updateCard(cardID) { card in
            guard let index = card.items.firstIndex(where: { $0.id == itemID }) else { return }
            card.items[index].agent = surface
            card.items[index].done = false
            if card.kind == .kanban { Self.move(&card.items, index, toColumn: 1) }
        }
    }

    /// An agent's status changed: items it's working on follow it.
    func cardsAgentChanged(_ surface: Ghostty.SurfaceView) {
        guard let activity = VerticalTabsAgents.shared.info(for: surface)?.activity else { return }
        for card in model.cards where card.items.contains(where: { $0.agent == surface.id }) {
            updateCard(card.id) { card in
                for index in card.items.indices where card.items[index].agent == surface.id {
                    switch activity {
                    case .working:
                        if card.kind == .kanban, card.items[index].column != 1 { Self.move(&card.items, index, toColumn: 1) }
                    case .done:
                        card.items[index].done = true
                        if card.kind == .kanban, card.items[index].column != 2 { Self.move(&card.items, index, toColumn: 2) }
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Moves a kanban card to the end of a column.
    static func move(_ items: inout [CardItem], _ index: Int, toColumn column: Int) {
        var item = items.remove(at: index)
        item.column = column
        item.done = column == 2
        let last = items.lastIndex { $0.column == column }.map { $0 + 1 } ?? items.count
        items.insert(item, at: last)
    }
}
#endif
