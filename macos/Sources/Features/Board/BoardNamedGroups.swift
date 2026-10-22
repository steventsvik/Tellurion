#if os(macOS)
import AppKit

/// A group you make on the board: a name, a role and the tiles in it, drawn as a frame around
/// them with a header ("● BACKEND  12 · 11 running ⌄"). Its frame is always its tiles' frames,
/// so moving tiles moves it. Collapsed, its tiles are hidden (and stop drawing) behind a strip
/// listing them. A tile is in at most one group; tiles in a group leave the automatic project
/// areas.
struct BoardGroupNode: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var role: BoardRole
    /// An index into BoardProjects.palette, in place of the role's color.
    var color: Int?
    var tiles: [UUID]
    var collapsed = false
}

/// What a group is for: its default name and color.
enum BoardRole: String, Codable, CaseIterable, Identifiable {
    case frontend, backend, testers, reviewers, design, docs, security, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontend: return "Frontend"
        case .backend: return "Backend"
        case .testers: return "Testers"
        case .reviewers: return "Reviewers"
        case .design: return "Design"
        case .docs: return "Docs"
        case .security: return "Security"
        case .general: return "General"
        }
    }

    var nsColor: NSColor {
        let rgb: UInt32
        switch self {
        case .frontend: rgb = 0xF5B83D
        case .backend: rgb = 0xB18CFF
        case .testers: rgb = 0x6FCF7F
        case .reviewers: rgb = 0x4AA8FF
        case .design: rgb = 0xF06BBF
        case .docs: rgb = 0x3CC9C9
        case .security: rgb = 0xFF6B57
        case .general: rgb = 0x9AA0AA
        }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension BoardGroupNode {
    var nsColor: NSColor { color.map(BoardProjects.nsColor) ?? role.nsColor }
}

/// One group as BoardGroupsView draws it.
struct BoardNamedGroupDisplay: Equatable {
    let id: UUID
    let name: String
    let color: NSColor
    /// Around its tiles (or, collapsed, where they are).
    let frame: CGRect
    let count: Int
    let running: Int
    let collapsed: Bool
    /// Collapsed: each tile's name and status.
    let rows: [(name: String, status: String, color: NSColor)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.color == rhs.color && lhs.frame == rhs.frame
            && lhs.count == rhs.count && lhs.running == rhs.running && lhs.collapsed == rhs.collapsed
            && lhs.rows.map { "\($0.name)|\($0.status)" } == rhs.rows.map { "\($0.name)|\($0.status)" }
    }
}

extension BoardController {
    // MARK: Looking up

    func namedGroup(_ id: UUID) -> BoardGroupNode? { model.groups.first { $0.id == id } }

    /// The group a tile is in.
    func namedGroup(containing tile: UUID) -> BoardGroupNode? { model.groups.first { $0.tiles.contains(tile) } }

    /// Tiles hidden because their group is collapsed.
    var collapsedTiles: Set<UUID> {
        Set(model.groups.filter(\.collapsed).flatMap(\.tiles))
    }

    func groupSurfaces(_ group: BoardGroupNode) -> [Ghostty.SurfaceView] {
        let members = Set(group.tiles)
        let byID = Dictionary(model.surfaces.filter { members.contains($0.id) }.map { ($0.id, $0) }) { first, _ in first }
        return group.tiles.compactMap { byID[$0] }
    }

    /// Around a group's tiles.
    func groupFrame(_ group: BoardGroupNode) -> CGRect? {
        let frames = group.tiles.compactMap { model.frames[$0] }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    func namedGroupDisplays() -> [BoardNamedGroupDisplay] {
        model.groups.compactMap { group in
            guard let frame = groupFrame(group) else { return nil }
            let surfaces = groupSurfaces(group)
            let infos = surfaces.map { VerticalTabsAgents.shared.info(for: $0) }
            let rows = group.collapsed ? zip(surfaces, infos).map { surface, info in
                (name: tileLabel(surface), status: model.paused.contains(surface.id) ? "Paused" : info?.activity.label ?? "Terminal",
                 color: info.map { NSColor(AgentStatusPill.color($0.activity)) } ?? NSColor.secondaryLabelColor)
            } : []
            return BoardNamedGroupDisplay(id: group.id, name: group.name, color: group.nsColor, frame: frame,
                                          count: surfaces.count, running: infos.filter { $0?.activity == .working }.count,
                                          collapsed: group.collapsed, rows: rows)
        }
    }

    // MARK: Changing

    /// Replaces the groups; ⌘Z puts the old ones back.
    func setGroups(_ groups: [BoardGroupNode], action: String) {
        let old = model.groups
        guard old != groups else { return }
        model.groups = groups
        undoManager?.registerUndo(withTarget: self) { $0.setGroups(old, action: action) }
        undoManager?.setActionName(action)
        updateVisibility()
        scheduleSave()
    }

    private func changeGroup(_ id: UUID, action: String, _ change: (inout BoardGroupNode) -> Void) {
        guard let index = model.groups.firstIndex(where: { $0.id == id }) else { return }
        var groups = model.groups
        change(&groups[index])
        setGroups(groups, action: action)
    }

    /// A new group of these tiles (which leave any group they were in).
    @discardableResult
    func createGroup(_ tiles: [UUID], name: String? = nil, role: BoardRole = .general) -> UUID? {
        let tiles = tiles.filter { id in model.surfaces.contains { $0.id == id } }
        guard !tiles.isEmpty else { return nil }
        var groups = model.groups
        for index in groups.indices { groups[index].tiles.removeAll { tiles.contains($0) } }
        groups.removeAll { $0.tiles.isEmpty }
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = BoardGroupNode(id: UUID(), name: BoardStore.uniqueName(title?.isEmpty == false ? title ?? role.title : role.title,
                                                                           taken: Set(groups.map(\.name))),
                                   role: role, tiles: tiles)
        groups.append(group)
        setGroups(groups, action: "New Group")
        return group.id
    }

    func addToGroup(_ tiles: [UUID], group id: UUID) {
        var groups = model.groups
        for index in groups.indices where groups[index].id != id { groups[index].tiles.removeAll { tiles.contains($0) } }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        for tile in tiles where !groups[index].tiles.contains(tile) && model.surfaces.contains(where: { $0.id == tile }) {
            groups[index].tiles.append(tile)
        }
        groups.removeAll { $0.tiles.isEmpty }
        setGroups(groups, action: "Add to Group")
    }

    func removeFromGroup(_ tile: UUID) {
        var groups = model.groups
        for index in groups.indices { groups[index].tiles.removeAll { $0 == tile } }
        groups.removeAll { $0.tiles.isEmpty }
        setGroups(groups, action: "Remove from Group")
    }

    func ungroup(_ id: UUID) {
        setGroups(model.groups.filter { $0.id != id }, action: "Ungroup")
    }

    func renameGroup(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let taken = Set(model.groups.filter { $0.id != id }.map(\.name))
        changeGroup(id, action: "Rename Group") { $0.name = BoardStore.uniqueName(name, taken: taken) }
    }

    func setGroupColor(_ id: UUID, _ color: Int?) {
        changeGroup(id, action: "Group Color") { $0.color = color }
    }

    func setGroupRole(_ id: UUID, _ role: BoardRole) {
        let taken = Set(model.groups.filter { $0.id != id }.map(\.name))
        changeGroup(id, action: "Group Role") { group in
            if BoardRole.allCases.contains(where: { group.name == $0.title || group.name.hasPrefix($0.title + " ") }) {
                group.name = BoardStore.uniqueName(role.title, taken: taken)
            }
            group.role = role
        }
    }

    func toggleCollapsed(_ id: UUID) {
        changeGroup(id, action: "Collapse Group") { $0.collapsed.toggle() }
        // A hidden tile can't keep the keyboard.
        if let group = namedGroup(id), group.collapsed {
            if let focused = focusedSurface, group.tiles.contains(focused.id) { window?.makeFirstResponder(canvas) }
            if let focused = model.focused?.value, group.tiles.contains(focused.id) { model.focused = nil }
        }
    }

    /// Opens the collapsed group a tile is in, so it can be shown (or take the keyboard).
    func expandGroup(containing tile: UUID) {
        guard let group = namedGroup(containing: tile), group.collapsed else { return }
        changeGroup(group.id, action: "Expand Group") { $0.collapsed = false }
    }

    func promptRenameGroup(_ id: UUID) {
        guard let group = namedGroup(id) else { return }
        promptRename("Rename Group", current: group.name) { [weak self] in self?.renameGroup(id, to: $0) }
    }

    /// Closing a group closes its tiles, after asking when agents are running in them.
    func closeGroup(_ id: UUID) {
        guard let group = namedGroup(id), let window else { return }
        let surfaces = groupSurfaces(group)
        let agents = surfaces.filter { VerticalTabsAgents.shared.info(for: $0) != nil }.count
        let alert = NSAlert()
        alert.messageText = agents > 0 ? "Close running agents?" : "Close \(group.name)?"
        alert.informativeText = agents > 0
            ? "Closing ends \(agents) session\(agents == 1 ? "" : "s") in \(group.name), and closes its \(surfaces.count) tile\(surfaces.count == 1 ? "" : "s")."
            : "Closes its \(surfaces.count) tile\(surfaces.count == 1 ? "" : "s")."
        alert.addButton(withTitle: "Close \(surfaces.count == 1 ? "Tile" : "All")")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            for surface in surfaces { self.closeSurface(surface, withConfirmation: false) }
        }
    }

    /// Asks what to tell every tile in a group.
    func promptGroupMessage(_ id: UUID) {
        guard let window, let group = namedGroup(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Message \(group.name)"
        alert.informativeText = "Typed into each of its \(group.tiles.count) tiles once its agent is ready."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        field.placeholderString = "What should they do?"
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.messageGroup(id, field.stringValue)
        }
    }

    /// Sends text to every tile in a group: to agents once they're ready, typed into shells.
    @discardableResult
    func messageGroup(_ id: UUID, _ text: String) -> Int {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group = namedGroup(id), !text.isEmpty else { return 0 }
        let surfaces = groupSurfaces(group)
        for surface in surfaces { deliverToAgent(text, to: surface, label: "To \(group.name)") }
        return surfaces.count
    }

    /// Lays a group's tiles out as a grid where the group is.
    func tidyGroup(_ id: UUID) {
        guard let group = namedGroup(id), let frame = groupFrame(group) else { return }
        let placed: [(UUID, CGRect)] = group.tiles.compactMap { id in model.frames[id].map { (id, $0) } }
        let tiles = placed.sorted { a, b in
            abs(a.1.minY - b.1.minY) > 60 ? a.1.minY < b.1.minY : a.1.minX < b.1.minX
        }
        let columns = max(1, tiles.count <= 4 ? tiles.count : Int(ceil(Double(tiles.count).squareRoot())))
        var frames: [UUID: CGRect] = [:]
        var x = frame.minX, y = frame.minY, lineHeight: CGFloat = 0
        for (index, tile) in tiles.enumerated() {
            if index > 0, index % columns == 0 {
                x = frame.minX
                y += lineHeight + Self.gap
                lineHeight = 0
            }
            frames[tile.0] = CGRect(x: x, y: y, width: tile.1.width, height: tile.1.height)
            x += tile.1.width + Self.gap
            lineHeight = max(lineHeight, tile.1.height)
        }
        setFrames(frames, animated: true, undoAction: "Tidy Group")
    }

    /// After a tile is dropped: into the group whose frame it landed in, or out of its own
    /// group when it was dragged well away from the others.
    func regroup(after id: UUID, from start: CGRect? = nil) {
        guard let frame = model.frames[id], model.surfaces.contains(where: { $0.id == id }) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let own = namedGroup(containing: id)
        for group in model.groups where group.id != own?.id && !group.collapsed {
            let others = BoardGroupNode(id: group.id, name: group.name, role: group.role, tiles: group.tiles.filter { $0 != id })
            if let area = groupFrame(others), area.insetBy(dx: -BoardGroupsView.pad, dy: -BoardGroupsView.pad).contains(center) {
                addToGroup([id], group: group.id)
                undoMove(id, to: start)
                return
            }
        }
        guard let own, own.tiles.count > 1 else { return }
        let rest = BoardGroupNode(id: own.id, name: own.name, role: own.role, tiles: own.tiles.filter { $0 != id })
        if let area = groupFrame(rest), !area.insetBy(dx: -Self.gap * 3, dy: -Self.gap * 3).intersects(frame) {
            removeFromGroup(id)
            undoMove(id, to: start)
        }
    }

    /// With the group change just registered: ⌘Z also puts the tile back where it was.
    private func undoMove(_ id: UUID, to frame: CGRect?) {
        guard let frame else { return }
        undoManager?.registerUndo(withTarget: self) { board in
            board.setFrames([id: frame], animated: true, undoAction: nil)
        }
    }

    /// Closed tiles leave their groups; empty groups go.
    func pruneGroups() {
        let ids = Set(model.surfaces.map(\.id))
        var groups = model.groups
        for index in groups.indices { groups[index].tiles.removeAll { !ids.contains($0) } }
        groups.removeAll { $0.tiles.isEmpty }
        if groups != model.groups { model.groups = groups }
    }

    // MARK: Menu

    func groupMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu()
        guard let group = namedGroup(id) else { return menu }
        menu.addItem(ClosureMenuItem("Message \(group.name)…", image: nil) { [weak self] in self?.promptGroupMessage(id) })
        let paused = Set(group.tiles).isSubset(of: model.paused)
        menu.addItem(ClosureMenuItem(paused ? "Resume Group" : "Pause Group", image: nil) { [weak self] in
            self?.setPaused(!paused, group.tiles)
        })
        menu.addItem(ClosureMenuItem(group.collapsed ? "Expand" : "Collapse", image: nil) { [weak self] in self?.toggleCollapsed(id) })
        menu.addItem(ClosureMenuItem("Tidy", image: nil) { [weak self] in self?.tidyGroup(id) })
        if !model.teams.isEmpty {
            let wire = NSMenuItem(title: "Wire to Orchestrator", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for team in model.teams {
                let key = BoardTeams.groupKey(id)
                let item = ClosureMenuItem(orchestratorName(team.id), image: nil) { [weak self] in self?.toggleGroup(key, in: team.id) }
                item.state = team.groups.contains(key) ? .on : .off
                sub.addItem(item)
            }
            wire.submenu = sub
            menu.addItem(wire)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Rename…", image: nil) { [weak self] in self?.promptRenameGroup(id) })
        let roles = NSMenuItem(title: "Role", action: nil, keyEquivalent: "")
        let roleMenu = NSMenu()
        for role in BoardRole.allCases {
            let item = ClosureMenuItem(role.title, image: nil) { [weak self] in self?.setGroupRole(id, role) }
            item.state = group.role == role ? .on : .off
            roleMenu.addItem(item)
        }
        roles.submenu = roleMenu
        menu.addItem(roles)
        menu.addItem(ClosureMenuItem("Ungroup", image: nil) { [weak self] in self?.ungroup(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Group…", image: nil) { [weak self] in self?.closeGroup(id) })
        return menu
    }
}
#endif
