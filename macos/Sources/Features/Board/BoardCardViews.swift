#if os(macOS)
import AppKit
import SwiftUI

/// A note, checklist or kanban board on the board: a title bar like a terminal's and its
/// content, all AppKit so typing and dragging work at any zoom.
final class BoardCardView: BoardNodeView {
    private(set) var card: BoardCard
    private let state = BoardCardState()
    private let clip = FlippedView()
    private var headerView: NSView!
    private var overview: NSView!
    private let content: CardContent

    init(controller: BoardController, card: BoardCard) {
        self.card = card
        switch card.kind {
        case .note: content = NoteContent()
        case .checklist: content = ChecklistContent()
        case .kanban: content = KanbanContent()
        case .map: content = AgentMapContent()
        }
        super.init(controller: controller, id: card.id)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 9
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1.25
        clip.layer?.backgroundColor = Extreme.chrome.panel.nsColor.cgColor
        addSubview(clip)
        let header = PassiveHostingView(rootView: BoardCardHeader(state: state))
        let overview = PassiveHostingView(rootView: BoardCardOverview(state: state))
        header.sizingOptions = []
        overview.sizingOptions = []
        headerView = header
        self.overview = overview
        clip.addSubview(content)
        clip.addSubview(header)
        clip.addSubview(overview)
        overview.isHidden = true
        content.board = controller
        content.cardID = card.id
        content.apply(card)
        state.apply(card)
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.header)
        content.frame = CGRect(x: 0, y: Self.header, width: bounds.width, height: max(0, bounds.height - Self.header))
        overview.frame = clip.bounds
    }

    func update(card: BoardCard, zoom: CGFloat) {
        // Statuses of linked agents change without the card changing.
        content.refreshAgents()
        if card != self.card {
            self.card = card
            content.apply(card)
            state.apply(card)
        }
        if abs(state.zoom - zoom) > 0.001 { state.zoom = zoom }
        setZoom(zoom)
        overview.isHidden = zoom >= 0.45
        // A note's color, or an Agent Map's project color.
        let tint = card.kind == .note ? SketchStyle.color(card.color)
            : card.folder.flatMap { controller?.model.colors[$0] }.map(BoardProjects.nsColor)
        clip.layer?.borderColor = (tint?.withAlphaComponent(0.6) ?? Extreme.chrome.lineStrong.nsColor).cgColor
    }

    /// What an Agent Map shows, for tests.
    var mapState: String? { (content as? AgentMapContent)?.testState }

    /// Puts the cursor where typing starts: the note, or the checklist's new-item field.
    func beginTyping() { content.beginTyping() }

    override func nodeMenu() -> NSMenu? {
        guard let controller else { return nil }
        let id = nodeID
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename…", image: nil) { [weak controller] in controller?.promptCardTitle(id) })
        if card.kind == .note {
            let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            colors.submenu = SketchCanvasView.colorMenu(current: card.color) { [weak controller] index in
                controller?.updateCard(id) { $0.color = index }
            }
            menu.addItem(colors)
            menu.addItem(ClosureMenuItem("Send to Agent…", image: nil) { [weak controller, weak self] in
                guard let self, let controller, !self.card.text.isEmpty else { return }
                self.sendNote(controller)
            })
        }
        if card.kind == .checklist {
            menu.addItem(ClosureMenuItem("Clear Checked Items", image: nil) { [weak controller] in
                controller?.updateCard(id) { $0.items.removeAll(where: \.done) }
            })
        }
        if card.kind == .kanban {
            menu.addItem(ClosureMenuItem("Clear Done", image: nil) { [weak controller] in
                controller?.updateCard(id) { $0.items.removeAll { $0.column == 2 } }
            })
        }
        if card.kind == .map {
            menu.addItem(mapProjectItem(controller))
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close \(card.kind.title)", image: nil) { [weak controller] in controller?.removeCard(id) })
        return menu
    }

    /// Which project the map shows: one on the board, or any folder.
    private func mapProjectItem(_ controller: BoardController) -> NSMenuItem {
        let id = nodeID
        let item = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for project in Set(controller.model.projects.values).sorted() {
            let entry = ClosureMenuItem(BoardProjects.name(project), image: nil) { [weak controller] in
                controller?.setMapFolder(id, to: project)
            }
            entry.state = project == card.folder ? .on : .off
            menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("Choose Folder…", image: nil) { [weak controller, weak self] in
            guard let controller, let window = self?.window else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                controller.setMapFolder(id, to: BoardProjects.project(of: url.path) ?? url.path)
            }
        })
        item.submenu = menu
        return item
    }

    /// A note goes to an agent as a whole: an item made from it.
    private func sendNote(_ controller: BoardController) {
        let item = CardItem(text: card.text)
        let id = nodeID
        controller.updateCard(id) { $0.items = [item] }
        let menu = controller.agentMenu(for: item.id, in: id)
        menu.popUp(positioning: nil, at: CGPoint(x: menuRect.minX, y: menuRect.maxY + 4), in: self)
    }

    override func nodeClose() { controller?.removeCard(nodeID) }

    override func nodeFocus() {
        controller?.zoom(toNode: nodeID)
        beginTyping()
    }

    override func nodeClick() { beginTyping() }
}

