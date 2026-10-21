#if os(macOS)
import AppKit

/// A team on a board: a lead agent (an ordinary agent tile) and the member tiles it runs.
/// The lead manages them with the `team` command (agent-hooks/team), and hears from
/// Tellurion whenever a member finishes a turn or needs something.
struct BoardTeam: Codable, Identifiable, Equatable {
    struct Member: Codable, Equatable {
        var tile: UUID
        var role: String
    }

    let id: UUID
    var name: String
    /// The lead's tile.
    var lead: UUID
    var members: [Member] = []
    var goal: String?
    /// An index into BoardProjects.palette.
    var color = 0
}

/// A line from a lead to a member, for BoardGroupsView.
struct BoardTeamLink: Equatable {
    let from: CGRect
    let to: CGRect
    let color: Int
    let label: String
}

/// `team` requests: the command writes ~/.ghostty-extreme/teams/<id>.json and sends a signed
/// `ghostty-extreme://team` notification with the id from the lead's terminal; the answer goes
/// in <id>.reply (OK or ERR, then the text).
enum BoardTeams {
    static let eventTitle = "ghostty-extreme://team"
    static var folder: URL { AgentTools.root.appendingPathComponent("teams", isDirectory: true) }
    static let roles = ["Coder", "Reviewer", "Tester", "Researcher", "Designer", "Writer"]

    struct Request: Decodable {
        let id: String
        let command: String
        let member: String?
        let text: String?
        let agent: String?
        let role: String?
    }

    /// From VerticalTabsAgents, once the token checked out.
    static func handle(body: String, from surface: Ghostty.SurfaceView) {
        struct Ping: Decodable { let id: String }
        guard let data = body.data(using: .utf8), let ping = try? JSONDecoder().decode(Ping.self, from: data),
              ping.id.hasPrefix("tm-"), ping.id.count <= 48,
              ping.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return }
        let file = folder.appendingPathComponent(ping.id + ".json")
        let request = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Request.self, from: $0) }
        try? FileManager.default.removeItem(at: file)
        let answer: (ok: Bool, text: String)
        if let request, request.id == ping.id {
            if let board = BoardController.all.first(where: { $0.surfaceTree.contains(surface) }) {
                answer = board.teamRequest(request, from: surface)
            } else {
                answer = (false, "Teams work on a board. This terminal isn't on one.")
            }
        } else {
            answer = (false, "The request couldn't be read.")
        }
        let reply = (answer.ok ? "OK" : "ERR") + "\n" + answer.text + (answer.text.hasSuffix("\n") ? "" : "\n")
        try? Data(reply.utf8).write(to: folder.appendingPathComponent(ping.id + ".reply"), options: .atomic)
    }

    static func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}

/// What a team's lead has yet to hear, sent together a moment after the last of it.
final class BoardTeamRelay {
    /// Each tile's agent status when last seen.
    var last: [UUID: VerticalTabAgentActivity] = [:]
    /// Per team: the members to report on, and what happened.
    var pending: [UUID: [(tile: UUID, activity: VerticalTabAgentActivity, detail: String?)]] = [:]
    var flush: [UUID: DispatchWorkItem] = [:]
    /// Membership changes to tell the lead about, per team, with whether the tile should still
    /// be a member when they're sent (so a change you undid isn't reported).
    var changes: [UUID: [(tile: UUID, member: Bool?, text: String)]] = [:]
}

extension BoardController {
    // MARK: Looking up

    func team(ledBy tile: UUID) -> BoardTeam? { model.teams.first { $0.lead == tile } }

    /// The team a tile leads or is in.
    func team(of tile: UUID) -> BoardTeam? {
        model.teams.first { $0.lead == tile || $0.members.contains { $0.tile == tile } }
    }

    func role(of tile: UUID) -> String? {
        model.teams.lazy.compactMap { $0.members.first { $0.tile == tile }?.role }.first
    }

    private func surface(_ id: UUID) -> Ghostty.SurfaceView? { model.surfaces.first { $0.id == id } }

    /// The lines from leads to members, edge to edge.
    func teamLinks() -> [BoardTeamLink] {
        model.teams.flatMap { team -> [BoardTeamLink] in
            guard let lead = model.frames[team.lead] else { return [] }
            return team.members.compactMap { member in
                model.frames[member.tile].map { BoardTeamLink(from: lead, to: $0, color: team.color, label: member.role) }
            }
        }
    }

