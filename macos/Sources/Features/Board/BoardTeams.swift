#if os(macOS)
import AppKit

/// An orchestrator on a board: a card (BoardCard.Kind.orchestrator) wired to terminals and to
/// whole project groups. You give it a command; its brain (OrchestratorBrain) hands each
/// wired agent its part, reads what they answer when they finish, and follows up until it's
/// done. Saved with the board, keyed by the card's id.
struct BoardTeam: Codable, Identifiable, Equatable {
    struct Member: Codable, Equatable {
        var tile: UUID
        var role: String?
    }

    /// The orchestrator card's.
    let id: UUID
    /// Terminals wired one by one.
    var members: [Member] = []
    /// Project groups wired whole (BoardProjects paths): every tile of the project counts,
    /// including ones opened later.
    var groups: [String] = []
    var goal: String?
    /// An index into BoardProjects.palette.
    var color = BoardTeams.color
    /// How many turns it takes on its own per command (nil: BoardTeams.turns).
    var turns: Int?
}

/// A wire from an orchestrator to a terminal or a group, for BoardGroupsView.
struct BoardTeamLink: Equatable {
    let from: CGRect
    let to: CGRect
    let color: Int
    /// Something on the far end is working: dots travel along the wire.
    let working: Bool
}

/// A wired agent, as the orchestrator sees it.
struct BoardTeamAgent {
    let surface: Ghostty.SurfaceView
    let role: String?
    /// The group it came with, if it wasn't wired by itself.
    let group: String?
}

enum BoardTeams {
    static let roles = ["Coder", "Reviewer", "Tester", "Researcher", "Designer", "Writer"]
    /// Orange.
    static let color = 7
    static let turns = 12
    static let maxAgents = 24

    /// How an orchestrator names a named group it's wired to (project groups are their path).
    static func groupKey(_ id: UUID) -> String { "group:" + id.uuidString }

    static func groupID(_ key: String) -> UUID? {
        key.hasPrefix("group:") ? UUID(uuidString: String(key.dropFirst(6))) : nil
    }

    static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}

/// What orchestrators have yet to hear from their agents, sent together a moment after the
/// last of it.
final class BoardTeamRelay {
    /// Each tile's agent status when last seen.
    var last: [UUID: VerticalTabAgentActivity] = [:]
    /// Per orchestrator: the agents to report on, and what happened.
    var pending: [UUID: [(tile: UUID, activity: VerticalTabAgentActivity, detail: String?)]] = [:]
    var flush: [UUID: DispatchWorkItem] = [:]
}

extension BoardController {
    // MARK: Looking up

    func orchestrator(_ id: UUID) -> BoardTeam? { model.teams.first { $0.id == id } }

    func orchestratorName(_ id: UUID) -> String {
        model.cards.first { $0.id == id }?.title ?? "Orchestrator"
    }

    /// The tiles of a wired group: a named group's, or a project's on this board.
    func groupTiles(_ key: String) -> [Ghostty.SurfaceView] {
        if let id = BoardTeams.groupID(key) { return namedGroup(id).map(groupSurfaces) ?? [] }
        return model.surfaces.filter { model.projects[$0.id] == key }
    }

    /// A wired group's name: a named group's, or the project folder's.
    func groupTitle(_ key: String) -> String {
        if let id = BoardTeams.groupID(key) { return namedGroup(id)?.name ?? "Group" }
        return BoardProjects.name(key)
    }

    /// Everything wired: terminals first, then each group's tiles, each once.
    func wiredAgents(_ team: BoardTeam) -> [BoardTeamAgent] {
        var seen = Set<UUID>()
        var agents: [BoardTeamAgent] = []
        for member in team.members {
            guard let surface = surface(member.tile), seen.insert(member.tile).inserted else { continue }
            agents.append(BoardTeamAgent(surface: surface, role: member.role, group: nil))
        }
        for project in team.groups {
            for surface in groupTiles(project) where seen.insert(surface.id).inserted {
                agents.append(BoardTeamAgent(surface: surface, role: nil, group: project))
            }
        }
        return agents
    }

    /// The orchestrators a tile is wired to, by itself or with its group.
    func orchestrators(of tile: UUID) -> [BoardTeam] {
        let project = model.projects[tile]
        let named = namedGroup(containing: tile).map { BoardTeams.groupKey($0.id) }
        return model.teams.filter { team in
            team.members.contains { $0.tile == tile } || project.map(team.groups.contains) == true
                || named.map(team.groups.contains) == true
        }
    }

