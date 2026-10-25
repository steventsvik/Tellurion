#if os(macOS)
import AppKit
import Combine

/// An orchestrator's brain: your Claude Code (or Codex) run headless, like the board's agent.
/// Each turn it gets your command and the wired agents (status, role, last answer) and
/// answers with what to send whom, and which agents to start. After a command it keeps
/// going by itself: when wired agents finish, it reads their answers and hands out the next
/// steps, until it says the goal is done, reaches its turn limit, or you stop it. It never
/// answers permission prompts; those stay with you.
final class OrchestratorBrain: ObservableObject {
    typealias Engine = HeadlessAgent.Engine

    struct Entry: Identifiable, Equatable {
        enum Kind { case user, say, action, event, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// What happened to a wired agent since the last turn.
    struct Update {
        let tile: UUID
        let name: String
        let activity: VerticalTabAgentActivity
        let detail: String?
        let answer: String?
    }

    @Published private(set) var log: [Entry] = []
    @Published private(set) var busy = false
    /// Following up on its own after a command.
    @Published private(set) var running = false
    @Published private(set) var turn = 0
    @Published private(set) var engines: [Engine]?
    /// The agent CLIs on this Mac, for starting new agents.
    @Published private(set) var installed: [BoardAgent] = []
    @Published var engine: Engine? {
        didSet {
            guard oldValue != engine else { return }
            if let engine { UserDefaults.standard.set(engine.rawValue, forKey: BoardAssistant.engineKey) }
            session = nil
        }
    }

    weak var controller: BoardController?
    let id: UUID
    private var session: String?
    private var run: HeadlessAgent.Run?
    /// The command it's working on.
    private var goal: String?
    /// Updates that came while it was thinking: the next turn carries them.
    private var waiting: [Update] = []
    /// Checks for agents that haven't taken their message (see `watch`).
    private var watchdog: DispatchWorkItem?
    /// Agents already pointed out as stuck, so each is mentioned once.
    private var flagged: Set<UUID> = []
    /// Counts turns started, so a lookup that finishes after a stop is dropped.
    private var pass = 0
    /// Wired tiles found running an agent that hasn't reported a status (see BoardPause.agents).
    private(set) var detected: Set<UUID> = []
    /// Tests: replies to use instead of running the engine, in order.
    var canned: [OrchestratorReply] = []

    init(controller: BoardController, id: UUID) {
        self.controller = controller
        self.id = id
    }

    var limit: Int { controller?.orchestrator(id)?.turns ?? BoardTeams.turns }

    func lookUp() {
        guard engines == nil else { return }
        HeadlessAgent.lookUp { [weak self] found, agents in
            guard let self else { return }
            self.installed = agents
            self.engines = found
            let saved = UserDefaults.standard.string(forKey: BoardAssistant.engineKey).flatMap(Engine.init(rawValue:))
            self.engine = saved.flatMap { found.contains($0) ? $0 : nil } ?? found.first
        }
    }

    // MARK: Commands

    /// Your command: to the agents you @mentioned as it is, or to the brain.
    func command(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let controller, !text.isEmpty else { return }
        let (mentioned, rest) = controller.mentions(in: text)
        if !mentioned.isEmpty {
            guard !rest.isEmpty else { return }
            for surface in mentioned { controller.deliverToAgent(rest, to: surface, label: "From you") }
            add(.user, text)
            add(.action, "Sent to " + ListFormatter.localizedString(byJoining: mentioned.map { controller.tileLabel($0) }))
            return
        }
        stop(quietly: true)
        add(.user, text)
        goal = text
        if controller.orchestrator(id)?.goal != text {
            controller.model.teams = controller.model.teams.map { team in
                var team = team
                if team.id == id { team.goal = text }
                return team
            }
            controller.scheduleSave()
        }
        turn = 0
        running = true
        flagged = []
        think(command: text, updates: [])
    }

    func stop(quietly: Bool = false) {
        run?.stop()
        run = nil
        pass += 1
        busy = false
        waiting = []
        watchdog?.cancel()
        watchdog = nil
        if running, !quietly { add(.event, "Stopped. Send a command to carry on.") }
        running = false
    }

