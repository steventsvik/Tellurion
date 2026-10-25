#if os(macOS)
import AppKit

/// Notes, checklists and kanban boards beside the terminals. A checklist item or a kanban
/// card can be handed to an agent: it's typed into one on the board (or a new Claude Code or
/// Codex tile), and then follows that agent: Doing while it works, Done when it finishes.
struct BoardCard: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case note, checklist, kanban, map, orchestrator, web, document, media

        var title: String {
            switch self {
            case .note: return "Note"
            case .checklist: return "Checklist"
            case .kanban: return "Kanban"
            case .map: return "Agent Map"
            case .orchestrator: return "Orchestrator"
            case .web: return "Web"
            case .document: return "Document"
            case .media: return "Media"
            }
        }

        var symbol: String {
            switch self {
            case .note: return "note.text"
            case .checklist: return "checklist"
            case .kanban: return "rectangle.split.3x1"
            case .map: return "map"
            case .orchestrator: return "point.3.connected.trianglepath.dotted"
            case .web: return "globe"
            case .document: return "doc.richtext"
            case .media: return "play.rectangle"
            }
        }

        var size: CGSize {
            switch self {
            case .note: return CGSize(width: 340, height: 300)
            case .checklist: return CGSize(width: 380, height: 420)
            case .kanban: return CGSize(width: 1120, height: 540)
            case .map: return CGSize(width: 980, height: 640)
            case .orchestrator: return CGSize(width: 380, height: 520)
            case .web: return BoardWeb.size
            case .document: return CGSize(width: 620, height: 780)
            case .media: return BoardMedia.size
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
    /// 2: kanban columns are Backlog, To Do, In Progress, Done (nil: an older card with To Do,
    /// Doing, Done, moved over when the board opens).
    var kanbanVersion: Int?
    /// A web tile's tabs (their addresses; empty for the start page), the one shown, and its
    /// viewport preset.
    var tabs: [String]?
    var tab: Int?
    var viewport: String?
    /// A document card's markdown file.
    var file: String?
    /// Where it sits on the board (kept in the board's frames while open).
    var frame: CGRect = .zero
}

/// A checklist line or a kanban card.
struct CardItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    /// Kanban column (see `columns`); new cards go in To Do.
    var column = CardItem.todo
    /// The tile whose agent is working on it.
    var agent: UUID?
    /// When it's due, and how much it matters (0 low, 1 medium, 2 high).
    var due: Date?
    var priority: Int?

    static let columns = ["Backlog", "To Do", "In Progress", "Done"]
    static let backlog = 0, todo = 1, doing = 2, done = 3
    static let priorities = ["Low", "Med", "High"]
}

extension BoardController {
    @discardableResult
    /// `edit` puts the cursor in it (not when the board's agent adds one).
    func addCard(_ kind: BoardCard.Kind, at point: CGPoint? = nil, edit: Bool = true) -> UUID {
        var card = BoardCard(id: UUID(), kind: kind, title: BoardStore.uniqueName(kind.title, taken: Set(model.cards.map(\.title))))
        if kind == .kanban { card.kanbanVersion = 2 }
        if kind == .checklist { card.items = [] }
        if kind == .map {
            card.folder = mapFolder(near: point)
            if let folder = card.folder { card.title = BoardProjects.name(folder) }
        }
        insertCard(card, frame: spot(for: kind.size, at: point))
        undoManager?.registerUndo(withTarget: self) { $0.removeCard(card.id) }
        undoManager?.setActionName("New \(kind.title)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.raise(id: card.id)
            if let frame = self.model.frames[card.id] { self.revealRect(frame) }
            if edit { self.cardView(card.id)?.beginTyping() }
        }
        return card.id
    }

    private func insertCard(_ card: BoardCard, frame: CGRect) {
        model.frames[card.id] = frame
        model.cards.append(card)
        if !model.order.contains(card.id) { model.order.append(card.id) }
        scheduleSave()
    }

    /// Closes a card; ⌘Z brings it back (an orchestrator with its wiring).
    func removeCard(_ id: UUID) {
        guard let index = model.cards.firstIndex(where: { $0.id == id }) else { return }
        let card = model.cards[index]
        let frame = model.frames[id] ?? .zero
        let team = orchestrator(id)
        model.cards.remove(at: index)
        model.order.removeAll { $0 == id }
        if team != nil {
            model.teams.removeAll { $0.id == id }
            orchestratorBrains.removeValue(forKey: id)?.stop(quietly: true)
            if model.wiring == id { endWiring() }
        }
        undoManager?.registerUndo(withTarget: self) { board in
            board.insertCard(card, frame: frame)
            if let team { board.model.teams.append(team) }
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
           model.frames[card.id] != nil {
            raise(id: card.id)
            zoom(toNode: card.id)
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
        guard let card = model.cards.first(where: { $0.id == id }) else { return }
        promptRename("Rename \(card.kind.title)", current: card.title) { [weak self] text in
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            self?.updateCard(id) { $0.title = title }
        }
    }

    /// Where a new sketch or card goes: around `point`, else beside the focused tile.
    func spot(for size: CGSize, at point: CGPoint?) -> CGRect {
        if let point { return freeSpot(size: size, near: nil, around: point) }
        return freeSpot(size: size, near: (focusedSurface ?? model.focused?.value).flatMap { model.frames[$0.id] })
    }

    func cardView(_ id: UUID) -> BoardCardView? {
        canvas?.documentView?.subviews.lazy.compactMap { $0 as? BoardCardView }.first { $0.nodeID == id }
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
            if card.kind == .kanban { Self.move(&card.items, index, toColumn: CardItem.doing) }
        }
    }

    /// An agent's status changed: items it's working on follow it.
    func cardsAgentChanged(_ surface: Ghostty.SurfaceView) {
        guard let activity = VerticalTabsAgents.shared.info(for: surface)?.activity else { return }
        for card in model.cards where card.items.contains(where: { $0.agent == surface.id }) {
            updateCard(card.id) { card in
                // By id: a move puts an item at the end and shifts the ones after it.
                for itemID in card.items.filter({ $0.agent == surface.id }).map(\.id) {
                    guard let index = card.items.firstIndex(where: { $0.id == itemID }) else { continue }
                    switch activity {
                    case .working:
                        if card.kind == .kanban, card.items[index].column != CardItem.doing { Self.move(&card.items, index, toColumn: CardItem.doing) }
                    case .done:
                        card.items[index].done = true
                        if card.kind == .kanban, card.items[index].column != CardItem.done { Self.move(&card.items, index, toColumn: CardItem.done) }
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Kanbans from before Backlog: To Do, Doing and Done move one column right.
    static func migrated(_ card: BoardCard) -> BoardCard {
        guard card.kind == .kanban else { return card }
        var card = card
        if card.kanbanVersion == nil {
            for index in card.items.indices { card.items[index].column = min(card.items[index].column + 1, CardItem.done) }
            card.kanbanVersion = 2
        }
        // A column outside the four isn't laid out: the item would count but couldn't be seen.
        for index in card.items.indices { card.items[index].column = min(max(card.items[index].column, 0), CardItem.done) }
        return card
    }

    /// Moves a kanban card to the end of a column.
    static func move(_ items: inout [CardItem], _ index: Int, toColumn column: Int) {
        var item = items.remove(at: index)
        item.column = column
        item.done = column == CardItem.done
        let last = items.lastIndex { $0.column == column }.map { $0 + 1 } ?? items.count
        items.insert(item, at: last)
    }
}
#endif