    func isWired(_ tile: UUID, to id: UUID) -> Bool {
        orchestrator(id)?.members.contains { $0.tile == tile } == true
    }

    func role(of tile: UUID, in id: UUID) -> String? {
        orchestrator(id)?.members.first { $0.tile == tile }?.role
    }

    private func surface(_ id: UUID) -> Ghostty.SurfaceView? { model.surfaces.first { $0.id == id } }

    /// The wires: to each terminal wired by itself, and to each wired group's area (or to its
    /// tiles, when they're spread out).
    func teamLinks() -> [BoardTeamLink] {
        guard !model.teams.isEmpty else { return [] }
        let areas = BoardTiles.groups(model)
        var links: [BoardTeamLink] = []
        for team in model.teams {
            guard let card = model.frames[team.id] else { continue }
            let grouped = Set(team.groups.flatMap { groupTiles($0).map(\.id) })
            for member in team.members where !grouped.contains(member.tile) {
                guard let frame = model.frames[member.tile], let tile = surface(member.tile) else { continue }
                links.append(BoardTeamLink(from: card, to: frame, color: team.color, working: isWorking(tile)))
            }
            for project in team.groups {
                let tiles = groupTiles(project)
                let working = tiles.contains { isWorking($0) }
                if let id = BoardTeams.groupID(project), let group = namedGroup(id), let frame = groupFrame(group) {
                    links.append(BoardTeamLink(from: card, to: frame.insetBy(dx: -BoardGroupsView.pad, dy: -BoardGroupsView.pad),
                                               color: team.color, working: working))
                } else if let area = areas.first(where: { $0.project == project && $0.tiles.count == tiles.count }) {
                    links.append(BoardTeamLink(from: card, to: area.frame, color: team.color, working: working))
                } else {
                    for tile in tiles {
                        guard let frame = model.frames[tile.id] else { continue }
                        links.append(BoardTeamLink(from: card, to: frame, color: team.color, working: isWorking(tile)))
                    }
                }
            }
        }
        return links
    }

    private func isWorking(_ surface: Ghostty.SurfaceView) -> Bool {
        VerticalTabsAgents.shared.info(for: surface)?.activity == .working && !model.paused.contains(surface.id)
    }

    // MARK: Changing

    /// Replaces the orchestrators; ⌘Z puts the old ones back.
    func setTeams(_ teams: [BoardTeam], action: String) {
        let old = model.teams
        guard old != teams else { return }
        model.teams = teams
        undoManager?.registerUndo(withTarget: self) { $0.setTeams(old, action: action) }
        undoManager?.setActionName(action)
        scheduleSave()
    }

    private func changeTeam(_ id: UUID, action: String, _ change: (inout BoardTeam) -> Void) {
        guard ensureTeam(id) != nil, let index = model.teams.firstIndex(where: { $0.id == id }) else { return }
        var teams = model.teams
        change(&teams[index])
        setTeams(teams, action: action)
    }

    /// An orchestrator card's team, made on the spot when the card has none (a board file
    /// from before, or one whose team was lost): without it, wiring and commands would do
    /// nothing, silently.
    @discardableResult
    func ensureTeam(_ id: UUID) -> BoardTeam? {
        if let team = orchestrator(id) { return team }
        guard model.cards.contains(where: { $0.id == id && $0.kind == .orchestrator }) else { return nil }
        let team = BoardTeam(id: id)
        model.teams.append(team)
        scheduleSave()
        return team
    }

    /// A new orchestrator card at `point` (or beside the focused tile), wired to `tiles`.
    @discardableResult
    func newOrchestrator(at point: CGPoint? = nil, wiring tiles: [UUID] = [], groups: [String] = [], goal: String? = nil) -> UUID {
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        // Room around it, so its wires have length to curve.
        let size = BoardCard.Kind.orchestrator.size
        let room = point == nil ? spot(for: CGSize(width: size.width + 280, height: size.height + 160), at: nil) : nil
        let id = addCard(.orchestrator, at: point ?? room.map { CGPoint(x: $0.midX, y: $0.midY) }, edit: false)
        let used = Set(model.teams.map(\.color))
        // Orange first, then colors no other orchestrator has.
        let color = ([BoardTeams.color] + Array(0..<BoardProjects.palette.count)).first { !used.contains($0) } ?? BoardTeams.color
        var team = BoardTeam(id: id, members: tiles.filter { surface($0) != nil }.map { BoardTeam.Member(tile: $0) },
                             groups: groups, goal: goal, color: color)
        team.goal = goal?.isEmpty == true ? nil : goal
        setTeams(model.teams + [team], action: "New Orchestrator")
        undoManager?.setActionName("New Orchestrator")
        return id
    }