    func clear() {
        stop(quietly: true)
        session = nil
        log = []
        turn = 0
    }

    /// Wired agents finished, asked something or need permission.
    func agentsChanged(_ updates: [Update]) {
        for update in updates { add(.event, Self.describe(update)) }
        guard running else { return }
        if busy {
            waiting += updates
            return
        }
        followUp(updates)
    }

    /// The next turn, with what the agents did, unless something says to hold.
    private func followUp(_ updates: [Update]) {
        // Only finished turns and questions are worth a turn; a permission prompt waits for you.
        guard updates.contains(where: { $0.activity != .needsPermission }) else { return }
        guard turn < limit else {
            running = false
            add(.event, "Stopped after \(limit) turns. Send a command to carry on.")
            return
        }
        if let controller, let team = controller.orchestrator(id),
           controller.wiredAgents(team).contains(where: { controller.model.paused.contains($0.surface.id) }) {
            running = false
            add(.event, "Paused agents: waiting. Send a command to carry on.")
            return
        }
        think(command: nil, updates: updates)
    }

    private static func describe(_ update: Update) -> String {
        switch update.activity {
        case .needsPermission: return "\(update.name) is waiting for your permission"
        case .needsInput: return "\(update.name) asks something"
        case .failed: return "\(update.name) stopped with an error"
        default: return "\(update.name) finished"
        }
    }

    // MARK: Thinking

    private func think(command: String?, updates: [Update]) {
        guard let controller else { return }
        guard let team = controller.ensureTeam(id) else {
            add(.error, "This orchestrator card is gone from the board.")
            running = false
            return
        }
        let engine = self.engine, tool = engine.flatMap { ToolPath.find($0.rawValue) }
        guard canned.isEmpty == false || tool != nil else {
            add(.error, engines == nil ? "Still looking for Claude Code and Codex. Try again in a moment."
                : "The orchestrator needs Claude Code or Codex. Install one, then try again.")
            running = false
            return
        }
        turn += 1
        busy = true
        pass += 1
        let pass = self.pass
        // Agents started by hand haven't always said anything yet: look for them by process.
        let unknown = Set(controller.wiredAgents(team).filter { VerticalTabsAgents.shared.info(for: $0.surface) == nil }.map(\.surface.id))
        guard unknown.isEmpty else {
            BoardPause.queue.async { [weak self] in
                let found = BoardPause.agents(in: unknown)
                DispatchQueue.main.async {
                    guard self?.pass == pass else { return }
                    self?.proceed(command: command, updates: updates, detected: found)
                }
            }
            return
        }
        proceed(command: command, updates: updates, detected: [:])
    }

    private func proceed(command: String?, updates: [Update], detected: [UUID: String]) {
        guard let controller, let team = controller.ensureTeam(id), busy else { return }
        self.detected = Set(detected.keys)
        let engine = self.engine, tool = engine.flatMap { ToolPath.find($0.rawValue) }
        let context = controller.orchestratorContext(team, agents: installed, detected: detected)
        var body = "Turn \(turn) of at most \(limit).\n\nThe agents now:\n\(context.text)"
        if let goal { body += "\n\nThe user's command: \(goal)" }
        if let command, command != goal { body += "\n\nNew from the user: \(command)" }
        if !updates.isEmpty {
            body += "\n\nSince your last turn:\n" + updates.map { update in
                var line = "- \(context.handle(update.tile) ?? "?") \(update.name): \(Self.describe(update).dropFirst(update.name.count + 1))"
                if let detail = update.detail, update.activity == .needsPermission { line += " (\(detail))" }
                if let answer = update.answer {
                    line += ". Its answer:\n" + BoardTeams.clip(answer, 2500)
                } else if update.activity == .done || update.activity == .ready || update.activity == .needsInput {
                    line += " (its answer couldn't be read; ask it if you need it)"
                }
                return line
            }.joined(separator: "\n")
        }
        DemoDirector.note("orchestrator turn \(turn): \(body.replacingOccurrences(of: "\n", with: " / "))")
        if !canned.isEmpty {
            let reply = canned.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.busy = false
                self?.apply(reply, handles: context.handles)
            }
            return
        }
        guard let engine, let tool else {
            busy = false
            running = false
            add(.error, "Claude Code or Codex isn't available any more.")
            return
        }
        let prompt = HeadlessAgent.prompt(engine, instructions: OrchestratorPrompt.instructions, session: session, body: body)
        let arguments = HeadlessAgent.arguments(engine, instructions: OrchestratorPrompt.instructions,
                                                schema: OrchestratorPrompt.schema, session: session)
        let run = HeadlessAgent.Run()
        self.run = run
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HeadlessAgent.run(run, tool: tool, arguments: arguments, input: prompt)
            DispatchQueue.main.async {
                guard let self, self.run === run else { return }
                self.run = nil
                self.busy = false
                let parsed = HeadlessAgent.parse(result, engine: engine)
                if let session = parsed.session { self.session = session }
                guard let reply = parsed.json.flatMap({ try? JSONDecoder().decode(OrchestratorReply.self, from: $0) }) else {
                    self.add(.error, parsed.error ?? "No answer from \(engine.title).")
                    self.running = false
                    return
                }
                self.apply(reply, handles: context.handles)
            }
        }
    }