    // MARK: Changing

    /// Replaces the teams; ⌘Z puts the old ones back.
    private func setTeams(_ teams: [BoardTeam], action: String) {
        let old = model.teams
        guard old != teams else { return }
        model.teams = teams
        undoManager?.registerUndo(withTarget: self) { $0.setTeams(old, action: action) }
        undoManager?.setActionName(action)
        scheduleSave()
    }

    /// A new team led by `lead`. Tiles already in a team leave it first.
    @discardableResult
    func createTeam(lead: UUID, members: [(tile: UUID, role: String)], goal: String?, brief: Bool) -> UUID? {
        guard surface(lead) != nil else { return nil }
        var teams = model.teams
        let ids = Set([lead] + members.map(\.tile))
        // A lead that joins another team stops leading its own.
        teams.removeAll { ids.contains($0.lead) }
        for index in teams.indices { teams[index].members.removeAll { ids.contains($0.tile) } }
        let used = Set(teams.map(\.color))
        let name = BoardStore.uniqueName("Team", taken: Set(teams.map(\.name)))
        let team = BoardTeam(id: UUID(), name: name, lead: lead,
                             members: members.filter { $0.tile != lead }.map { BoardTeam.Member(tile: $0.tile, role: $0.role) },
                             goal: goal?.isEmpty == true ? nil : goal,
                             // Away from the first project colors, and not another team's.
                             color: (0..<BoardProjects.palette.count).map { ($0 + 6) % BoardProjects.palette.count }
                                .first { !used.contains($0) } ?? 0)
        teams.append(team)
        setTeams(teams, action: "New Team")
        if brief { sendBrief(team.id) }
        for member in team.members { introduce(member, in: team) }
        return team.id
    }

    /// Adds a tile to a team (leaving any other); the lead hears about it.
    func addToTeam(_ teamID: UUID, tile: UUID, role: String, notify: Bool = true) {
        guard var team = model.teams.first(where: { $0.id == teamID }), tile != team.lead, surface(tile) != nil else { return }
        var teams = model.teams
        teams.removeAll { $0.lead == tile }
        for index in teams.indices { teams[index].members.removeAll { $0.tile == tile } }
        team = teams.first { $0.id == teamID } ?? team
        let member = BoardTeam.Member(tile: tile, role: role.isEmpty ? "Member" : role)
        team.members.append(member)
        if let index = teams.firstIndex(where: { $0.id == teamID }) { teams[index] = team }
        setTeams(teams, action: "Add to Team")
        guard notify else { return }
        introduce(member, in: team)
        let agent = surface(tile).flatMap { VerticalTabsAgents.shared.info(for: $0)?.kind.displayName } ?? "a terminal"
        tellLead(team.id, tile: tile, member: true, "\(member.role) (\(agent)) joined the team.")
    }

    func removeFromTeam(tile: UUID) {
        guard let team = model.teams.first(where: { $0.members.contains { $0.tile == tile } }),
              let member = team.members.first(where: { $0.tile == tile }) else { return }
        var teams = model.teams
        if let index = teams.firstIndex(where: { $0.id == team.id }) { teams[index].members.removeAll { $0.tile == tile } }
        setTeams(teams, action: "Remove from Team")
        tellLead(team.id, tile: tile, member: false, "\(member.role) left the team.")
    }

    func disbandTeam(_ id: UUID) {
        setTeams(model.teams.filter { $0.id != id }, action: "Disband Team")
    }

    func setRole(_ role: String, for tile: UUID) {
        let role = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty else { return }
        var teams = model.teams
        for t in teams.indices {
            for m in teams[t].members.indices where teams[t].members[m].tile == tile {
                let old = teams[t].members[m].role
                teams[t].members[m].role = role
                setTeams(teams, action: "Change Role")
                tellLead(teams[t].id, tile: tile, "\(old) is now the \(role).")
                return
            }
        }
    }

    func renameTeam(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        setTeams(model.teams.map { team in
            var team = team
            if team.id == id { team.name = name }
            return team
        }, action: "Rename Team")
    }