    func wire(_ tiles: [UUID], to id: UUID, role: String? = nil) {
        changeTeam(id, action: "Wire to Orchestrator") { team in
            for tile in tiles where surface(tile) != nil && !team.members.contains(where: { $0.tile == tile }) {
                team.members.append(BoardTeam.Member(tile: tile, role: role))
            }
        }
    }

    /// Unwires a terminal from one orchestrator, or from all of them.
    func unwire(_ tile: UUID, from id: UUID? = nil) {
        let teams = model.teams.map { team -> BoardTeam in
            guard id == nil || team.id == id else { return team }
            var team = team
            team.members.removeAll { $0.tile == tile }
            return team
        }
        setTeams(teams, action: "Unwire")
    }

    func toggleWire(_ tile: UUID, in id: UUID) {
        DemoDirector.note("orchestrator wire \(isWired(tile, to: id) ? "off" : "on")")
        if isWired(tile, to: id) { unwire(tile, from: id) } else { wire([tile], to: id) }
    }

    func toggleGroup(_ project: String, in id: UUID) {
        changeTeam(id, action: "Wire Group") { team in
            if team.groups.contains(project) {
                team.groups.removeAll { $0 == project }
            } else {
                team.groups.append(project)
            }
        }
    }

    func setRole(_ role: String?, for tile: UUID, in id: UUID) {
        let role = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        changeTeam(id, action: "Change Role") { team in
            for index in team.members.indices where team.members[index].tile == tile {
                team.members[index].role = role?.isEmpty == false ? role : nil
            }
        }
    }

    func setTurns(_ turns: Int, for id: UUID) {
        changeTeam(id, action: "Turn Limit") { $0.turns = turns == BoardTeams.turns ? nil : turns }
    }

