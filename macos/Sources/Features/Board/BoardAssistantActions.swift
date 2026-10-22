#if os(macOS)
import AppKit

/// What the board's agent answers: a few words for you, and what to do on the board.
struct BoardAssistantReply: Codable {
    var say: String
    var actions: [BoardAssistantAction]

    /// From an answer's text, with or without a code fence around the JSON.
    static func decode(_ text: String) -> BoardAssistantReply? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// One thing to do on the board. Which fields matter depends on `type` (see BoardAssistantPrompt).
struct BoardAssistantAction: Codable, Equatable {
    struct Node: Codable, Equatable {
        var id: String
        var label: String
        var shape: String?
    }

    struct Edge: Codable, Equatable {
        var from: String
        var to: String
        var label: String?
    }

    struct TeamMember: Codable, Equatable {
        var agent: String
        var role: String
    }

    var type: String
    var tile: String?
    var tiles: [String]?
    var card: String?
    var item: Int?
    var agent: String?
    var count: Int?
    var folder: String?
    var task: String?
    var command: String?
    var text: String?
    var title: String?
    var items: [String]?
    var doing: [String]?
    var done: [String]?
    var nodes: [Node]?
    var edges: [Edge]?
    var target: String?
    var role: String?
    var members: [TeamMember]?

    /// Closing, removing and typing into an agent that's already running wait for you.
    var needsConfirmation: Bool {
        switch type {
        case "close_tile", "remove_card", "message_agent", "command_orchestrator", "message_group", "close_group": return true
        case "hand_item": return tile != nil
        default: return false
        }
    }
}

/// The short names the board's agent uses for what's on the board (T1, C2, S1), for one turn.
struct BoardAssistantHandles {
    var ids: [String: UUID] = [:]

    func id(_ handle: String?) -> UUID? {
        handle.flatMap { ids[$0.trimmingCharacters(in: .whitespaces).uppercased()] }
    }
}

/// What the board's agent is told.
enum BoardAssistantPrompt {
    static let instructions = """
    You are the board agent inside Tellurion, a macOS terminal app. The user's board is a \
    canvas of tiles: terminals (each may run a coding agent such as Claude Code or Codex), \
    notes, checklists, kanban boards, sketches and Agent Maps. You help the user set the \
    board up and run workflows on it: start agents, organize work into cards, hand tasks to \
    agents, sketch plans, and tidy the board. You can't run commands, read files or browse; \
    you act only through the actions below, and the board carries them out.

    Every message gives the board's current state, with handles: T1… for terminal tiles, \
    C1… for cards, S1… for sketches. Use only handles from the latest state.

    Reply with JSON only: {"say": "...", "actions": [...]}. "say" is one or two short, \
    plain sentences for the user (what you did, or a question). If the request is unclear, \
    ask in "say" with no actions. Don't promise anything the actions can't do.

    Actions (each is an object with "type" and the fields shown; omit fields you don't need):
    - launch_agents {agent, count?, folder?, task?, title?}: start `count` (default 1, max 12) \
    agent tiles. agent is one of the installed agents listed in the state, or "shell". task \
    is the first message each one gets.
    - new_terminal {folder?, command?, title?}: a terminal tile; command runs in it.
    - message_agent {tile, text}: type text into a running agent or terminal and press Return.
    - hand_item {card, item, tile? | agent?}: give item number `item` (1-based, as listed) of \
    a checklist or kanban card to an agent: to tile T#, or to a new agent of kind `agent`. \
    The card moves to Doing while it works and to Done when it finishes.
    - close_tile {tile}
    - rename_tile {tile, title}
    - pause {tiles?} / resume {tiles?}: freeze and continue tiles' processes; no tiles = all.
    - add_note {title?, text}
    - add_checklist {title?, items}
    - add_kanban {title?, items, doing?, done?}: items are the To Do column.
    - add_items {card, items}: add to a checklist, or to a kanban's To Do.
    - add_sketch {title?, nodes: [{id, label, shape?}], edges?: [{from, to, label?}]}: a \
    diagram, laid out left to right along the edges. shape: rectangle (default), ellipse, \
    diamond, database or text.
    - agent_map {folder?}: a live map of the project's files with its agents moving through them.
    - remove_card {card}: close a card or sketch (C# or S#).
    - arrange {}: group the tiles by project.
    - show {target?}: zoom to a tile, card or sketch; no target shows everything; target \
    "mission_map" opens the Mission Map (who runs whom, and every agent's status).
    - rename_board {title}
    - create_orchestrator {members: [{agent, role}], folder?, task?}: an orchestrator card \
    wired to new agents, each with a role (Coder, Reviewer, Tester…; up to 8). An \
    orchestrator splits the user's command among its agents and follows up until it's done. \
    task is its first command.
    - wire {card?, tiles}: wire tiles T# to orchestrator card C# (no card: a new orchestrator).
    - unwire {card, tiles}
    - command_orchestrator {card, text}: give orchestrator C# a command.
    - create_group {tiles, title?, role?}: put tiles T# in a new named group (role: frontend, \
    backend, testers, reviewers, design, docs, security or general). Groups are listed with \
    handles G#.
    - add_to_group {target, tiles}: add tiles to group G#.
    - message_group {target, text}: send text to every tile in group G#.
    - close_group {target}: close group G# and its tiles.

    Folders may start with ~. Without one, tiles start in the board's folder. Several actions \
    run in order. Closing, removing and messaging running agents ask the user first, so \
    don't ask for permission yourself.
    """