    /// Does what the reply says (tests feed replies here directly).
    func apply(_ reply: OrchestratorReply, handles: [String: UUID]) {
        guard let controller else { return }
        let say = reply.say.trimmingCharacters(in: .whitespacesAndNewlines)
        if !say.isEmpty { add(.say, say) }
        var dispatched = false
        // Its own step to undo: replies come between events, so nothing else would close it.
        let undo = controller.undoManager
        let own = undo?.groupingLevel == 0
        if own { undo?.beginUndoGrouping() }
        for action in reply.actions {
            guard let line = controller.performOrchestration(action, for: id, handles: handles, detected: detected) else { continue }
            add(.action, line)
            if action.type != "wait" { dispatched = true }
        }
        if own {
            undo?.endUndoGrouping()
            undo?.setActionName(controller.orchestratorName(id))
        }
        if reply.done == true {
            running = false
            return
        }
        watch()
        let pending = waiting
        waiting = []
        guard running, let team = controller.orchestrator(id) else { return }
        // Nothing sent and nobody working: there's nothing to wait for.
        let working = controller.wiredAgents(team).contains { VerticalTabsAgents.shared.info(for: $0.surface)?.activity == .working }
        if !dispatched && !working && pending.isEmpty {
            running = false
            return
        }
        if !pending.isEmpty { followUp(pending) }
    }

    /// While it waits on its agents: an agent whose message hasn't gone in after a while has
    /// something else on screen (a trust or sign-in prompt, a menu): say so, once.
    private func watch() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.busy, let controller = self.controller,
                  let team = controller.orchestrator(self.id) else { return }
            for agent in controller.wiredAgents(team) where !self.flagged.contains(agent.surface.id) {
                let stuck = AgentInbox.shared.waiting(for: agent.surface).contains { Date().timeIntervalSince($0.created) > 40 }
                guard stuck, AgentInbox.readiness(of: agent.surface) != .working else { continue }
                self.flagged.insert(agent.surface.id)
                self.add(.error, "\(controller.tileLabel(agent.surface)) hasn't taken its message: something is waiting in its "
                         + "terminal (a prompt or sign-in). Answer it there and the message goes in.")
            }
            self.watch()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func add(_ kind: Entry.Kind, _ text: String) {
        log.append(Entry(kind: kind, text: text))
        if log.count > 80 { log.removeFirst(log.count - 80) }
        DemoDirector.note("orchestrator[\(controller?.orchestratorName(id) ?? "")] \(kind): \(text.replacingOccurrences(of: "\n", with: " / "))")
    }
}

/// What the brain answers: a few words for you, what to do, and whether the goal is met.
struct OrchestratorReply: Codable {
    var say: String
    var actions: [OrchestratorAction]
    var done: Bool?
}

struct OrchestratorAction: Codable, Equatable {
    var type: String
    var agent: String?
    var text: String?
    var role: String?
    var task: String?
    var folder: String?
}