final class BoardCardState: ObservableObject {
    @Published var kind: BoardCard.Kind = .note
    @Published var title = ""
    @Published var summary: String?
    @Published var tint: NSColor?
    @Published var zoom: CGFloat = 1

    func apply(_ card: BoardCard) {
        if kind != card.kind { kind = card.kind }
        if title != card.title { title = card.title }
        let summary: String?
        switch card.kind {
        case .note: summary = nil
        case .checklist: summary = card.items.isEmpty ? nil : "\(card.items.filter(\.done).count) of \(card.items.count)"
        case .kanban: summary = card.items.isEmpty ? nil : "\(card.items.filter { $0.column == 2 }.count) of \(card.items.count) done"
        case .map: summary = "Agent Map"
        }
        if self.summary != summary { self.summary = summary }
        let tint = card.kind == .note ? SketchStyle.color(card.color) : nil
        if self.tint != tint { self.tint = tint }
    }
}

private struct BoardCardHeader: View {
    @ObservedObject var state: BoardCardState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.kind.symbol).font(.system(size: 11, weight: .medium))
                .foregroundColor(state.tint.map { Color(nsColor: $0) } ?? Extreme.muted)
            Text(state.title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
            if let summary = state.summary {
                Text(summary).font(Extreme.font(11)).foregroundColor(Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(["ellipsis", "arrow.up.left.and.arrow.down.right", "xmark"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundColor(Extreme.muted)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Extreme.panel)
        .overlay(Rectangle().fill(Extreme.line).frame(height: 1), alignment: .bottom)
    }
}

private struct BoardCardOverview: View {
    @ObservedObject var state: BoardCardState

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 6) {
                Image(systemName: state.kind.symbol).font(.system(size: 20, weight: .medium))
                    .foregroundColor(state.tint.map { Color(nsColor: $0) } ?? Extreme.text)
                Text(state.title).font(Extreme.font(13, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                if let summary = state.summary {
                    Text(summary).font(Extreme.font(11)).foregroundColor(Extreme.muted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 200)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Extreme.panel.opacity(0.92)))
            .scaleEffect(min(1 / max(state.zoom, 0.08), geo.size.width / 220))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Content

extension NSView {
    /// Every view under this one.
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}

/// What's under a card's title bar.
class CardContent: NSView {
    weak var board: BoardController?
    var cardID = UUID()

    override var isFlipped: Bool { true }
    func apply(_ card: BoardCard) {}
    func refreshAgents() {}
    func beginTyping() {}

    func change(_ body: (inout BoardCard) -> Void) {
        board?.updateCard(cardID, body)
    }

    /// "● Working · Claude Code" for an item an agent has, or nil.
    func agentLine(_ item: CardItem) -> (String, NSColor)? {
        guard let id = item.agent, let board,
              let surface = board.model.surfaces.first(where: { $0.id == id }) else {
            return item.agent == nil || item.done ? nil : ("Agent closed", .tertiaryLabelColor)
        }
        // Finished work doesn't need to say its agent has gone.
        guard let info = VerticalTabsAgents.shared.info(for: surface) else {
            return item.done ? nil : ("Agent not running", .tertiaryLabelColor)
        }
        let name = BoardTileTitle.title(surface, info, name: board.model.titles[surface.id])
        return ("\(info.activity.label) · \(name)", NSColor(AgentStatusPill.color(info.activity)))
    }

    func showAgent(_ item: CardItem) {
        guard let id = item.agent, let surface = board?.model.surfaces.first(where: { $0.id == id }) else { return }
        board?.focusTile(surface)
    }
}

/// A sticky note: a tinted page you type on.
final class NoteContent: CardContent, NSTextViewDelegate {
    private let scroll = NSScrollView()
    private let text = NSTextView()
    private var applying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 15)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    override func apply(_ card: BoardCard) {
        layer?.backgroundColor = SketchStyle.color(card.color).withAlphaComponent(0.14).cgColor
        guard text.string != card.text, window?.firstResponder !== text else { return }
        applying = true
        text.string = card.text
        applying = false
    }

    func textDidChange(_ notification: Notification) {
        guard !applying else { return }
        let words = text.string
        change { $0.text = words }
    }

    override func beginTyping() {
        window?.makeFirstResponder(text)
    }
}

// MARK: - Checklist

final class ChecklistContent: CardContent, NSTextFieldDelegate {
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let addField = NSTextField()
    private var rows: [ChecklistRow] = []
    private var items: [CardItem] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        addSubview(scroll)
        addField.placeholderString = "Add an item"
        addField.isBordered = false
        addField.drawsBackground = false
        addField.focusRingType = .none
        addField.font = .systemFont(ofSize: 14)
        addField.delegate = self
        addField.target = self
        addField.action = #selector(addItem)
        addSubview(addField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        addField.frame = CGRect(x: 42, y: bounds.height - 38, width: bounds.width - 56, height: 22)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 46))
        layoutRows()
    }

    private func layoutRows() {
        let width = scroll.contentSize.width
        var y: CGFloat = 8
        for row in rows {
            let height = row.height(for: width)
            row.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        list.frame = CGRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        // A hairline over the new-item field, and its plus.
        NSColor.separatorColor.setFill()
        CGRect(x: 14, y: bounds.height - 46, width: bounds.width - 28, height: 1).fill()
        if let plus = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            NSColor.tertiaryLabelColor.set()
            let tinted = plus.copy() as? NSImage ?? plus
            tinted.isTemplate = true
            tinted.draw(in: CGRect(x: 16, y: bounds.height - 38, width: 18, height: 18), from: .zero,
                        operation: .sourceOver, fraction: 0.6, respectFlipped: true, hints: nil)
        }
    }

    override func apply(_ card: BoardCard) {
        let old = items
        items = card.items
        if old.map(\.id) != items.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = items.map { item in
                let row = ChecklistRow(item: item)
                row.owner = self
                list.addSubview(row)
                return row
            }
        } else {
            for (row, item) in zip(rows, items) { row.show(item) }
        }
        refreshAgents()
        needsLayout = true
    }

    override func refreshAgents() {
        for (row, item) in zip(rows, items) { row.showAgent(agentLine(item)) }
    }

    override func beginTyping() {
        window?.makeFirstResponder(addField)
    }

    @objc private func addItem() {
        let words = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        addField.stringValue = ""
        change { $0.items.append(CardItem(text: words)) }
        // Ready for the next one.
        DispatchQueue.main.async { [weak self] in self?.beginTyping() }
    }

    func toggle(_ id: UUID) {
        change { card in
            guard let i = card.items.firstIndex(where: { $0.id == id }) else { return }
            card.items[i].done.toggle()
        }
    }

    func edit(_ id: UUID, text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        change { card in
            if words.isEmpty { card.items.removeAll { $0.id == id } } else if let i = card.items.firstIndex(where: { $0.id == id }) {
                card.items[i].text = words
            }
        }
    }

    func menu(for id: UUID) -> NSMenu? {
        guard let board, let item = items.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        let hand = NSMenuItem(title: "Hand to Agent", action: nil, keyEquivalent: "")
        hand.submenu = board.agentMenu(for: id, in: cardID)
        menu.addItem(hand)
        if item.agent != nil {
            menu.addItem(ClosureMenuItem("Show Agent", image: nil) { [weak self] in self?.showAgent(item) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete", image: nil) { [weak self] in
            self?.change { $0.items.removeAll { $0.id == id } }
        })
        return menu
    }
}

/// One checklist line: a round check, its words (editable), and the agent on it.
final class ChecklistRow: NSView, NSTextFieldDelegate {
    weak var owner: ChecklistContent?
    private var item: CardItem
    private let check = NSButton()
    private let field = NSTextField(wrappingLabelWithString: "")
    private let agent = NSTextField(labelWithString: "")

    init(item: CardItem) {
        self.item = item
        super.init(frame: .zero)
        check.isBordered = false
        check.imagePosition = .imageOnly
        check.target = self
        check.action = #selector(toggle)
        addSubview(check)
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.focusRingType = .none
        addSubview(field)
        agent.font = .systemFont(ofSize: 11, weight: .medium)
        agent.isHidden = true
        addSubview(agent)
        show(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ item: CardItem) {
        self.item = item
        let symbol = item.done ? "checkmark.circle.fill" : "circle"
        check.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.done ? "Done" : "Not done")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        check.contentTintColor = item.done ? .controlAccentColor : .tertiaryLabelColor
        if field.currentEditor() == nil { field.stringValue = item.text }
        field.textColor = item.done ? .secondaryLabelColor : .labelColor
    }

    func showAgent(_ line: (String, NSColor)?) {
        agent.isHidden = line == nil
        agent.stringValue = line.map { "● " + $0.0 } ?? ""
        agent.textColor = line?.1 ?? .secondaryLabelColor
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        let textWidth = max(width - 56, 40)
        field.preferredMaxLayoutWidth = textWidth
        let text = field.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 18
        return max(text, 18) + (agent.isHidden ? 12 : 28)
    }

    override func layout() {
        super.layout()
        check.frame = CGRect(x: 14, y: 5, width: 22, height: 22)
        let textWidth = max(bounds.width - 56, 40)
        let text = field.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: textWidth, height: 1000)).height ?? 18
        field.frame = CGRect(x: 42, y: 7, width: textWidth, height: max(text, 18))
        agent.frame = CGRect(x: 42, y: field.frame.maxY + 2, width: textWidth, height: 15)
    }

    @objc private func toggle() { owner?.toggle(item.id) }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard field.stringValue != item.text else { return }
        owner?.edit(item.id, text: field.stringValue)
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(for: item.id) }
}