    /// A tile dragged onto another by its link: into the target's team, or a new team the
    /// target leads. Asks for the role.
    func connect(_ tile: UUID, to target: UUID) {
        guard tile != target, let dragged = surface(tile) else { return }
        let suggested = role(of: tile) ?? Self.suggestedRole(dragged, existing: team(of: target)?.members.map(\.role) ?? [])
        let label = tileLabel(dragged)
        promptRename("Role", info: "What does \(label) do on the team?", current: suggested, button: "Add to Team") { [weak self] role in
            guard let self else { return }
            if let team = self.team(of: target), team.lead != tile {
                self.addToTeam(team.id, tile: tile, role: role)
            } else {
                self.createTeam(lead: target, members: [(tile, role)], goal: nil, brief: true)
            }
        }
    }

    static func suggestedRole(_ surface: Ghostty.SurfaceView, existing: [String]) -> String {
        if VerticalTabsAgents.shared.info(for: surface) == nil { return "Terminal" }
        return BoardTeams.roles.first { !existing.contains($0) } ?? "Coder"
    }

    /// Closed tiles leave their teams; a team whose lead closed ends.
    func pruneTeams() {
        let ids = Set(model.surfaces.map(\.id))
        var teams = model.teams.filter { ids.contains($0.lead) }
        for index in teams.indices { teams[index].members.removeAll { !ids.contains($0.tile) } }
        if teams != model.teams { model.teams = teams }
    }

    // MARK: Starting a team

    /// Starts a lead and its members as one block, the lead above, linked and briefed.
    func launchTeam(lead: BoardAgent, members: [(agent: BoardAgent?, role: String)], folder: String?, goal: String?) {
        guard let app = ghostty.app else { return }
        if let folder { setFolder(folder) }
        let start = folder ?? workspace.folder
        let size = members.count > 3 ? CGSize(width: 640, height: 400) : Self.tileSize
        let columns = max(1, min(members.count, 4))
        let rows = Int(ceil(Double(members.count) / Double(columns)))
        let block = CGSize(width: CGFloat(columns) * size.width + CGFloat(columns - 1) * Self.gap,
                           height: Self.tileSize.height + Self.gap * 3 + CGFloat(rows) * (size.height + Self.gap))
        let existing = model.surfaces.compactMap { model.frames[$0.id] }
        let area = freeSpot(size: block, near: existing.first.map { first in existing.dropFirst().reduce(first) { $0.union($1) } })
        // The lead starts on its brief, which already lists the members.
        let planned = BoardTeam(id: UUID(), name: BoardStore.uniqueName("Team", taken: Set(model.teams.map(\.name))), lead: UUID(),
                                members: members.map { BoardTeam.Member(tile: UUID(), role: $0.role) }, goal: goal)
        let brief = teamBrief(planned, agents: members.map { $0.agent?.kind.displayName })
        var leadCommand = lead.command(prompt: brief)
        if lead.kind == .claude || lead.kind == .codex,
           let file = AgentTools.writePrompt(brief, folder: "board-prompts", name: "\(AgentTools.timestamp())-team.md") {
            leadCommand = AgentTools.agentCommand(lead.kind, promptFile: file)
        }
        var views: [Ghostty.SurfaceView] = []
        func tile(_ command: String?, frame: CGRect) -> Ghostty.SurfaceView {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = start
            config.initialInput = command
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            model.frames[view.id] = frame
            views.append(view)
            return view
        }
        let leadView = tile(leadCommand, frame: CGRect(x: area.midX - Self.tileSize.width / 2, y: area.minY,
                                                width: Self.tileSize.width, height: Self.tileSize.height))
        var linked: [(tile: UUID, role: String)] = []
        for (index, member) in members.enumerated() {
            let col = index % columns, row = index / columns
            let frame = CGRect(x: area.minX + CGFloat(col) * (size.width + Self.gap),
                               y: area.minY + Self.tileSize.height + Self.gap * 3 + CGFloat(row) * (size.height + Self.gap),
                               width: size.width, height: size.height)
            let view = tile(member.agent.map { $0.binary + "\n" }, frame: frame)
            linked.append((view.id, member.role))
        }
        for view in views {
            // Started again plainly after a relaunch (Claude Code and Codex resume instead).
            if let line = view === leadView ? lead.binary + "\n" : linkedAgent(view, members, linked) { setCommand(line, for: view.id) }
        }
        insert(views, undoAction: "New Team")
        createTeam(lead: leadView.id, members: linked, goal: goal, brief: false)
        zoom(toFit: area.insetBy(dx: -40, dy: -40), animated: true)
    }

