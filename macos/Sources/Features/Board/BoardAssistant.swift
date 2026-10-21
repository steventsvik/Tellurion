#if os(macOS)
import AppKit
import Combine

/// The board's own agent, in the bar at the bottom of a board: you say what you want ("three
/// Claude agents on the kanban's to-do cards", "sketch the backend") and it arranges the
/// board. It runs your installed Claude Code (or Codex) headless with no tools of its own: it
/// only answers with actions from a fixed list (see BoardAssistantAction), which the board
/// carries out. Closing tiles, removing cards and typing into a running agent wait for you
/// to confirm. Each board has its own conversation.
final class BoardAssistant: ObservableObject {
    typealias Engine = HeadlessAgent.Engine

    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant, error }
        let id = UUID()
        let role: Role
        var text: String
        /// What the board did for this answer ("Opened 3 Claude Code tiles").
        var done: [String] = []
    }

    /// Actions that wait for you: what they'll do, in words.
    struct Pending: Equatable {
        let lines: [String]
        let actions: [BoardAssistantAction]
        let handles: BoardAssistantHandles

        static func == (lhs: Pending, rhs: Pending) -> Bool { lhs.lines == rhs.lines }
    }

    static let engineKey = "BoardAssistantEngine"

    @Published private(set) var messages: [Message] = []
    @Published private(set) var busy = false
    @Published private(set) var pending: Pending?
    /// The engines installed on this Mac (nil until looked up).
    @Published private(set) var engines: [Engine]?
    @Published var engine: Engine? {
        didSet {
            guard oldValue != engine else { return }
            if let engine { UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey) }
            session = nil
        }
    }

    weak var controller: BoardController?
    private var session: String?
    private var process: Process?
    private var agents: [BoardAgent] = []

    init(controller: BoardController) {
        self.controller = controller
    }

    /// Finds Claude Code, Codex and the other agents once, off the main thread.
    func lookUp() {
        guard engines == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Engine.installed()
            let agents = BoardAgent.installed()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.agents = agents
                self.engines = found
                let saved = UserDefaults.standard.string(forKey: Self.engineKey).flatMap(Engine.init(rawValue:))
                self.engine = saved.flatMap { found.contains($0) ? $0 : nil } ?? found.first
            }
        }
    }

    // MARK: Asking

    /// Sends what you typed: to the agents you @mentioned, or to the board's agent.
    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let controller, !text.isEmpty, !busy else { return }
        // @Group: shows who it reaches, and sends once you confirm.
        if let (group, rest) = controller.groupMention(in: text) {
            guard !rest.isEmpty else { return }
            messages.append(Message(role: .user, text: text))
            var handles = BoardAssistantHandles()
            handles.ids["G"] = group.id
            let names = controller.groupSurfaces(group).map { controller.tileLabel($0) }
            pending = Pending(lines: ["Tell \(group.name) → " + ListFormatter.localizedString(byJoining: names) + " ← “\(rest)”"],
                              actions: [BoardAssistantAction(type: "message_group", text: rest, target: "G")], handles: handles)
            return
        }
        let (mentioned, rest) = controller.mentions(in: text)
        if !mentioned.isEmpty {
            guard !rest.isEmpty else { return }
            for surface in mentioned { controller.deliver(rest, to: surface) }
            let names = mentioned.map { controller.tileLabel($0) }
            messages.append(Message(role: .user, text: text, done: ["Sent to \(ListFormatter.localizedString(byJoining: names))"]))
            return
        }
        guard let engine, let tool = ToolPath.find(engine.rawValue) else {
            messages.append(Message(role: .error, text: "The board's agent needs Claude Code or Codex. Install one, then try again."))
            return
        }
        messages.append(Message(role: .user, text: text))
        pending = nil
        busy = true
        let context = controller.assistantContext(agents: agents)
        let prompt = HeadlessAgent.prompt(engine, instructions: BoardAssistantPrompt.instructions, session: session,
                                          body: "The board now:\n\(context.text)\n\nThe user says: \(text)")
        let arguments = HeadlessAgent.arguments(engine, instructions: BoardAssistantPrompt.instructions,
                                                schema: BoardAssistantPrompt.schema, session: session)
        let process = Process()
        self.process = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HeadlessAgent.run(process, tool: tool, arguments: arguments, input: prompt)
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.process = nil
                self.busy = false
                self.finish(result, engine: engine, handles: context.handles)
            }
        }
    }

    /// Stops the answer being worked on.
    func stop() {
        process?.terminate()
        process = nil
        busy = false
    }

    /// Starts a new conversation.
    func reset() {
        stop()
        session = nil
        messages = []
        pending = nil
    }

    func confirm() {
        guard let pending, let controller else { return }
        self.pending = nil
        let done = controller.perform(pending.actions, handles: pending.handles, confirmed: true).done
        note(done)
    }

    func cancel() {
        guard pending != nil else { return }
        pending = nil
        note(["Cancelled"])
    }

    /// Notes what was done under the last answer.
    func note(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].done += lines
        } else {
            messages.append(Message(role: .assistant, text: "", done: lines))
        }
    }

    /// Adds a line to the conversation as though the board's agent had said it (quick actions).
    func record(_ line: String) {
        messages.append(Message(role: .assistant, text: "", done: [line]))
    }

    private func finish(_ result: AgentTools.Result, engine: Engine, handles: BoardAssistantHandles) {
        let parsed = HeadlessAgent.parse(result, engine: engine)
        if let id = parsed.session { session = id }
        guard let reply = parsed.json.flatMap({ try? JSONDecoder().decode(BoardAssistantReply.self, from: $0) }) else {
            messages.append(Message(role: .error, text: parsed.error ?? "No answer from \(engine.title)."))
            return
        }
        apply(reply, handles: handles)
    }

    /// Shows the answer and does what it says (what needs you waits in `pending`).
    func apply(_ reply: BoardAssistantReply, handles: BoardAssistantHandles) {
        guard let controller else { return }
        messages.append(Message(role: .assistant, text: reply.say))
        let outcome = controller.perform(reply.actions, handles: handles, confirmed: false)
        note(outcome.done)
        if !outcome.waiting.isEmpty {
            pending = Pending(lines: outcome.waiting.compactMap { controller.describe($0, handles: handles) },
                              actions: outcome.waiting, handles: handles)
        }
    }
}
#endif