// MARK: - Kanban

/// Three columns of cards. Drag a card to move it; double-click to edit; + adds one.
final class KanbanContent: CardContent, NSTextFieldDelegate {
    private var items: [CardItem] = []
    private var cards: [UUID: KanbanCard] = [:]
    private var addButtons: [NSButton] = []
    private var headers: [NSTextField] = []
    private struct CardDrag {
        let id: UUID
        let offset: CGPoint
        let start: CGPoint
        var moved: Bool
    }

    private var drag: CardDrag?
    private var dropTarget: (column: Int, index: Int)?
    private let indicator = NSView()

    private static let pad: CGFloat = 10
    private static let headerHeight: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        for column in 0..<3 {
            let header = NSTextField(labelWithString: CardItem.columns[column])
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            addSubview(header)
            headers.append(header)
            let add = ClosureButton { [weak self] in self?.addCard(in: column) }
            add.isBordered = false
            add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a card to \(CardItem.columns[column])")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            add.contentTintColor = .secondaryLabelColor
            add.toolTip = "Add a card"
            addSubview(add)
            addButtons.append(add)
        }
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.layer?.cornerRadius = 1.5
        indicator.isHidden = true
        addSubview(indicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var columnWidth: CGFloat { max((bounds.width - Self.pad * 4) / 3, 60) }

    private func columnRect(_ column: Int) -> CGRect {
        CGRect(x: Self.pad + CGFloat(column) * (columnWidth + Self.pad), y: Self.pad,
               width: columnWidth, height: max(bounds.height - Self.pad * 2, 40))
    }

    override func draw(_ dirtyRect: NSRect) {
        for column in 0..<3 {
            let rect = columnRect(column)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            (dropTarget?.column == column ? NSColor.controlAccentColor.withAlphaComponent(0.1)
                : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill()
            path.fill()
        }
    }

    override func layout() {
        super.layout()
        for column in 0..<3 {
            let rect = columnRect(column)
            let count = items.filter { $0.column == column }.count
            headers[column].stringValue = count > 0 ? "\(CardItem.columns[column])  \(count)" : CardItem.columns[column]
            headers[column].frame = CGRect(x: rect.minX + 12, y: rect.minY + 8, width: rect.width - 48, height: 16)
            addButtons[column].frame = CGRect(x: rect.maxX - 30, y: rect.minY + 4, width: 24, height: 24)
            var y = rect.minY + Self.headerHeight + 4
            var index = 0
            for item in items where item.column == column {
                guard let card = cards[item.id] else { continue }
                if dropTarget?.column == column && dropTarget?.index == index, drag?.moved == true {
                    y += 10
                }
                let height = card.height(for: rect.width - 16)
                if drag?.id != item.id || drag?.moved != true {
                    card.frame = CGRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: height)
                }
                y += height + 8
                if drag?.id != item.id || drag?.moved != true { index += 1 }
            }
        }
        if let target = dropTarget, drag?.moved == true {
            indicator.isHidden = false
            indicator.frame = indicatorFrame(target)
        } else {
            indicator.isHidden = true
        }
    }

    private func indicatorFrame(_ target: (column: Int, index: Int)) -> CGRect {
        let rect = columnRect(target.column)
        let inColumn = items.filter { $0.column == target.column && $0.id != drag?.id }.compactMap { cards[$0.id] }
        let y: CGFloat
        if target.index < inColumn.count {
            y = inColumn[target.index].frame.minY - 9
        } else {
            y = (inColumn.last?.frame.maxY ?? rect.minY + Self.headerHeight) + 3
        }
        return CGRect(x: rect.minX + 10, y: y, width: rect.width - 20, height: 3)
    }

    override func apply(_ card: BoardCard) {
        items = card.items
        let ids = Set(items.map(\.id))
        for (id, view) in cards where !ids.contains(id) {
            view.removeFromSuperview()
            cards[id] = nil
        }
        for item in items {
            let view = cards[item.id] ?? {
                let view = KanbanCard(item: item)
                view.owner = self
                addSubview(view, positioned: .below, relativeTo: indicator)
                cards[item.id] = view
                return view
            }()
            view.show(item)
        }
        refreshAgents()
        needsLayout = true
        needsDisplay = true
    }

    override func refreshAgents() {
        for item in items { cards[item.id]?.showAgent(agentLine(item)) }
    }

    override func beginTyping() {
        if items.isEmpty { addCard(in: 0) }
    }

    func addCard(in column: Int) {
        let item = CardItem(text: "", column: column)
        change { card in
            let last = card.items.lastIndex { $0.column == column }.map { $0 + 1 } ?? card.items.count
            card.items.insert(item, at: last)
        }
        DispatchQueue.main.async { [weak self] in self?.cards[item.id]?.beginEditing() }
    }

    func edit(_ id: UUID, text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        change { card in
            if words.isEmpty { card.items.removeAll { $0.id == id } } else if let i = card.items.firstIndex(where: { $0.id == id }) {
                card.items[i].text = words
            }
        }
    }

    // Dragging cards between columns.

    func cardMouseDown(_ id: UUID, _ event: NSEvent) {
        guard let view = cards[id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        drag = CardDrag(id: id, offset: CGPoint(x: point.x - view.frame.minX, y: point.y - view.frame.minY), start: point, moved: false)
    }

    func cardMouseDragged(_ event: NSEvent) {
        guard var current = drag, let view = cards[current.id] else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !current.moved {
            guard hypot(point.x - current.start.x, point.y - current.start.y) >= 4 else { return }
            current.moved = true
            drag = current
            view.lift(true)
            addSubview(view, positioned: .below, relativeTo: indicator)
        }
        view.frame.origin = CGPoint(x: point.x - current.offset.x, y: point.y - current.offset.y)
        // The column under the pointer, and the place among its cards.
        let column = (0..<3).min { abs(columnRect($0).midX - point.x) < abs(columnRect($1).midX - point.x) } ?? 0
        let others = items.filter { $0.column == column && $0.id != current.id }.compactMap { cards[$0.id] }
        let index = others.firstIndex { point.y < $0.frame.midY } ?? others.count
        if dropTarget?.column != column || dropTarget?.index != index {
            dropTarget = (column, index)
            // The other cards slide apart to show where it will go.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                layout()
            }
            needsDisplay = true
        }
    }

    func cardMouseUp(_ event: NSEvent) {
        defer {
            drag = nil
            dropTarget = nil
            needsLayout = true
            needsDisplay = true
        }
        guard let current = drag else { return }
        guard current.moved, let target = dropTarget else {
            if event.clickCount == 2 { cards[current.id]?.beginEditing() }
            return
        }
        cards[current.id]?.lift(false)
        change { card in
            guard let from = card.items.firstIndex(where: { $0.id == current.id }) else { return }
            var item = card.items.remove(at: from)
            item.column = target.column
            item.done = target.column == 2
            let inColumn = card.items.enumerated().filter { $0.element.column == target.column }.map(\.offset)
            let at = target.index < inColumn.count ? inColumn[target.index] : (inColumn.last.map { $0 + 1 } ?? card.items.count)
            card.items.insert(item, at: at)
        }
    }

    func menu(for id: UUID) -> NSMenu? {
        guard let board, let item = items.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Edit", image: nil) { [weak self] in self?.cards[id]?.beginEditing() })
        let hand = NSMenuItem(title: "Hand to Agent", action: nil, keyEquivalent: "")
        hand.submenu = board.agentMenu(for: id, in: cardID)
        menu.addItem(hand)
        if item.agent != nil {
            menu.addItem(ClosureMenuItem("Show Agent", image: nil) { [weak self] in self?.showAgent(item) })
        }
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        move.submenu = NSMenu()
        for (column, name) in CardItem.columns.enumerated() where column != item.column {
            move.submenu?.addItem(ClosureMenuItem(name, image: nil) { [weak self] in
                self?.change { card in
                    guard let i = card.items.firstIndex(where: { $0.id == id }) else { return }
                    BoardController.move(&card.items, i, toColumn: column)
                }
            })
        }
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete", image: nil) { [weak self] in
            self?.change { $0.items.removeAll { $0.id == id } }
        })
        return menu
    }
}

