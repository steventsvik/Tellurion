#if os(macOS)
import AppKit

/// Short names for agent tiles ("Otto", "Ada 2"), so you can tell them apart and @mention
/// them; Restart and Duplicate in a tile's title bar.
enum BoardAgentNames {
    static let pool = ["Ada", "Otto", "Cy", "Pip", "Dax", "Maya", "Rafa", "Nova", "Iris", "Kai", "Zoe", "Leo",
                       "Mila", "Ren", "Juno", "Bex", "Box", "Lux", "Tess", "Ivo"]
    static let key = "BoardAgentNames"

    /// On unless turned off in the board's menu.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The next name not used on this board: the pool first, then "Ada 2", "Otto 2", …
    static func next(taken: Set<String>) -> String {
        for round in 1... {
            for name in pool {
                let candidate = round == 1 ? name : "\(name) \(round)"
                if !taken.contains(candidate) { return candidate }
            }
        }
        return "Agent"
    }
}

/// The tiles this run of the app started with permission prompts skipped, because you asked
/// for that in the Group composer or duplicated such a tile. Kept in memory only: a board file
/// is plain JSON that any program running as you can write, so what it says about a tile's
/// command never turns prompts off, and never puts the badge on a tile.
enum BoardSkippedPrompts {
    static var tiles: Set<UUID> = []
}

extension BoardAgent {
    /// The flag that starts it without permission prompts, for agents that have one.
    var skipFlag: String? {
        switch kind {
        case .claude: return "--dangerously-skip-permissions"
        case .codex: return "--dangerously-bypass-approvals-and-sandbox"
        case .gemini, .qwen: return "--yolo"
        default: return nil
        }
    }
}

extension BoardController {
    /// Names an agent tile the first time its agent shows up, unless you named it.
    func nameAgentIfNeeded(_ surface: Ghostty.SurfaceView) {
        guard BoardAgentNames.enabled, model.titles[surface.id] == nil,
              VerticalTabsAgents.shared.info(for: surface) != nil else { return }
        model.titles[surface.id] = BoardAgentNames.next(taken: Set(model.titles.values))
        scheduleSave()
    }

    /// Whether a tile's agent was started with its permission prompts skipped.
    func skipsPermissions(_ id: UUID) -> Bool {
        Self.skipsPermissions(command: commands[id], startedSkipping: BoardSkippedPrompts.tiles.contains(id))
    }

    /// A tile skips prompts only if the app started it that way in this run and its command
    /// still says so (it's dropped when the agent quits). The command alone isn't enough: it
    /// may have come from the board's file.
    nonisolated static func skipsPermissions(command: String?, startedSkipping: Bool) -> Bool {
        guard startedSkipping, let command else { return false }
        return BoardAgent.catalog.contains { agent in agent.skipFlag.map { command.contains($0) } ?? false }
    }

    /// What's typed into a duplicate of a tile: its agent started afresh, the way a new tile
    /// of that kind is, or nothing for a plain terminal. Never the tile's stored command, which
    /// may have come from the board's file.
    nonisolated static func duplicateLine(agent: BoardAgent?, skipsPermissions: Bool) -> String? {
        guard let agent else { return nil }
        let line = agent.command(prompt: nil)
        guard skipsPermissions, let flag = agent.skipFlag, line.hasPrefix(agent.binary) else { return line }
        return agent.binary + " " + flag + line.dropFirst(agent.binary.count)
    }

    /// Starts a tile's agent again in place: its session resumed when it has one, else its
    /// command run again. The tile keeps its place, group and wiring.
    func restartTile(_ view: Ghostty.SurfaceView) {
        guard let model = view.surfaceModel else { return }
        // Its status is gone until the agent is back; a save in between mustn't take that for
        // the agent quitting (which would drop the tile's command).
        restarting.insert(view.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.restarting.remove(view.id) }
        let info = VerticalTabsAgents.shared.info(for: view)
        let record = BoardTile(id: view.id, frame: .zero, cwd: view.pwd,
                               agent: info?.kind.rawValue, session: info.flatMap(ResumeAfterUpdate.session(for:)),
                               command: commands[view.id], title: nil, accounts: BoardTile.savedAccounts(self.model.tileAccounts[view.id]))
        let line = BoardAgent.resumeCommand(for: record)?.trimmingCharacters(in: .whitespacesAndNewlines)
        func key(_ key: Ghostty.Input.Key, _ mods: Ghostty.Input.Mods, _ codepoint: UInt32) {
            model.sendKeyEvent(.init(key: key, action: .press, mods: mods, unshiftedCodepoint: codepoint))
            model.sendKeyEvent(.init(key: key, action: .release, mods: mods, unshiftedCodepoint: codepoint))
        }
        // Agents quit on a second ⌃C; a shell just gets a fresh line.
        key(.c, .ctrl, 99)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if info != nil { key(.c, .ctrl, 99) }
            guard let line, !line.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (info != nil ? 1.2 : 0.2)) {
                model.sendText(line)
                key(.enter, [], 13)
            }
        }
        Ghostty.moveFocus(to: view)
    }

    /// A new tile beside this one, in its folder and in the same group: the same agent started
    /// afresh (without permission prompts if this one was started that way here), or a plain
    /// shell for a plain terminal.
    func duplicateTile(_ view: Ghostty.SurfaceView) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder(of: view) ?? workspace.folder
        let agent = VerticalTabsAgents.shared.info(for: view).flatMap { BoardAgent.forKind($0.kind) }
        let skips = skipsPermissions(view.id)
        let command = Self.duplicateLine(agent: agent, skipsPermissions: skips)
        let size = model.frames[view.id]?.size ?? Self.tileSize
        // One undo step for the copy and its place in the group.
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Duplicate Tile")
        }
        guard let copy = addTile(config: config, command: command, near: view,
                                 frame: freeSpot(size: size, near: model.frames[view.id])) else { return }
        if skips, agent?.skipFlag != nil { BoardSkippedPrompts.tiles.insert(copy.id) }
        if let group = namedGroup(containing: view.id) { addToGroup([copy.id], group: group.id) }
    }
}
#endif