    /// For Claude Code's structured output. Loose on purpose: the board checks each action.
    static let schema: String = {
        let strings = ["type": "array", "items": ["type": "string"]] as [String: Any]
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["launch_agents", "new_terminal", "message_agent", "hand_item", "close_tile",
                                                    "rename_tile", "pause", "resume", "add_note", "add_checklist", "add_kanban",
                                                    "add_items", "add_sketch", "agent_map", "remove_card", "arrange", "show",
                                                    "rename_board", "create_orchestrator", "wire", "unwire",
                                                    "command_orchestrator", "create_group", "add_to_group",
                                                    "message_group", "close_group"]],
                "tile": ["type": "string"], "tiles": strings, "card": ["type": "string"], "item": ["type": "integer"],
                "agent": ["type": "string"], "count": ["type": "integer"], "folder": ["type": "string"],
                "task": ["type": "string"], "command": ["type": "string"], "text": ["type": "string"],
                "title": ["type": "string"], "items": strings, "doing": strings, "done": strings,
                "target": ["type": "string"], "role": ["type": "string"],
                "members": ["type": "array", "items": ["type": "object", "properties": [
                    "agent": ["type": "string"], "role": ["type": "string"]], "required": ["agent", "role"]]],
                "nodes": ["type": "array", "items": ["type": "object", "properties": [
                    "id": ["type": "string"], "label": ["type": "string"], "shape": ["type": "string"]],
                    "required": ["id", "label"]]],
                "edges": ["type": "array", "items": ["type": "object", "properties": [
                    "from": ["type": "string"], "to": ["type": "string"], "label": ["type": "string"]],
                    "required": ["from", "to"]]],
            ],
            "required": ["type"],
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["say": ["type": "string"], "actions": ["type": "array", "items": action]],
            "required": ["say", "actions"],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }()
}

extension BoardController {
    // MARK: What the board's agent sees