/// A card in a kanban column.
final class KanbanCard: NSView, NSTextFieldDelegate {
    weak var owner: KanbanContent?
    private var item: CardItem
    var itemID: UUID { item.id }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let agent = NSTextField(labelWithString: "")

    init(item: CardItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Extreme.chrome.raised.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.font = .systemFont(ofSize: 13)
        label.delegate = self
        label.focusRingType = .none
        addSubview(label)
        agent.font = .systemFont(ofSize: 11, weight: .medium)
        agent.isHidden = true
        addSubview(agent)
        show(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ item: CardItem) {
        self.item = item
        if label.currentEditor() == nil { label.stringValue = item.text }
        label.textColor = item.column == 2 ? .secondaryLabelColor : .labelColor
    }

    func showAgent(_ line: (String, NSColor)?) {
        agent.isHidden = line == nil
        agent.stringValue = line.map { "● " + $0.0 } ?? ""
        agent.textColor = line?.1 ?? .secondaryLabelColor
    }

    func height(for width: CGFloat) -> CGFloat {
        let text = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width - 20, height: 1000)).height ?? 17
        return max(text, 17) + 20 + (agent.isHidden ? 0 : 17)
    }

    override func layout() {
        super.layout()
        let text = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: bounds.width - 20, height: 1000)).height ?? 17
        label.frame = CGRect(x: 10, y: 10, width: bounds.width - 20, height: max(text, 17))
        agent.frame = CGRect(x: 10, y: label.frame.maxY + 3, width: bounds.width - 20, height: 14)
    }

    func beginEditing() {
        label.isEditable = true
        label.isSelectable = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        label.isEditable = false
        label.isSelectable = false
        owner?.edit(item.id, text: label.stringValue)
    }

    func lift(_ up: Bool) {
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        layer?.shadowOpacity = up ? 0.35 : 0
        layer?.borderColor = (up ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While editing, clicks go to the text; otherwise the card takes them, to drag it.
        if label.isEditable { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.cardMouseDown(item.id, event) }
    override func mouseDragged(with event: NSEvent) { owner?.cardMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.cardMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(for: item.id) }
}
#endif