    private func linkedAgent(_ view: Ghostty.SurfaceView, _ members: [(agent: BoardAgent?, role: String)],
                             _ linked: [(tile: UUID, role: String)]) -> String? {
        guard let index = linked.firstIndex(where: { $0.tile == view.id }) else { return nil }
        return members[index].agent.map { $0.binary + "\n" }
    }

    // MARK: Talking to the lead

    /// What a lead is told when its team starts: the `team` command, the members, the goal.
    /// `agents` names the members' agents when they haven't started yet.
    func teamBrief(_ team: BoardTeam, agents: [String?]? = nil) -> String {
        let members = team.members.enumerated().map { index, member -> String in
            let agent = agents.flatMap { index < $0.count ? $0[index] : nil }
                ?? surface(member.tile).flatMap { VerticalTabsAgents.shared.info(for: $0)?.kind.displayName }
            return "  \(index + 1). \(member.role)" + (agent.map { " (\($0))" } ?? "")
        }
        return """
        You lead a team of coding agents on the user's Tellurion board ("\(team.name)"). Each member \
        is a separate agent in its own terminal. Run the team with the `team` command, using your \
        shell tool:

          ~/.ghostty-extreme/bin/team status                     who's on the team and what each is doing
          ~/.ghostty-extreme/bin/team send <member> "<message>"  give a member work, or answer it
          ~/.ghostty-extreme/bin/team broadcast "<message>"      message every member
          ~/.ghostty-extreme/bin/team result <member>            a member's last full answer
          ~/.ghostty-extreme/bin/team add <claude|codex|shell> --role "<role>" [--task "<task>"]
                                                                 start a new member
          ~/.ghostty-extreme/bin/team remove <member>            take a member off the team

        Name members by role or number. When a member finishes a turn, asks something or waits for \
        the user's permission, you'll get a "[Team]" message with what they said. Members can't see \
        each other or this conversation, so give each one everything it needs. Plan the work, split \
        it into tasks, hand them out, check the results, and keep the user posted. Do small things \
        yourself; delegate the rest.

        The team:
        \(members.isEmpty ? "  (no members yet; add some with team add)" : members.joined(separator: "\n"))

        Goal: \(team.goal ?? "Ask the user what the team should work on.")
        """
    }

    /// Sends a lead its brief (it was already running).
    func sendBrief(_ teamID: UUID) {
        guard let team = model.teams.first(where: { $0.id == teamID }), let lead = surface(team.lead) else { return }
        deliverToAgent(teamBrief(team), to: lead, label: "Team brief")
    }

    /// A short note to a member that's now on a team, if it's already running an agent.
    private func introduce(_ member: BoardTeam.Member, in team: BoardTeam) {
        guard let tile = surface(member.tile), let lead = surface(team.lead),
              VerticalTabsAgents.shared.info(for: tile) != nil else { return }
        deliverToAgent("You're now the \(member.role) on a team led by \(tileLabel(lead)) on the user's Tellurion board. "
                       + "Your lead will send you tasks. End each turn with a short summary of what you did; your lead sees it.",
                       to: tile, label: "Joined \(team.name)")
    }

    /// Queues a line for the lead, sent with whatever else arrives in the next few seconds.
    func tellLead(_ teamID: UUID, tile: UUID, member: Bool? = nil, _ line: String) {
        teamRelay.changes[teamID, default: []].append((tile, member, line))
        scheduleLeadUpdate(teamID)
    }

    /// Typed to an agent once it's ready (Claude Code and Codex), or straight into a terminal.
    private func deliverToAgent(_ text: String, to surface: Ghostty.SurfaceView, label: String) {
        let kind = VerticalTabsAgents.shared.info(for: surface)?.kind
        if kind == .claude || kind == .codex {
            AgentInbox.shared.deliver(text, to: surface, label: label)
        } else if kind != nil {
            deliver(text, to: surface)
        }
    }

    /// A member's agent changed: tell its lead when a turn ends or it needs someone.
    func teamMemberChanged(_ surface: Ghostty.SurfaceView) {
        let info = VerticalTabsAgents.shared.info(for: surface)
        let before = teamRelay.last[surface.id]
        teamRelay.last[surface.id] = info?.activity
        guard let info, info.activity != before, let team = team(of: surface.id), team.lead != surface.id else { return }
        let finished = before == .working || before == .needsPermission
        switch info.activity {
        case .done, .ready where finished: break
        case .needsInput, .needsPermission, .failed: break
        default: return
        }
        teamRelay.pending[team.id, default: []].append((surface.id, info.activity, info.detail))
        scheduleLeadUpdate(team.id)
    }