    /// Clicks on tiles and group labels wire them to this orchestrator until it's done.
    func startWiring(_ id: UUID) {
        model.wiring = id
        guard wiringMonitor == nil else { return }
        // Taken before the tiles see them, so a click wires whatever the zoom and wherever
        // the keyboard is; Escape is done, as the Done button is.
        wiringMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            DemoDirector.note("wiring monitor \(event.type == .keyDown ? "key" : "click") ours=\(event.window === self?.window) wiring=\(self?.model.wiring != nil)")
            guard let self, event.window === self.window, let id = self.model.wiring else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.endWiring()
                return nil
            }
            return self.wiringClick(event, id) ? nil : event
        }
    }

    /// A click on a terminal while connecting (not on its buttons, or on anything over it):
    /// wires or unwires it.
    private func wiringClick(_ event: NSEvent, _ id: UUID) -> Bool {
        guard let document = groupsView?.superview,
              let hit = window?.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: document),
              hit !== groupsView else {
            DemoDirector.note("wiring click: not on the board")
            return false
        }
        let point = document.convert(event.locationInWindow, from: nil)
        guard let top = model.order.reversed().first(where: { model.frames[$0]?.contains(point) == true }),
              model.surfaces.contains(where: { $0.id == top }) else {
            DemoDirector.note("wiring click: nothing to wire at \(point)")
            return false
        }
        var node: NSView? = hit
        while let view = node, !(view is BoardNodeView) { node = view.superview }
        if let node = node as? BoardNodeView, !node.isHandle {
            let local = node.convert(event.locationInWindow, from: nil)
            if [node.closeRect, node.zoomRect, node.menuRect].contains(where: { $0.contains(local) }) { return false }
        }
        toggleWire(top, in: id)
        return true
    }

    func endWiring() {
        model.wiring = nil
        if let wiringMonitor { NSEvent.removeMonitor(wiringMonitor) }
        wiringMonitor = nil
    }

    /// Closed tiles and ungrouped groups come unwired.
    func pruneTeams() {
        let ids = Set(model.surfaces.map(\.id))
        let groups = Set(model.groups.map(\.id))
        let teams = model.teams.map { team -> BoardTeam in
            var team = team
            team.members.removeAll { !ids.contains($0.tile) }
            team.groups.removeAll { key in BoardTeams.groupID(key).map { !groups.contains($0) } ?? false }
            return team
        }
        if teams != model.teams { model.teams = teams }
    }

    // MARK: Starting agents

    /// A new agent tile beside the orchestrator, wired to it, without taking the keyboard.
    /// No agent: a plain terminal.
    @discardableResult
    func spawnAgent(_ agent: BoardAgent?, role: String?, task: String?, folder: String?, for id: UUID) -> Ghostty.SurfaceView? {
        var config = Ghostty.SurfaceConfiguration()
        let wired = orchestrator(id).map(wiredAgents) ?? []
        config.workingDirectory = folder ?? wired.lazy.compactMap { self.folder(of: $0.surface) }.first ?? workspace.folder
        var command = agent.map { $0.binary + "\n" }
        if let agent, let task, !task.isEmpty {
            let prompt = Self.memberIntro(role: role, orchestrator: orchestratorName(id)) + "\n\nYour task: " + task
            if agent.kind == .claude || agent.kind == .codex,
               // Unique: one reply can spawn several agents in the same second.
               let file = AgentTools.writePrompt(prompt, folder: "board-prompts",
                                                 name: "\(AgentTools.timestamp())-\(UUID().uuidString.prefix(6))-member.md") {
                command = AgentTools.agentCommand(agent.kind, promptFile: file)
            } else {
                command = agent.command(prompt: prompt)
            }
        }
        let anchor = model.frames[id]
        guard let tile = addTile(config: config, command: command, frame: freeSpot(size: Self.tileSize, near: anchor), focus: false) else {
            return nil
        }
        // Started again plainly after a relaunch (Claude Code and Codex resume instead).
        if let agent { setCommand(agent.binary + "\n", for: tile.id) }
        wire([tile.id], to: id, role: role)
        return tile
    }

    /// Starts an orchestrator with its agents as one block, the card above them, and gives it
    /// the goal as its first command.
    func launchOrchestrator(members: [(agent: BoardAgent?, role: String)], folder: String?, goal: String?) {
        guard let app = ghostty.app else { return }
        undoManager?.beginUndoGrouping()
        if let folder { setFolder(folder) }
        let start = folder ?? workspace.folder
        let size = members.count > 3 ? CGSize(width: 640, height: 400) : Self.tileSize
        let columns = max(1, min(members.count, 4))
        let rows = Int(ceil(Double(members.count) / Double(columns)))
        let card = BoardCard.Kind.orchestrator.size
        let width = max(card.width, CGFloat(columns) * size.width + CGFloat(columns - 1) * Self.gap)
        let block = CGSize(width: width, height: card.height + Self.gap * 4 + CGFloat(rows) * (size.height + Self.gap))
        let existing = model.surfaces.compactMap { model.frames[$0.id] }
        let area = freeSpot(size: block, near: existing.first.map { first in existing.dropFirst().reduce(first) { $0.union($1) } })
        var views: [Ghostty.SurfaceView] = []
        var wired: [(tile: UUID, role: String)] = []
        for (index, member) in members.enumerated() {
            let col = index % columns, row = index / columns
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = start
            config.initialInput = member.agent.map { $0.binary + "\n" }
            let accounts = applyAccounts(&config)
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            if !accounts.isEmpty { model.tileAccounts[view.id] = accounts }
            model.frames[view.id] = CGRect(x: area.minX + CGFloat(col) * (size.width + Self.gap),
                                           y: area.minY + card.height + Self.gap * 4 + CGFloat(row) * (size.height + Self.gap),
                                           width: size.width, height: size.height)
            if let agent = member.agent { setCommand(agent.binary + "\n", for: view.id) }
            views.append(view)
            wired.append((view.id, member.role))
        }
        if !views.isEmpty { insert(views, undoAction: "New Orchestrator", focus: false) }
        let id = newOrchestrator(at: CGPoint(x: area.midX, y: area.minY + card.height / 2), goal: goal)
        changeTeam(id, action: "New Orchestrator") { team in
            team.members = wired.map { BoardTeam.Member(tile: $0.tile, role: $0.role) }
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("New Orchestrator")
        zoom(toFit: area.insetBy(dx: -40, dy: -40), animated: true)
        // The agents need a moment to start before they can take work.
        if let goal, !goal.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.orchestrator(id) != nil else { return }
                self.orchestratorBrain(id).command(goal)
            }
        }
    }

    // MARK: Talking to agents

    /// What an agent the orchestrator starts is told first.
    static func memberIntro(role: String?, orchestrator: String) -> String {
        "You're " + (role.map { "the \($0)" } ?? "an agent") + " working for \(orchestrator), which coordinates several coding "
            + "agents on the user's Tellurion board. It sees your final answer each turn, so end each turn with a short "
            + "summary of what you did and anything you need."
    }

    /// Typed to an agent once it's ready (Claude Code and Codex), or straight into a terminal.
    /// The camera stays where it is: an orchestrator or group message goes to many tiles.
    func deliverToAgent(_ text: String, to surface: Ghostty.SurfaceView, label: String) {
        let kind = VerticalTabsAgents.shared.info(for: surface)?.kind
        if kind == .claude || kind == .codex {
            AgentInbox.shared.deliver(text, to: surface, label: label)
        } else {
            deliver(text, to: surface, show: false)
        }
    }

    /// The brain behind an orchestrator card (made on first use, kept while the board is open).
    func orchestratorBrain(_ id: UUID) -> OrchestratorBrain {
        if let brain = orchestratorBrains[id] { return brain }
        let brain = OrchestratorBrain(controller: self, id: id)
        orchestratorBrains[id] = brain
        return brain
    }

    /// An agent's status changed: its orchestrators hear about it when a turn ends or it
    /// needs someone.
    func teamMemberChanged(_ surface: Ghostty.SurfaceView) {
        let info = VerticalTabsAgents.shared.info(for: surface)
        let before = teamRelay.last[surface.id]
        teamRelay.last[surface.id] = info?.activity
        guard let info, info.activity != before else { return }
        let finished = before == .working || before == .needsPermission
        switch info.activity {
        case .done where finished, .ready where finished: break
        case .needsInput, .needsPermission, .failed: break
        default: return
        }
        for team in orchestrators(of: surface.id) {
            teamRelay.pending[team.id, default: []].append((surface.id, info.activity, info.detail))
            scheduleTeamUpdate(team.id)
        }
    }

    private func scheduleTeamUpdate(_ id: UUID) {
        teamRelay.flush[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendTeamUpdate(id) }
        teamRelay.flush[id] = work
        // A few seconds, so agents finishing together arrive as one update, and their
        // transcripts are written.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func sendTeamUpdate(_ id: UUID) {
        let events = teamRelay.pending.removeValue(forKey: id) ?? []
        teamRelay.flush[id] = nil
        guard let team = orchestrator(id), !events.isEmpty else { return }
        let wired = wiredAgents(team)
        var updates: [OrchestratorBrain.Update] = []
        // The latest event per agent.
        var seen = Set<UUID>()
        for event in events.reversed() where seen.insert(event.tile).inserted {
            guard let agent = wired.first(where: { $0.surface.id == event.tile }) else { continue }
            let answer = event.activity == .needsPermission || event.activity == .failed ? nil : lastAnswer(agent.surface)
            updates.append(OrchestratorBrain.Update(tile: event.tile, name: tileLabel(agent.surface), activity: event.activity,
                                                    detail: event.detail, answer: answer))
        }
        guard !updates.isEmpty else { return }
        orchestratorBrain(id).agentsChanged(updates.reversed())
    }

    /// The agent's last answer, from the transcript it reported. Never guessed from its
    /// folder: that could be another session there (yours, or another agent's).
    /// Read again only when the transcript has changed.
    func lastAnswer(_ surface: Ghostty.SurfaceView) -> String? {
        guard let transcript = VerticalTabsAgents.shared.info(for: surface)?.transcriptPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: transcript) else { return nil }
        let stamp = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attributes[.size] as? Int ?? 0)"
        if let cached = Self.answers[transcript], cached.stamp == stamp { return cached.answer }
        let answer = AgentTools.lastAssistantMessage(transcript: transcript)?.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.answers[transcript] = (stamp, answer)
        return answer
    }

    private static var answers: [String: (stamp: String, answer: String?)] = [:]
}
#endif
