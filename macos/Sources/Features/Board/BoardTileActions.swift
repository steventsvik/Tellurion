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
        guard let line = commands[id] else { return false }
        return BoardAgent.catalog.contains { agent in agent.skipFlag.map { line.contains($0) } ?? false }
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
                               command: commands[view.id], title: nil)
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

    /// A new tile beside this one, in its folder, running the same agent (with the same
    /// flags), in the same group.
    func duplicateTile(_ view: Ghostty.SurfaceView) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder(of: view) ?? workspace.folder
        let agent = VerticalTabsAgents.shared.info(for: view).flatMap { BoardAgent.forKind($0.kind) }
        // The command it was started with (flags included), else its agent plainly.
        let command = commands[view.id] ?? agent.map { $0.binary + "\n" }
        let size = model.frames[view.id]?.size ?? Self.tileSize
        // One undo step for the copy and its place in the group.
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Duplicate Tile")
        }
        guard let copy = addTile(config: config, command: command, near: view,
                                 frame: freeSpot(size: size, near: model.frames[view.id])) else { return }
        if let group = namedGroup(containing: view.id) { addToGroup([copy.id], group: group.id) }
    }
}
#endif