enum OrchestratorPrompt {
    static let instructions = """
    You are an orchestrator on the user's Tellurion board, a canvas of terminals in a macOS \
    app. Several coding agents (Claude Code, Codex and others, each in its own terminal) are \
    wired to you. The user gives you a command; you split it into tasks, hand them to the \
    agents, read what they answer when they finish, and hand out the next steps until the \
    command is done. You can't run commands or read files yourself; you act only through \
    the actions below, and the board carries them out.

    Each message lists the wired agents with handles (A1, A2…), their role, status, folder \
    and their last answer. Use only handles from the latest message. Agents can't see each \
    other or this conversation, so give each one everything it needs: what to do, where, \
    and what to report back. Keep agents busy in parallel when the work allows it; don't \
    give two agents the same files at once. A "terminal" with no agent running can't take \
    messages: start an agent in it, or spawn one.

    Reply with JSON only: {"say": "...", "actions": [...], "done": false}. "say" is one or \
    two short, plain sentences for the user: what you just did or found. Set "done" to true \
    only when the user's command is complete (or can't be done), and say so in "say".

    Actions:
    - send {agent, text}: give one agent work, or answer its question. agent is a handle or \
    a role.
    - broadcast {text}: the same message to every wired agent.
    - spawn {agent, role, task?, folder?}: start a new agent (claude, codex, or another \
    installed one listed; "shell" for a plain terminal), wired to you. task is its first \
    message. Start agents only when the wired ones aren't enough (at most 24 in all).
    - wait {}: nothing to do until agents finish.

    When an agent is waiting for the user's permission, tell the user in "say"; you can't \
    approve it. When nothing is wired and the command needs agents, spawn them.
    """

    /// For Claude Code's structured output.
    static let schema: String = {
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["send", "broadcast", "spawn", "wait"]],
                "agent": ["type": "string"], "text": ["type": "string"], "role": ["type": "string"],
                "task": ["type": "string"], "folder": ["type": "string"],
            ],
            "required": ["type"],
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["say": ["type": "string"], "actions": ["type": "array", "items": action], "done": ["type": "boolean"]],
            "required": ["say", "actions", "done"],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }()
}

/// The wired agents in words, with a handle for each.
struct OrchestratorContext {
    var text: String
    var handles: [String: UUID]

    func handle(_ tile: UUID) -> String? { handles.first { $0.value == tile }?.key }
}

extension BoardController {
    /// `detected`: agents found running by process in tiles that haven't reported any status.
    func orchestratorContext(_ team: BoardTeam, agents installed: [BoardAgent], detected: [UUID: String] = [:]) -> OrchestratorContext {
        var handles: [String: UUID] = [:]
        var lines: [String] = []
        let wired = wiredAgents(team)
        if wired.isEmpty { lines.append("No agents are wired yet.") }
        for (index, agent) in wired.enumerated() {
            let handle = "A\(index + 1)"
            handles[handle] = agent.surface.id
            var parts = ["\(handle) \"\(tileLabel(agent.surface))\""]
            if let role = agent.role { parts.append("role \(role)") }
            if let group = agent.group { parts.append("in group \(groupTitle(group))") }
            if let info = VerticalTabsAgents.shared.info(for: agent.surface) {
                parts.append("\(info.kind.displayName), \(info.activity.label.lowercased())")
                if let detail = info.detail, AgentAlerts.isWaiting(info.activity) { parts.append("waiting on: \(detail)") }
            } else if let binary = detected[agent.surface.id] {
                let name = BoardAgent.catalog.first { $0.binary == binary }?.kind.displayName ?? binary
                parts.append("\(name), running (it hasn't reported a status yet; it takes messages)")
            } else {
                parts.append("terminal (no agent)")
            }
            if model.paused.contains(agent.surface.id) { parts.append("paused by the user") }
            if let folder = folder(of: agent.surface) { parts.append("in \((folder as NSString).abbreviatingWithTildeInPath)") }
            lines.append("- " + parts.joined(separator: "; "))
            if let answer = lastAnswer(agent.surface), VerticalTabsAgents.shared.info(for: agent.surface)?.activity != .working {
                lines.append("  Last answer: " + BoardTeams.clip(answer.replacingOccurrences(of: "\n", with: " "), 600))
            }
        }
        lines.append("Installed agents: " + (installed.isEmpty ? "none found" : installed.map(\.binary).joined(separator: ", ")) + ".")
        return OrchestratorContext(text: lines.joined(separator: "\n"), handles: handles)
    }

