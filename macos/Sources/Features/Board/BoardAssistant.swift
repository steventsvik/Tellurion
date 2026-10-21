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
    enum Engine: String, CaseIterable, Identifiable {
        case claude, codex

        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code" : "Codex" }
        var kind: VerticalTabAgentKind { self == .claude ? .claude : .codex }
    }

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
            let found = Engine.allCases.filter { ToolPath.find($0.rawValue) != nil }
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
        let first = session == nil
        let prompt = (first && engine == .codex ? BoardAssistantPrompt.instructions + "\n\n" : "")
            + "The board now:\n\(context.text)\n\nThe user says: \(text)"
        let arguments = engine == .claude ? claudeArguments() : codexArguments()
        let process = Process()
        self.process = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.run(process, tool: tool, arguments: arguments, input: prompt)
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
        guard let controller else { return }
        let parsed = engine == .claude ? Self.parseClaude(result) : Self.parseCodex(result)
        if let id = parsed.session { session = id }
        guard let reply = parsed.reply else {
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

    // MARK: Running the CLI

    private func claudeArguments() -> [String] {
        // No tools, MCP servers, hooks or settings: it can only answer, and the board acts.
        var arguments = ["-p", "--output-format", "json", "--model", "sonnet", "--tools", "",
                         "--strict-mcp-config", "--setting-sources", "",
                         "--system-prompt", BoardAssistantPrompt.instructions,
                         "--json-schema", BoardAssistantPrompt.schema]
        if let session { arguments += ["--resume", session] }
        return arguments
    }

    private func codexArguments() -> [String] {
        let options = ["--json", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "notify=[]"]
        if let session { return ["exec", "resume"] + options + [session, "-"] }
        return ["exec"] + options + ["-"]
    }

    /// Runs in its own folder, so its sessions stay out of your projects' histories. Gets your
    /// login shell's PATH and nothing else from Tellurion's environment (no event token).
    private static func run(_ process: Process, tool: String, arguments: [String], input: String) -> AgentTools.Result {
        let folder = AgentTools.root.appendingPathComponent("board-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME": NSHomeDirectory(), "PATH": SetupChecks.loginPath.joined(separator: ":"),
                           "LANG": inherited["LANG"] ?? "en_US.UTF-8", "TERM": "dumb"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR"] { environment[key] = inherited[key] }
        process.environment = environment
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return AgentTools.Result(status: -1, output: "", error: "\(error)") }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        // A stuck run gives up after two minutes.
        let timeout = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        var errData = Data()
        let reader = DispatchQueue(label: "board-agent-stderr")
        reader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        reader.sync {}
        timeout.cancel()
        return AgentTools.Result(status: process.terminationStatus,
                                 output: String(bytes: outData, encoding: .utf8) ?? "",
                                 error: String(bytes: errData, encoding: .utf8) ?? "")
    }

    struct Parsed {
        var reply: BoardAssistantReply?
        var session: String?
        var error: String?
    }

    static func parseClaude(_ result: AgentTools.Result) -> Parsed {
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Parsed(error: failure(result, "Claude Code"))
        }
        var parsed = Parsed(session: json["session_id"] as? String)
        if let structured = json["structured_output"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            parsed.reply = try? JSONDecoder().decode(BoardAssistantReply.self, from: data)
        }
        if parsed.reply == nil, let text = json["result"] as? String { parsed.reply = BoardAssistantReply.decode(text) }
        if parsed.reply == nil {
            parsed.error = (json["is_error"] as? Bool == true ? json["result"] as? String : nil) ?? failure(result, "Claude Code")
        }
        return parsed
    }

    static func parseCodex(_ result: AgentTools.Result) -> Parsed {
        var parsed = Parsed()
        var message: String?
        for line in result.output.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if json["type"] as? String == "thread.started" { parsed.session = json["thread_id"] as? String }
            if let item = json["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                message = item["text"] as? String
            }
            if json["type"] as? String == "error" || json["type"] as? String == "turn.failed" {
                parsed.error = (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String)
            }
        }
        parsed.reply = message.flatMap(BoardAssistantReply.decode)
        if parsed.reply == nil, parsed.error == nil { parsed.error = message ?? failure(result, "Codex") }
        return parsed
    }

    private static func failure(_ result: AgentTools.Result, _ name: String) -> String {
        if result.status == 15 { return "Stopped." }
        let detail = result.error.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        if let detail, !detail.isEmpty { return "\(name) didn't answer: \(detail)" }
        return "\(name) didn't answer (exit \(result.status))."
    }
}
#endif