    /// The board in words, with a handle for everything on it.
    func assistantContext(agents: [BoardAgent]) -> (text: String, handles: BoardAssistantHandles) {
        var handles = BoardAssistantHandles()
        var lines = ["Board \"\(model.name)\", folder \(workspace.folder.map(Self.tilde) ?? "~")."]
        lines.append("Installed agents: " + (agents.isEmpty ? "none" : agents.map(\.binary).joined(separator: ", ")) + ".")
        lines.append(model.surfaces.isEmpty ? "Tiles: none." : "Tiles:")
        for (index, surface) in model.surfaces.enumerated() {
            let handle = "T\(index + 1)"
            handles.ids[handle] = surface.id
            var parts = ["\(handle) \"\(tileLabel(surface))\""]
            if let info = VerticalTabsAgents.shared.info(for: surface) {
                parts.append("agent \(info.kind.displayName), \(info.activity.label.lowercased())")
                if let task = info.task { parts.append("task: \(Self.clip(task, 120))") }
            } else {
                parts.append("shell")
            }
            if let folder = folder(of: surface) { parts.append("in \(Self.tilde(folder))") }
            if model.paused.contains(surface.id) { parts.append("paused") }
            let wired = orchestrators(of: surface.id).compactMap { team in
                model.cards.firstIndex { $0.id == team.id }.map { "C\($0 + 1)" }
            }
            if !wired.isEmpty { parts.append("wired to " + wired.joined(separator: ", ")) }
            lines.append("- " + parts.joined(separator: "; "))
        }
        if !model.groups.isEmpty { lines.append("Groups:") }
        for (index, group) in model.groups.enumerated() {
            let handle = "G\(index + 1)"
            handles.ids[handle] = group.id
            let tiles = group.tiles.compactMap { id in model.surfaces.firstIndex { $0.id == id }.map { "T\($0 + 1)" } }
            lines.append("- \(handle) \"\(group.name)\" (\(group.role.title)): " + tiles.joined(separator: ", ")
                         + (group.collapsed ? "; collapsed" : ""))
        }
        if !model.cards.isEmpty { lines.append("Cards:") }
        for (index, card) in model.cards.enumerated() {
            let handle = "C\(index + 1)"
            handles.ids[handle] = card.id
            switch card.kind {
            case .note:
                lines.append("- \(handle) note \"\(card.title)\": \(Self.clip(card.text, 300))")
            case .document:
                lines.append("- \(handle) document \"\(card.title)\"")
            case .web:
                lines.append("- \(handle) web tile \"\(card.title)\": " + (card.tabs ?? []).filter { !$0.isEmpty }.joined(separator: ", "))
            case .orchestrator:
                lines.append("- \(handle) orchestrator \"\(card.title)\"" + orchestratorSummary(card.id))
            case .map:
                lines.append("- \(handle) Agent Map of \(card.folder.map(Self.tilde) ?? "no project")")
            case .checklist, .kanban:
                lines.append("- \(handle) \(card.kind.rawValue) \"\(card.title)\":")
                for (number, item) in card.items.enumerated() where !item.text.isEmpty {
                    let state = card.kind == .kanban ? CardItem.columns[min(max(item.column, 0), 2)] : (item.done ? "done" : "not done")
                    let owner = item.agent.flatMap { id in model.surfaces.firstIndex { $0.id == id } }.map { ", with T\($0 + 1)" } ?? ""
                    lines.append("  \(number + 1). \(Self.clip(item.text, 120)) [\(state)\(owner)]")
                }
            }
        }
        if !model.sketches.isEmpty { lines.append("Sketches:") }
        for (index, sketch) in model.sketches.enumerated() {
            let handle = "S\(index + 1)"
            handles.ids[handle] = sketch.id
            let labels = sketch.elements.compactMap { $0.kind.isBox ? $0.text : nil }.filter { !$0.isEmpty }.prefix(20)
            lines.append("- \(handle) \"\(sketch.title)\"" + (labels.isEmpty ? "" : ": " + labels.joined(separator: ", ")))
        }
        return (lines.joined(separator: "\n"), handles)
    }

    /// A tile's name in the list and in @mentions: its given name, its agent, or its title;
    /// "Claude Code 2" when another tile has the same one.
    func tileLabel(_ surface: Ghostty.SurfaceView) -> String {
        tileLabels().first { $0.id == surface.id }?.label ?? BoardTileTitle.title(surface, nil)
    }

    func tileLabels() -> [(id: UUID, label: String, surface: Ghostty.SurfaceView)] {
        var seen: [String: Int] = [:]
        return model.surfaces.map { surface in
            let base = BoardTileTitle.title(surface, VerticalTabsAgents.shared.info(for: surface), name: model.titles[surface.id])
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return (surface.id, n == 1 ? base : "\(base) \(n)", surface)
        }
    }