    private func scheduleLeadUpdate(_ teamID: UUID) {
        teamRelay.flush[teamID]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendLeadUpdate(teamID) }
        teamRelay.flush[teamID] = work
        // A few seconds, so members finishing together arrive as one message, and their
        // transcripts are written.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func sendLeadUpdate(_ teamID: UUID) {
        let events = teamRelay.pending.removeValue(forKey: teamID) ?? []
        let changes = teamRelay.changes.removeValue(forKey: teamID) ?? []
        teamRelay.flush[teamID] = nil
        guard let team = model.teams.first(where: { $0.id == teamID }), let lead = surface(team.lead),
              !events.isEmpty || !changes.isEmpty else { return }
        var lines = changes.filter { change in
            change.member.map { $0 == team.members.contains { $0.tile == change.tile } } ?? true
        }.map { "[Team] \($0.text)" }
        // The latest event per member.
        var seen = Set<UUID>()
        for event in events.reversed() where seen.insert(event.tile).inserted {
            guard let member = team.members.first(where: { $0.tile == event.tile }), let tile = surface(event.tile) else { continue }
            let agent = VerticalTabsAgents.shared.info(for: tile)?.kind.displayName ?? "terminal"
            let name = "\(member.role) (\(agent))"
            switch event.activity {
            case .needsPermission:
                lines.append("[Team] \(name) is waiting for the user's permission" + (event.detail.map { ": \($0)" } ?? "") + ".")
            case .failed:
                lines.append("[Team] \(name) stopped with an error.")
            default:
                let answer = lastAnswer(tile).map { BoardTeams.clip($0, 1500) } ?? "(no answer found)"
                let verb = event.activity == .needsInput ? "asks" : "finished"
                lines.append("[Team] \(name) \(verb):\n\(answer)\n(Full answer: team result \(member.role))")
            }
        }
        guard !lines.isEmpty else { return }
        let update = lines.joined(separator: "\n\n")
        DemoDirector.note("team update for \(tileLabel(lead)): \(update.replacingOccurrences(of: "\n", with: " / "))")
        deliverToAgent(update, to: lead, label: "Team update")
    }

    /// The member's last answer, from its transcript.
    private func lastAnswer(_ surface: Ghostty.SurfaceView) -> String? {
        guard let info = VerticalTabsAgents.shared.info(for: surface) else { return nil }
        let transcript = info.transcriptPath ?? AgentTranscripts.find(kind: info.kind, folder: surface.pwd ?? "", recent: 24 * 3600)
        return AgentTools.lastAssistantMessage(transcript: transcript)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The `team` command

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func teamRequest(_ request: BoardTeams.Request, from surface: Ghostty.SurfaceView) -> (ok: Bool, text: String) {
        guard let team = team(ledBy: surface.id) else {
            return (false, "This terminal isn't leading a team. Make it a lead from its tile's menu on the board.")
        }
        let leadName = tileLabel(surface)
        func member(_ name: String?) -> (member: BoardTeam.Member, surface: Ghostty.SurfaceView)? {
            guard let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
            let members = team.members.compactMap { m in self.surface(m.tile).map { (m, $0) } }
            if let n = Int(name), n >= 1, n <= team.members.count {
                return members.first { $0.0.tile == team.members[n - 1].tile }
            }
            return members.first { $0.0.role.lowercased() == name }
                ?? members.first { tileLabel($0.1).lowercased() == name }
                ?? members.first { $0.0.role.lowercased().hasPrefix(name) }
        }
        func send(_ text: String, to target: (member: BoardTeam.Member, surface: Ghostty.SurfaceView)) {
            let message = "From your team lead (\(leadName)), to you as the \(target.member.role):\n\n\(text)"
            if VerticalTabsAgents.shared.info(for: target.surface) != nil {
                deliverToAgent(message, to: target.surface, label: "From \(leadName)")
            } else {
                deliver(text, to: target.surface)
            }
        }
        switch request.command {
        case "status":
            var lines = ["\(team.name)" + (team.goal.map { ", goal: \($0)" } ?? "")]
            if team.members.isEmpty { lines.append("No members yet. Add one with: team add claude --role Coder") }
            for (index, m) in team.members.enumerated() {
                guard let tile = self.surface(m.tile) else { continue }
                var line = "\(index + 1). \(m.role): "
                if let info = VerticalTabsAgents.shared.info(for: tile) {
                    line += "\(info.kind.displayName), \(info.activity.label.lowercased())"
                    if let task = info.task { line += "; task: \(BoardTeams.clip(task.replacingOccurrences(of: "\n", with: " "), 160))" }
                    if let action = info.lastAction { line += "; last: \(action)" }
                    if let detail = info.detail, AgentAlerts.isWaiting(info.activity) { line += "; waiting on: \(detail)" }
                } else {
                    line += "terminal (no agent running)"
                }
                if model.paused.contains(m.tile) { line += "; paused by the user" }
                if let folder = folder(of: tile) { line += "; in \((folder as NSString).abbreviatingWithTildeInPath)" }
                lines.append(line)
            }
            return (true, lines.joined(separator: "\n"))
        case "send":
            guard let target = member(request.member) else { return (false, "No member \"\(request.member ?? "")\". Run: team status") }
            guard let text = request.text, !text.isEmpty else { return (false, "Nothing to send.") }
            send(text, to: target)
            return (true, "Sent to \(target.member.role). You'll hear back when it finishes.")
        case "broadcast":
            guard let text = request.text, !text.isEmpty else { return (false, "Nothing to send.") }
            let targets = team.members.compactMap { m in self.surface(m.tile).map { (member: m, surface: $0) } }
            guard !targets.isEmpty else { return (false, "The team has no members yet.") }
            for target in targets { send(text, to: target) }
            return (true, "Sent to \(targets.count) member\(targets.count == 1 ? "" : "s").")
        case "result":
            guard let target = member(request.member) else { return (false, "No member \"\(request.member ?? "")\". Run: team status") }
            guard let answer = lastAnswer(target.surface) else { return (false, "\(target.member.role) hasn't answered yet.") }
            return (true, BoardTeams.clip(answer, 20000))
        case "remove":
            guard let target = member(request.member) else { return (false, "No member \"\(request.member ?? "")\". Run: team status") }
            removeFromTeam(tile: target.member.tile)
            teamRelay.changes[team.id] = nil
            return (true, "\(target.member.role) is off the team. Its tile stays open.")
        case "add":
            let role = (request.role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty else { return (false, "Give the new member a role: --role \"Tester\"") }
            guard team.members.count < 12 else { return (false, "A team can have up to 12 members.") }
            let name = (request.agent ?? "").lowercased()
            let agent = BoardAgent.catalog.first { $0.binary == name || $0.kind.rawValue == name }
            guard agent != nil || name == "shell" else {
                return (false, "Unknown agent \"\(name)\". Try claude, codex, gemini or shell.")
            }
            let task = request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let intro = "You're the \(role) on a team led by \(leadName) on the user's Tellurion board. Your lead sees your "
                + "final answer each turn, so end each turn with a short summary of what you did."
            let prompt = task.isEmpty ? nil : intro + "\n\nYour task: " + task
            guard let tile = spawnMember(agent, prompt: prompt, near: surface) else { return (false, "The tile didn't open.") }
            addToTeam(team.id, tile: tile.id, role: role, notify: false)
            let number = (model.teams.first { $0.id == team.id }?.members.count) ?? 0
            return (true, "Started \(role) (\(agent?.kind.displayName ?? "terminal")) as member \(number)."
                    + (task.isEmpty ? " Send it a task with: team send \(number) \"…\"" : " It's working on the task."))
        default:
            return (false, "Unknown command \"\(request.command)\".")
        }
    }

    /// A new member tile beside the lead, in the lead's folder, without taking the keyboard.
    private func spawnMember(_ agent: BoardAgent?, prompt: String?, near lead: Ghostty.SurfaceView) -> Ghostty.SurfaceView? {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder(of: lead) ?? workspace.folder
        var command = agent.map { $0.binary + "\n" }
        if let agent, let prompt {
            if agent.kind == .claude || agent.kind == .codex,
               let file = AgentTools.writePrompt(prompt, folder: "board-prompts", name: "\(AgentTools.timestamp())-member.md") {
                command = AgentTools.agentCommand(agent.kind, promptFile: file)
            } else {
                command = agent.command(prompt: prompt)
            }
        }
        return addTile(config: config, command: command, near: lead,
                       frame: freeSpot(size: Self.tileSize, near: model.frames[lead.id]), focus: false)
    }
}
#endif