    /// One action from an orchestrator's brain; what was done, in words.
    /// `detected`: tiles running an agent that hasn't reported a status, which take messages
    /// typed in directly.
    func performOrchestration(_ action: OrchestratorAction, for id: UUID, handles: [String: UUID],
                              detected: Set<UUID> = []) -> String? {
        guard let team = orchestrator(id) else { return nil }
        let wired = wiredAgents(team)
        let from = orchestratorName(id)
        func target(_ name: String?) -> BoardTeamAgent? {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            if let tile = handles[name.uppercased()] { return wired.first { $0.surface.id == tile } }
            let lower = name.lowercased()
            return wired.first { $0.role?.lowercased() == lower }
                ?? wired.first { tileLabel($0.surface).lowercased() == lower }
                ?? wired.first { $0.role?.lowercased().hasPrefix(lower) == true }
        }
        /// Only to agents: text typed into a plain shell would run as a command.
        func send(_ text: String, to agent: BoardTeamAgent) -> Bool {
            if VerticalTabsAgents.shared.info(for: agent.surface) == nil {
                guard detected.contains(agent.surface.id) else { return false }
                // An agent's input box takes one line (a newline would send it early).
                let line = text.replacingOccurrences(of: "\n", with: " ")
                deliver("From \(from)" + (agent.role.map { ", to you as the \($0)" } ?? "") + ": " + line, to: agent.surface)
            } else {
                deliverToAgent("From \(from)" + (agent.role.map { ", to you as the \($0)" } ?? "") + ":\n\n" + text,
                               to: agent.surface, label: "From \(from)")
            }
            return true
        }
        switch action.type {
        case "send":
            guard let agent = target(action.agent), let text = action.text, !text.isEmpty else { return nil }
            guard send(text, to: agent) else { return "\(tileLabel(agent.surface)) has no agent running; not sent" }
            return "Sent \(tileLabel(agent.surface)): " + BoardTeams.clip(text.replacingOccurrences(of: "\n", with: " "), 120)
        case "broadcast":
            guard let text = action.text, !text.isEmpty, !wired.isEmpty else { return nil }
            let skipped = wired.filter { !send(text, to: $0) }.map { tileLabel($0.surface) }
            if skipped.count == wired.count { return "Not sent: no agent running in \(skipped.joined(separator: ", "))" }
            if !skipped.isEmpty { return "Sent everyone with an agent (not \(skipped.joined(separator: ", "))): " + BoardTeams.clip(text.replacingOccurrences(of: "\n", with: " "), 100) }
            return "Sent everyone: " + BoardTeams.clip(text.replacingOccurrences(of: "\n", with: " "), 120)
        case "spawn":
            guard wired.count < BoardTeams.maxAgents else { return "Can't start more than \(BoardTeams.maxAgents) agents" }
            let name = (action.agent ?? "claude").lowercased()
            let agent = BoardAgent.catalog.first { $0.binary == name || $0.kind.rawValue == name }
            guard agent != nil || name == "shell" else { return "Unknown agent \(name)" }
            let folder = action.folder.map { ($0 as NSString).expandingTildeInPath }
            if let folder, !FileManager.default.fileExists(atPath: folder) { return "No folder \(action.folder ?? "")" }
            let role = action.role?.isEmpty == false ? action.role : nil
            guard spawnAgent(agent, role: role, task: action.task, folder: folder, for: id) != nil else { return nil }
            return "Started " + (agent?.kind.displayName ?? "a terminal") + (role.map { " · \($0)" } ?? "")
        case "wait":
            return nil
        default:
            return nil
        }
    }
}
#endif