    /// A group @mentioned in `text` ("@Backend fix the tests"), and the text without it.
    func groupMention(in text: String) -> (group: BoardGroupNode, rest: String)? {
        // Longest first, so "@Backend 2" isn't read as "@Backend".
        for group in model.groups.sorted(by: { $0.name.count > $1.name.count }) {
            let token = "@" + group.name
            guard text.range(of: token, options: .caseInsensitive) != nil else { continue }
            let rest = text.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
            return (group, rest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// The tiles @mentioned in `text`, and the text without them.
    func mentions(in text: String) -> (tiles: [Ghostty.SurfaceView], rest: String) {
        var rest = text
        var tiles: [Ghostty.SurfaceView] = []
        // Longest first, so "@Claude Code 2" isn't read as "@Claude Code".
        for entry in tileLabels().sorted(by: { $0.label.count > $1.label.count }) {
            let token = "@" + entry.label
            guard rest.range(of: token, options: .caseInsensitive) != nil else { continue }
            rest = rest.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
            tiles.append(entry.surface)
        }
        return (tiles, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "; wired to T1, T3 and group web; working" for the board's agent.
    func orchestratorSummary(_ id: UUID) -> String {
        guard let team = orchestrator(id) else { return "" }
        let tiles = team.members.compactMap { member in model.surfaces.firstIndex { $0.id == member.tile }.map { "T\($0 + 1)" } }
        let wired = tiles + team.groups.map { "group \(groupTitle($0))" }
        var text = "; wired to " + (wired.isEmpty ? "nothing" : wired.joined(separator: ", "))
        if let brain = orchestratorBrains[id], brain.running { text += "; working on: \(Self.clip(team.goal ?? "", 120))" }
        return text
    }

    private static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private static func clip(_ text: String, _ length: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }

    // MARK: Doing it

    /// Carries out the actions in order. Unless `confirmed`, the ones that need you wait; the
    /// rest happen now, as one step for ⌘Z.
    func perform(_ actions: [BoardAssistantAction], handles: BoardAssistantHandles,
                 confirmed: Bool) -> (done: [String], waiting: [BoardAssistantAction]) {
        var done: [String] = []
        var waiting: [BoardAssistantAction] = []
        let before = Set(model.nodeIDs)
        undoManager?.beginUndoGrouping()
        for action in actions {
            if action.needsConfirmation && !confirmed {
                if describe(action, handles: handles) != nil { waiting.append(action) }
                continue
            }
            if let line = perform(action, handles: handles) { done.append(line) }
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Board Agent")
        // Shows everything it added (unless it chose what to show), after each new tile's own
        // scroll into view.
        let added = model.nodeIDs.filter { !before.contains($0) }
        if !added.isEmpty, !actions.contains(where: { $0.type == "show" }) {
            DispatchQueue.main.async {
                DispatchQueue.main.async { [weak self] in self?.showAdded(added) }
            }
        }
        return (done, waiting)
    }

    /// Fits what the board's agent added in view, clear of the bar at the bottom.
    private func showAdded(_ ids: [UUID]) {
        let frames = ids.compactMap { model.frames[$0] }
        guard let first = frames.first else { return }
        var rect = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -40, dy: -40)
        rect.size.height += 160
        // Zooms out only when it doesn't fit as it is.
        if let visible = canvas?.documentVisibleRect, rect.width <= visible.width, rect.height <= visible.height {
            revealRect(rect)
        } else {
            zoom(toFit: rect, animated: true)
        }
    }

    /// What a waiting action will do, or nil when it points at nothing.
    func describe(_ action: BoardAssistantAction, handles: BoardAssistantHandles) -> String? {
        switch action.type {
        case "close_tile":
            return surface(action.tile, handles).map { "Close \(tileName($0))" }
        case "remove_card":
            guard let id = handles.id(action.card) else { return nil }
            if let card = model.cards.first(where: { $0.id == id }) { return "Close \(card.title)" }
            return model.sketches.first { $0.id == id }.map { "Close \($0.title)" }
        case "message_agent":
            guard let surface = surface(action.tile, handles), let text = action.text, !text.isEmpty else { return nil }
            return "Send \(tileName(surface)): “\(Self.clip(text, 80))”"
        case "hand_item":
            guard let surface = surface(action.tile, handles), let item = item(action, handles) else { return nil }
            return "Give \(tileLabel(surface)): “\(Self.clip(item.item.text, 80))”"
        case "message_group":
            guard let id = handles.id(action.target), let group = namedGroup(id) else { return nil }
            return "Send to \(group.name)'s \(group.tiles.count) tiles: “\(action.text ?? "")”"
        case "close_group":
            guard let id = handles.id(action.target), let group = namedGroup(id) else { return nil }
            return "Close \(group.name) and its \(group.tiles.count) tiles"
        case "command_orchestrator":
            guard let id = handles.id(action.card), orchestrator(id) != nil else { return nil }
            return "Give \(orchestratorName(id)) the command “\(action.text ?? "")” (it messages its agents)"
        default:
            return nil
        }
    }

    /// "Claude Code 2", or "the terminal “~”" for a tile without an agent.
    private func tileName(_ surface: Ghostty.SurfaceView) -> String {
        let label = tileLabel(surface)
        if VerticalTabsAgents.shared.info(for: surface) != nil || model.titles[surface.id] != nil { return label }
        return "the terminal “\(label)”"
    }

    private func surface(_ handle: String?, _ handles: BoardAssistantHandles) -> Ghostty.SurfaceView? {
        handles.id(handle).flatMap { id in model.surfaces.first { $0.id == id } }
    }

    private func item(_ action: BoardAssistantAction, _ handles: BoardAssistantHandles) -> (card: BoardCard, item: CardItem)? {
        guard let id = handles.id(action.card), let card = model.cards.first(where: { $0.id == id }) else { return nil }
        // Numbered as the state listed them: blank items skipped.
        let items = card.items.filter { !$0.text.isEmpty }
        guard let n = action.item, n >= 1, n <= items.count else { return nil }
        return (card, items[n - 1])
    }

    private func folder(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isFolder) && isFolder.boolValue ? expanded : nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func perform(_ action: BoardAssistantAction, handles: BoardAssistantHandles) -> String? {
        switch action.type {
        case "launch_agents":
            let count = min(max(action.count ?? 1, 1), 12)
            if let path = action.folder, folder(path) == nil { return "No folder \(path)" }
            let folder = folder(action.folder)
            let task = action.task?.trimmingCharacters(in: .whitespacesAndNewlines)
            if action.agent == nil || action.agent == "shell" {
                launch(Array(repeating: (agent: nil as BoardAgent?, command: ""), count: count), folder: folder)
                return count == 1 ? "Opened a terminal" : "Opened \(count) terminals"
            }
            guard let agent = BoardAgent.catalog.first(where: { $0.binary == action.agent || $0.kind.rawValue == action.agent }) else {
                return "\(action.agent ?? "That agent") isn't one the board can start"
            }
            let lines = (0..<count).map { _ in (agent: Optional(agent), command: agent.command(prompt: task?.isEmpty == false ? task : nil)) }
            let before = Set(model.surfaces.map(\.id))
            launch(lines, folder: folder)
            if let title = action.title, !title.isEmpty {
                for (n, surface) in model.surfaces.filter({ !before.contains($0.id) }).enumerated() {
                    model.titles[surface.id] = count == 1 ? title : "\(title) \(n + 1)"
                }
            }
            return "Started \(count) \(agent.kind.displayName)" + (count == 1 ? "" : " tiles")
        case "new_terminal":
            var config = Ghostty.SurfaceConfiguration()
            if let path = action.folder {
                guard let folder = folder(path) else { return "No folder \(path)" }
                config.workingDirectory = folder
            }
            let command = action.command.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }
            guard let view = addTile(config: config, command: command) else { return nil }
            if let title = action.title, !title.isEmpty { model.titles[view.id] = title }
            return "Opened " + (action.title.map { "“\($0)”" } ?? "a terminal")
        case "message_agent":
            guard let surface = surface(action.tile, handles), let text = action.text, !text.isEmpty else { return nil }
            deliver(text, to: surface)
            return "Sent to \(tileLabel(surface))"
        case "hand_item":
            guard let found = item(action, handles) else { return "No such item" }
            if let surface = surface(action.tile, handles) {
                hand(found.item.id, in: found.card.id, to: surface)
                return "Gave “\(Self.clip(found.item.text, 40))” to \(tileLabel(surface))"
            }
            let kind: VerticalTabAgentKind = action.agent == "codex" ? .codex : .claude
            hand(found.item.id, in: found.card.id, newAgent: kind)
            return "Gave “\(Self.clip(found.item.text, 40))” to a new \(kind.displayName)"
        case "close_tile":
            guard let surface = surface(action.tile, handles) else { return nil }
            let name = tileLabel(surface)
            closeSurface(surface, withConfirmation: false)
            return "Closed \(name)"
        case "rename_tile":
            guard let surface = surface(action.tile, handles), let title = action.title else { return nil }
            setTitle(title, for: surface)
            return "Renamed a tile “\(title)”"
        case "pause", "resume":
            let ids = action.tiles.map { $0.compactMap { handles.id($0) } }
            setPaused(action.type == "pause", ids)
            let what = ids.map { $0.count == 1 ? "1 tile" : "\($0.count) tiles" } ?? "every tile"
            return (action.type == "pause" ? "Paused " : "Resumed ") + what
        case "add_note":
            let id = addCard(.note, edit: false)
            updateCard(id) { card in
                card.text = action.text ?? ""
                if let title = action.title, !title.isEmpty { card.title = title }
            }
            return "Added a note"
        case "add_checklist", "add_kanban":
            let kanban = action.type == "add_kanban"
            let id = addCard(kanban ? .kanban : .checklist, edit: false)
            updateCard(id) { card in
                if let title = action.title, !title.isEmpty { card.title = title }
                card.items = (action.items ?? []).map { CardItem(text: $0) }
                if kanban {
                    card.items += (action.doing ?? []).map { CardItem(text: $0, column: 1) }
                    card.items += (action.done ?? []).map { CardItem(text: $0, done: true, column: 2) }
                }
            }
            return kanban ? "Added a kanban board" : "Added a checklist"
        case "add_items":
            guard let id = handles.id(action.card), let card = model.cards.first(where: { $0.id == id }),
                  card.kind == .checklist || card.kind == .kanban, let items = action.items else { return nil }
            updateCard(id) { $0.items += items.map { CardItem(text: $0) } }
            return "Added \(items.count) to \(card.title)"
        case "add_sketch":
            let diagram = BoardDiagram.elements(nodes: action.nodes ?? [], edges: action.edges ?? [])
            let id = addSketch(elements: diagram.elements, size: diagram.size, focus: false)
            if let title = action.title, !title.isEmpty { renameSketch(id, to: title) }
            return "Sketched " + (action.title.map { "“\($0)”" } ?? "a diagram")
        case "agent_map":
            if let path = action.folder {
                guard let folder = folder(path) else { return "No folder \(path)" }
                let id = addCard(.map, edit: false)
                setMapFolder(id, to: folder)
            } else {
                showAgentMap()
            }
            return "Opened the Agent Map"
        case "remove_card":
            guard let id = handles.id(action.card) else { return nil }
            if let card = model.cards.first(where: { $0.id == id }) {
                removeCard(id)
                return "Closed \(card.title)"
            }
            guard let sketch = model.sketches.first(where: { $0.id == id }) else { return nil }
            removeSketch(id)
            return "Closed \(sketch.title)"
        case "arrange":
            arrangeByProject()
            return "Grouped the tiles by project"
        case "show":
            if action.target?.lowercased() == "mission_map" {
                model.showMissionMap = true
                return "Opened the Mission Map"
            }
            if let id = handles.id(action.target ?? action.tile ?? action.card), model.frames[id] != nil {
                zoom(toNode: id)
            } else {
                fitAll()
            }
            return nil
        case "rename_board":
            guard let title = action.title, !title.isEmpty else { return nil }
            rename(title)
            return "Renamed the board “\(title)”"
        case "create_orchestrator":
            if let path = action.folder, folder(path) == nil { return "No folder \(path)" }
            let find = { (name: String) in BoardAgent.catalog.first { $0.binary == name || $0.kind.rawValue == name } }
            let members = (action.members ?? []).prefix(8).map { (agent: find($0.agent), role: $0.role.isEmpty ? "Member" : $0.role) }
            let goal = (action.task ?? action.text)?.trimmingCharacters(in: .whitespacesAndNewlines)
            launchOrchestrator(members: Array(members), folder: folder(action.folder), goal: goal?.isEmpty == false ? goal : nil)
            return "Started an orchestrator with \(members.count) agent" + (members.count == 1 ? "" : "s")
        case "wire":
            let tiles = (action.tiles ?? action.tile.map { [$0] } ?? []).compactMap { surface($0, handles)?.id }
            guard !tiles.isEmpty else { return nil }
            if let id = handles.id(action.card), orchestrator(id) != nil {
                wire(tiles, to: id)
                return "Wired \(tiles.count) tile\(tiles.count == 1 ? "" : "s") to \(orchestratorName(id))"
            }
            let near = tiles.compactMap { model.frames[$0] }.reduce(CGRect.null) { $0.union($1) }
            newOrchestrator(at: near.isNull ? nil : CGPoint(x: near.midX, y: near.minY - BoardCard.Kind.orchestrator.size.height / 2 - 60),
                            wiring: tiles)
            return "Wired \(tiles.count) tile\(tiles.count == 1 ? "" : "s") to a new orchestrator"
        case "unwire":
            guard let id = handles.id(action.card), orchestrator(id) != nil else { return nil }
            let tiles = (action.tiles ?? action.tile.map { [$0] } ?? []).compactMap { surface($0, handles)?.id }
            for tile in tiles { unwire(tile, from: id) }
            return tiles.isEmpty ? nil : "Unwired \(tiles.count) tile\(tiles.count == 1 ? "" : "s")"
        case "create_group":
            let tiles = (action.tiles ?? action.tile.map { [$0] } ?? []).compactMap { surface($0, handles)?.id }
            guard !tiles.isEmpty else { return nil }
            let role = BoardRole(rawValue: (action.role ?? "general").lowercased()) ?? .general
            let id = createGroup(tiles, name: action.title, role: role)
            return "Grouped \(tiles.count) tile\(tiles.count == 1 ? "" : "s") as \(namedGroup(id)?.name ?? role.title)"
        case "add_to_group":
            guard let id = handles.id(action.target), let group = namedGroup(id) else { return nil }
            let tiles = (action.tiles ?? action.tile.map { [$0] } ?? []).compactMap { surface($0, handles)?.id }
            guard !tiles.isEmpty else { return nil }
            addToGroup(tiles, group: id)
            return "Added \(tiles.count) tile\(tiles.count == 1 ? "" : "s") to \(group.name)"
        case "message_group":
            guard let id = handles.id(action.target), let group = namedGroup(id), let text = action.text else { return nil }
            let count = messageGroup(id, text)
            return "Sent to \(group.name) (\(count) tile\(count == 1 ? "" : "s"))"
        case "close_group":
            guard let id = handles.id(action.target), let group = namedGroup(id) else { return nil }
            for surface in groupSurfaces(group) { closeSurface(surface, withConfirmation: false) }
            return "Closed \(group.name)"
        case "command_orchestrator":
            guard let id = handles.id(action.card), orchestrator(id) != nil, let text = action.text, !text.isEmpty else { return nil }
            orchestratorBrain(id).lookUp()
            orchestratorBrain(id).command(text)
            return "Gave \(orchestratorName(id)) the command"
        default:
            return nil
        }
    }
}

/// Boxes and arrows for a sketch the board's agent draws: columns by how far along the edges
/// a box is, rows on a grid. A box goes in its first arrow's row, so a chain reads straight
/// across, unless an arrow into it would cut through another box: then it takes the nearest
/// row (at most one past the others) whose arrows cross the fewest boxes.
enum BoardDiagram {
    static let box = CGSize(width: 200, height: 84)
    static let gap = CGSize(width: 150, height: 56)
    static let margin: CGFloat = 48

    static func elements(nodes: [BoardAssistantAction.Node], edges: [BoardAssistantAction.Edge]) -> (elements: [SketchElement], size: CGSize) {
        let nodes = nodes.reduce(into: [BoardAssistantAction.Node]()) { list, node in
            if !list.contains(where: { $0.id == node.id }) { list.append(node) }
        }
        guard !nodes.isEmpty else { return ([], BoardController.sketchSize) }
        let edges = edges.filter { edge in edge.from != edge.to && nodes.contains { $0.id == edge.from } && nodes.contains { $0.id == edge.to } }
        let column = columns(nodes, edges)
        var row: [String: Int] = [:]
        var taken: Set<[Int]> = []
        func frame(_ c: Int, _ r: Int) -> CGRect {
            CGRect(x: margin + CGFloat(c) * (box.width + gap.width), y: margin + CGFloat(r) * (box.height + gap.height),
                   width: box.width, height: box.height)
        }
        /// How many boxes already placed the arrows into a box at `r` would pass through.
        func crossings(_ node: String, _ r: Int) -> Int {
            let to = frame(column[node] ?? 0, r)
            var count = 0
            for edge in edges where edge.to == node {
                guard let c = column[edge.from], let fr = row[edge.from] else { continue }
                let from = frame(c, fr)
                let a = CGPoint(x: from.midX, y: from.midY), b = CGPoint(x: to.midX, y: to.midY)
                for (other, orow) in row where other != edge.from {
                    let box = frame(column[other] ?? 0, orow).insetBy(dx: -4, dy: -4)
                    if (1..<40).contains(where: { i in
                        let t = CGFloat(i) / 40
                        return box.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    }) { count += 1 }
                }
            }
            return count
        }
        for c in 0...(column.values.max() ?? 0) {
            for node in nodes where column[node.id] == c {
                let preferred = edges.first { $0.to == node.id }.flatMap { row[$0.from] } ?? 0
                let limit = (row.values.max() ?? -1) + 2
                let free = (0...max(limit, preferred)).filter { !taken.contains([c, $0]) }
                func cost(_ r: Int) -> (Int, Int, Int) { (crossings(node.id, r), abs(r - preferred), r) }
                let r = free.min { cost($0) < cost($1) } ?? 0
                row[node.id] = r
                taken.insert([c, r])
            }
        }
        var elements: [SketchElement] = []
        var ids: [String: UUID] = [:]
        var frames: [String: CGRect] = [:]
        for node in nodes {
            let rect = frame(column[node.id] ?? 0, row[node.id] ?? 0)
            frames[node.id] = rect
            let kind = SketchElement.Kind(rawValue: node.shape ?? "").flatMap { $0.isBox && $0 != .image ? $0 : nil } ?? .rectangle
            let element = SketchElement(kind: kind, frame: rect, color: kind == .database ? 1 : 0, text: node.label)
            ids[node.id] = element.id
            elements.append(element)
        }
        for edge in edges {
            guard let from = frames[edge.from], let to = frames[edge.to], let start = ids[edge.from], let end = ids[edge.to] else { continue }
            let a = CGPoint(x: from.midX, y: from.midY), b = CGPoint(x: to.midX, y: to.midY)
            elements.append(SketchElement(kind: .arrow, points: [a, b], start: start, end: end))
            if let label = edge.label, !label.isEmpty {
                // Above the arrow, in the gap between the boxes.
                let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                elements.append(SketchElement(kind: .text, frame: CGRect(x: middle.x - 65, y: middle.y - 34, width: 130, height: 26),
                                              width: 1.5, text: label))
            }
        }
        let bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
        let size = CGSize(width: max(BoardController.sketchSize.width, bounds.maxX + margin),
                          height: max(BoardController.sketchSize.height, bounds.maxY + margin + 40))
        return (elements, size)
    }

    /// Each box's column: the longest path to it from a box nothing points at. Capped, so a
    /// cycle ends.
    private static func columns(_ nodes: [BoardAssistantAction.Node], _ edges: [BoardAssistantAction.Edge]) -> [String: Int] {
        var level: [String: Int] = [:]
        for node in nodes { level[node.id] = 0 }
        for _ in 0..<nodes.count {
            var changed = false
            for edge in edges {
                let next = (level[edge.from] ?? 0) + 1
                if next > (level[edge.to] ?? 0), next < nodes.count {
                    level[edge.to] = next
                    changed = true
                }
            }
            if !changed { break }
        }
        // No empty columns.
        let used = Array(Set(level.values)).sorted()
        return level.mapValues { used.firstIndex(of: $0) ?? 0 }
    }
}
#endif
