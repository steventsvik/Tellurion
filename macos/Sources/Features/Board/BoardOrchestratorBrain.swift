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
        /// Pictures that went with it.
        var images = 0
    }

    /// What happened to a wired agent since the last turn.
    struct Update {
        let tile: UUID
        let name: String
        let activity: VerticalTabAgentActivity
        let detail: String?
        let answer: String?
        /// One line about its project's check, if that failed for the turn it finished.
        var failedCheck: String?
    }

    /// Why it stopped following up: you or a limit stopped it, or the work is done.
    enum Ending { case stopped, done }

    @Published private(set) var log: [Entry] = []
    @Published private(set) var busy = false
    /// Following up on its own after a command.
    @Published private(set) var running = false
    @Published private(set) var turn = 0
    /// How its last command ended; nil while it runs, and before the first one.
    @Published private(set) var ending: Ending?
    @Published private(set) var engines: [Engine]?
    /// The agent CLIs on this Mac, for starting new agents.
    @Published private(set) var installed: [BoardAgent] = []
    @Published var engine: Engine? {
        didSet {
            guard oldValue != engine else { return }
            if remembersEngine, let engine { UserDefaults.standard.set(engine.rawValue, forKey: BoardAssistant.engineKey) }
            session = nil
        }
    }

    weak var host: OrchestratorHost?
    let id: UUID
    /// Whether choosing an engine also makes it the one new orchestrators start with.
    var remembersEngine = true
    /// The engine to start with, where the host keeps its own choice.
    var preferredEngine: Engine?
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
    /// Wired panes found running an agent that hasn't reported a status (see BoardPause.agents).
    private(set) var detected: Set<UUID> = []
    /// Pictures pasted with the command, for its first turn.
    private var pictures: [ImageAttachment] = []
    /// Tests: replies to use instead of running the engine, in order.
    var canned: [OrchestratorReply] = []

    init(host: OrchestratorHost, id: UUID) {
        self.host = host
        self.id = id
    }

    var limit: Int { host?.orchestrator(id)?.turns ?? BoardTeams.turns }

    func lookUp() {
        guard engines == nil else { return }
        HeadlessAgent.lookUp { [weak self] found, agents in
            guard let self else { return }
            self.installed = agents
            self.engines = found
            let saved = self.preferredEngine ?? UserDefaults.standard.string(forKey: BoardAssistant.engineKey).flatMap(Engine.init(rawValue:))
            self.engine = saved.flatMap { found.contains($0) ? $0 : nil } ?? found.first
        }
    }

    // MARK: Commands

    /// Your command: to the agents you @mentioned as it is, or to the brain. Pictures pasted
    /// with it go to the brain in its prompt; an @mentioned agent is told where they're saved.
    func command(_ raw: String, images: [ImageAttachment] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !text.isEmpty else { return }
        let (mentioned, rest) = host.mentionedPanes(in: text, for: id)
        if !mentioned.isEmpty {
            guard let message = Self.mentionMessage(rest, files: ImageAttachment.save(images)) else {
                add(.error, "Say what to tell them, or paste a picture with the mention.")
                return
            }
            for pane in mentioned { host.deliver(message, toAgentIn: pane, label: "From you") }
            add(.user, text, images: images.count)
            add(.action, "Sent to " + ListFormatter.localizedString(byJoining: mentioned.map { host.paneLabel($0) }))
            return
        }
        stop(quietly: true)
        pictures = images
        add(.user, text, images: images.count)
        goal = text
        if host.orchestrator(id)?.goal != text { host.setGoal(text, for: id) }
        turn = 0
        ending = nil
        running = true
        flagged = []
        think(command: text, updates: [])
    }

    /// What an @mentioned agent gets: your words, the pictures' paths, or both; nil when there's
    /// neither, so nothing is sent without saying so.
    static func mentionMessage(_ rest: String, files: [URL]) -> String? {
        let paths = files.map { "Image: \($0.path)" }.joined(separator: "\n")
        switch (rest.isEmpty, files.isEmpty) {
        case (true, true): return nil
        case (false, true): return rest
        case (true, false): return (files.count == 1 ? "Have a look at this image." : "Have a look at these images.") + "\n\n" + paths
        case (false, false): return rest + "\n\n" + paths
        }
    }

    func stop(quietly: Bool = false) {
        run?.stop()
        run = nil
        pass += 1
        busy = false
        waiting = []
        watchdog?.cancel()
        watchdog = nil
        if running, !quietly {
            add(.event, "Stopped. Send a command to carry on.")
            ending = .stopped
        }
        running = false
    }

    func clear() {
        stop(quietly: true)
        session = nil
        log = []
        turn = 0
        ending = nil
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
            halt()
            add(.event, "Stopped after \(limit) turns. Send a command to carry on.")
            return
        }
        if let host, host.orchestrator(id) != nil, host.orchestratorAgents(id).contains(where: { host.isPaused($0.pane) }) {
            halt()
            add(.event, "Paused agents: waiting. Send a command to carry on.")
            return
        }
        think(command: nil, updates: updates)
    }

    /// Stops following up, as something stopped it (not because the work is done).
    private func halt() {
        running = false
        ending = .stopped
    }

    private static func describe(_ update: Update) -> String {
        switch update.activity {
        case .needsPermission: return "\(update.name) is waiting for your permission"
        case .needsInput: return "\(update.name) asks something"
        case .failed: return "\(update.name) stopped with an error"
        default: return "\(update.name) finished"
        }
    }

    /// One update as the brain reads it: who, what happened, and its answer.
    static func line(for update: Update, handle: String?) -> String {
        var line = "- \(handle ?? "?") \(update.name): \(describe(update).dropFirst(update.name.count + 1))"
        if let detail = update.detail, update.activity == .needsPermission { line += " (\(detail))" }
        if let check = update.failedCheck { line += "; its project check failed: \(check)" }
        if let answer = update.answer {
            line += ". Its answer:\n" + BoardTeams.clip(answer, 2500)
        } else if update.activity == .done || update.activity == .ready || update.activity == .needsInput {
            line += " (its answer couldn't be read; ask it if you need it)"
        }
        return line
    }

    // MARK: Thinking

    private func think(command: String?, updates: [Update]) {
        guard let host else { return }
        guard host.ensureTeam(id) != nil else {
            add(.error, host.orchestratorPlace == .board ? "This orchestrator card is gone from the board." : "This orchestrator was closed.")
            halt()
            return
        }
        let engine = self.engine, tool = engine.flatMap { ToolPath.find($0.rawValue) }
        guard canned.isEmpty == false || tool != nil else {
            add(.error, engines == nil ? "Still looking for Claude Code and Codex. Try again in a moment."
                : "The orchestrator needs Claude Code or Codex. Install one, then try again.")
            halt()
            return
        }
        turn += 1
        busy = true
        pass += 1
        let pass = self.pass
        // Agents started by hand haven't always said anything yet: look for them by process.
        let unknown = Set(host.orchestratorAgents(id).filter { host.agentInfo($0.pane) == nil }.map(\.pane))
        guard unknown.isEmpty else {
            host.detectAgents(in: unknown) { [weak self] found in
                guard self?.pass == pass else { return }
                self?.proceed(command: command, updates: updates, detected: found)
            }
            return
        }
        proceed(command: command, updates: updates, detected: [:])
    }

    private func proceed(command: String?, updates: [Update], detected: [UUID: String]) {
        guard let host, host.ensureTeam(id) != nil, busy else { return }
        self.detected = Set(detected.keys)
        let engine = self.engine, tool = engine.flatMap { ToolPath.find($0.rawValue) }
        let context = host.orchestratorContext(id, agents: installed, detected: detected)
        let instructions = OrchestratorPrompt.instructions(for: host.orchestratorPlace)
        var body = "Turn \(turn) of at most \(limit).\n\nThe agents now:\n\(context.text)"
        if let goal { body += "\n\nThe user's command: \(goal)" }
        if let command, command != goal { body += "\n\nNew from the user: \(command)" }
        if !updates.isEmpty {
            body += "\n\nSince your last turn:\n" + updates.map { Self.line(for: $0, handle: context.handle($0.tile)) }.joined(separator: "\n")
        }
        let pictures = self.pictures
        self.pictures = []
        if !pictures.isEmpty { body += "\n\nThe user attached \(pictures.count) image\(pictures.count == 1 ? "" : "s") to this command." }
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
            halt()
            add(.error, "Claude Code or Codex isn't available any more.")
            return
        }
        let prompt = HeadlessAgent.prompt(engine, instructions: instructions, session: session, body: body)
        let session = self.session
        let run = HeadlessAgent.Run()
        self.run = run
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Off the main thread: the files are written and the PNGs encoded here. Codex reads
            // the files; for Claude Code the pictures go in its prompt and switch it to a stream.
            let files = ImageAttachment.save(pictures)
            let arguments = HeadlessAgent.arguments(engine, instructions: instructions,
                                                    schema: OrchestratorPrompt.schema, session: session, images: files)
            let input = HeadlessAgent.input(engine, prompt: prompt, images: pictures.map(\.png))
            let result = HeadlessAgent.run(run, tool: tool, arguments: arguments, input: input)
            DispatchQueue.main.async {
                guard let self, self.run === run else { return }
                self.run = nil
                self.busy = false
                let parsed = HeadlessAgent.parse(result, engine: engine)
                if let session = parsed.session { self.session = session }
                guard let reply = parsed.json.flatMap({ try? JSONDecoder().decode(OrchestratorReply.self, from: $0) }) else {
                    self.add(.error, parsed.error ?? "No answer from \(engine.title).")
                    self.halt()
                    return
                }
                self.apply(reply, handles: context.handles)
            }
        }
    }

    /// Does what the reply says (tests feed replies here directly).
    func apply(_ reply: OrchestratorReply, handles: [String: UUID]) {
        guard let host else { return }
        let say = reply.say.trimmingCharacters(in: .whitespacesAndNewlines)
        if !say.isEmpty { add(.say, say) }
        var dispatched = false
        // Its own step to undo: replies come between events, so nothing else would close it.
        let undo = host.orchestratorUndo
        let own = undo?.groupingLevel == 0
        if own { undo?.beginUndoGrouping() }
        for action in reply.actions {
            guard let line = host.performOrchestration(action, for: id, handles: handles, detected: detected) else { continue }
            add(.action, line)
            if action.type != "wait" { dispatched = true }
        }
        if own {
            undo?.endUndoGrouping()
            undo?.setActionName(host.orchestratorName(id))
        }
        if reply.done == true {
            if running { ending = .done }
            running = false
            return
        }
        watch()
        let pending = waiting
        waiting = []
        guard running, host.orchestrator(id) != nil else { return }
        // Nothing sent and nobody working: there's nothing to wait for.
        let working = host.orchestratorAgents(id).contains { host.agentInfo($0.pane)?.activity == .working }
        if !dispatched && !working && pending.isEmpty {
            running = false
            ending = .done
            return
        }
        if !pending.isEmpty { followUp(pending) }
    }

    /// While it waits on its agents: an agent whose message hasn't gone in after a while has
    /// something else on screen (a trust or sign-in prompt, a menu): say so, once.
    private func watch() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.busy, let host = self.host, host.orchestrator(self.id) != nil else { return }
            for agent in host.orchestratorAgents(self.id) where !self.flagged.contains(agent.pane) {
                guard let surface = agent.surface else { continue }
                let stuck = AgentInbox.shared.waiting(for: surface).contains { Date().timeIntervalSince($0.created) > 40 }
                guard stuck, AgentInbox.readiness(of: surface) != .working else { continue }
                self.flagged.insert(agent.pane)
                self.add(.error, "\(host.paneLabel(agent.pane)) hasn't taken its message: something is waiting in its "
                         + "terminal (a prompt or sign-in). Answer it there and the message goes in.")
            }
            self.watch()
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func add(_ kind: Entry.Kind, _ text: String, images: Int = 0) {
        log.append(Entry(kind: kind, text: text, images: images))
        if log.count > 80 { log.removeFirst(log.count - 80) }
        DemoDirector.note("orchestrator[\(host?.orchestratorName(id) ?? "")] \(kind): \(text.replacingOccurrences(of: "\n", with: " / "))")
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
    /// The board's instructions.
    static let instructions = instructions(for: .board)

    /// What the brain is told about its job. Only where it lives differs: a board's canvas of
    /// terminals, or a classic window's tabs.
    static func instructions(for place: OrchestratorPlace) -> String {
        let opening = place == .board
            ? "You are an orchestrator on the user's Tellurion board, a canvas of terminals in a macOS app."
            : "You are an orchestrator in the user's Tellurion terminal: several tabs, each with a coding agent, in a macOS app."
        let hands = place == .board ? "the board" : "Tellurion"
        return """
        \(opening) Several coding agents (Claude Code, Codex and others, each in its own terminal) are \
        wired to you. The user gives you a command; you split it into tasks, hand them to the \
        agents, read what they answer when they finish, and hand out the next steps until the \
        command is done. You can't run commands or read files yourself; you act only through \
        the actions below, and \(hands) carries them out.

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
    }

    /// What an agent the orchestrator starts is told first.
    static func memberIntro(role: String?, orchestrator: String, place: OrchestratorPlace) -> String {
        "You're " + (role.map { "the \($0)" } ?? "an agent") + " working for \(orchestrator), which coordinates several coding "
            + "agents " + (place == .board ? "on the user's Tellurion board" : "in the user's Tellurion terminal")
            + ". It sees your final answer each turn, so end each turn with a short "
            + "summary of what you did and anything you need."
    }

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
#endif
