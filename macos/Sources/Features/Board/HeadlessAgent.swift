#if os(macOS)
import Foundation

/// Your installed Claude Code or Codex run headless with no tools, for the board's agent and
/// orchestrators: it reads a prompt and answers with JSON, which the board acts on.
enum HeadlessAgent {
    enum Engine: String, CaseIterable, Identifiable {
        case claude, codex

        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code" : "Codex" }
        var kind: VerticalTabAgentKind { self == .claude ? .claude : .codex }

        /// The engines installed on this Mac (looks on disk: call it off the main thread).
        static func installed() -> [Engine] { allCases.filter { ToolPath.find($0.rawValue) != nil } }
    }

    struct Parsed {
        /// The answer's JSON object.
        var json: Data?
        var session: String?
        var error: String?
    }

    /// The command line for one turn. Claude Code gets the instructions as its system prompt
    /// and the schema for structured output; Codex reads them at the top of the first prompt.
    /// Pictures (PNG files) go to Codex by path; Claude Code gets them inside its prompt (see
    /// `input`), which it only takes, and answers, as a stream.
    static func arguments(_ engine: Engine, instructions: String, schema: String, session: String?,
                          images: [URL] = []) -> [String] {
        switch engine {
        case .claude:
            // No tools, MCP servers, hooks or settings: it can only answer, and the board acts.
            let streamed = !images.isEmpty
            var arguments = ["-p", "--output-format", streamed ? "stream-json" : "json", "--model", "sonnet", "--tools", "",
                             "--strict-mcp-config", "--setting-sources", "",
                             "--system-prompt", instructions, "--json-schema", schema]
            if streamed { arguments += ["--input-format", "stream-json", "--verbose"] }
            if let session { arguments += ["--resume", session] }
            return arguments
        case .codex:
            let options = ["--json", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "notify=[]"]
                + images.flatMap { ["-i", $0.path] }
            if let session { return ["exec", "resume"] + options + [session, "-"] }
            // `-i` takes several files: without "--", the prompt's "-" would be read as one more.
            return ["exec"] + options + ["--", "-"]
        }
    }

    /// What goes in on stdin: the prompt, or for Claude Code with pictures, one user message
    /// (a JSON line) with the prompt and each picture as PNG. Codex takes its pictures as files.
    static func input(_ engine: Engine, prompt: String, images: [Data]) -> Data {
        guard engine == .claude, !images.isEmpty else { return Data(prompt.utf8) }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for png in images {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]])
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        return ((try? JSONSerialization.data(withJSONObject: message)) ?? Data()) + Data([0x0A])
    }

    /// Claude Code, Codex and the other agents on this Mac, found once (off the main thread)
    /// and shared; `done` runs on the main queue.
    static func lookUp(_ done: @escaping (_ engines: [Engine], _ agents: [BoardAgent]) -> Void) {
        if let found { return done(found.engines, found.agents) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = (engines: Engine.installed(), agents: BoardAgent.installed())
            DispatchQueue.main.async {
                found = result
                done(result.engines, result.agents)
            }
        }
    }

    private static var found: (engines: [Engine], agents: [BoardAgent])?

    /// The prompt for one turn: Codex's first one starts with the instructions.
    static func prompt(_ engine: Engine, instructions: String, session: String?, body: String) -> String {
        (session == nil && engine == .codex ? instructions + "\n\n" : "") + body
    }

    /// Runs in its own folder, so its sessions stay out of your projects' histories. Gets your
    /// login shell's PATH and nothing else from Tellurion's environment (no event token).
    /// Call it off the main thread; `handle` stops it.
    static func run(_ handle: Run, tool: String, arguments: [String], input: String) -> AgentTools.Result {
        run(handle, tool: tool, arguments: arguments, input: Data(input.utf8))
    }

    static func run(_ handle: Run, tool: String, arguments: [String], input: Data) -> AgentTools.Result {
        let folder = AgentTools.root.appendingPathComponent("board-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment()
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        do {
            guard try handle.start(process) else { return AgentTools.Result(status: 15, output: "", error: "Stopped.") }
        } catch {
            return AgentTools.Result(status: -1, output: "", error: "\(error)")
        }
        // A stuck run gives up after two minutes (set first: the write below can wait on it).
        let timeout = DispatchWorkItem { [weak handle] in handle?.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
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

    /// Your login shell's PATH and nothing else from Tellurion's environment (no event token).
    private static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME": NSHomeDirectory(), "PATH": SetupChecks.loginPath.joined(separator: ":"),
                           "LANG": inherited["LANG"] ?? "en_US.UTF-8", "TERM": "dumb"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR"] { environment[key] = inherited[key] }
        return environment
    }

    // MARK: Streaming, read-only, in a project

    /// What a streaming run is doing.
    enum Phase: Equatable {
        case thinking, reading, writing
    }

    /// How long a streaming run may take.
    static let streamLimit: TimeInterval = 600

    /// A streaming run; `stop()` works before or after the process starts.
    final class Run {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false
        fileprivate var timedOut = false

        var isStopped: Bool { lock.withLock { stopped } }

        func stop() {
            let process = lock.withLock { () -> Process? in
                stopped = true
                return self.process
            }
            if process?.isRunning == true { process?.terminate() }
        }

        /// Starts it unless it was stopped first.
        fileprivate func start(_ process: Process) throws -> Bool {
            try lock.withLock {
                guard !stopped else { return false }
                try process.run()
                self.process = process
                return true
            }
        }
    }

    /// What a streaming run is asked: its instructions and prompt, the project folder it
    /// reads, and the model (nil: the engine's default).
    struct Ask {
        var instructions: String
        var prompt: String
        var folder: String
        var model: String?
    }

    /// Runs the engine in the asked folder with read-only tools (it can look at the project, not change
    /// it), streaming: `progress` gets the phase and the answer so far, a few times a second at
    /// most (on a background queue); `done` the whole answer or an error (on the main queue).
    /// Gives up after `streamLimit`.
    @discardableResult
    static func stream(_ engine: Engine, _ ask: Ask,
                       progress: @escaping (Phase, String) -> Void,
                       done: @escaping (Result<String, Error>) -> Void) -> Run {
        let run = Run()
        let instructions = ask.instructions, prompt = ask.prompt, folder = ask.folder, model = ask.model
        let finish = { (result: Result<String, Error>) in DispatchQueue.main.async { done(result) } }
        DispatchQueue.global(qos: .userInitiated).async { [run] in
            // Finding the tool can ask a login shell, so it happens here, off the main thread.
            guard let tool = ToolPath.find(engine.rawValue) else {
                finish(.failure(StreamError.missing(engine.title)))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            switch engine {
            case .claude:
                process.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                     "--model", model ?? "sonnet", "--strict-mcp-config", "--setting-sources", "",
                                     "--tools", "Read", "Grep", "Glob", "--allowedTools", "Read", "Grep", "Glob",
                                     "--system-prompt", instructions]
            case .codex:
                // No MCP servers: they'd run outside the read-only sandbox.
                process.arguments = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only",
                                     "-c", "notify=[]", "-c", "mcp_servers={}", "-"]
            }
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            process.environment = environment()
            let stdin = Pipe(), out = Pipe(), err = Pipe()
            process.standardInput = stdin
            process.standardOutput = out
            process.standardError = err
            do {
                guard try run.start(process) else {
                    finish(.failure(StreamError.stopped))
                    return
                }
            } catch {
                finish(.failure(error))
                return
            }
            let timeout = DispatchWorkItem { [weak run] in
                run?.timedOut = true
                run?.stop()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + streamLimit, execute: timeout)
            // stderr on its own, so a chatty CLI can't fill the pipe and stall.
            var errorData = Data()
            let errorRead = DispatchGroup()
            errorRead.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = err.fileHandleForReading.readDataToEndOfFile()
                errorRead.leave()
            }
            try? stdin.fileHandleForWriting.write(contentsOf: Data(((engine == .codex ? instructions + "\n\n" : "") + prompt).utf8))
            try? stdin.fileHandleForWriting.close()

            var buffer = Data()
            var text = ""
            var sent = ""
            var lastSent = Date.distantPast
            var final: String?
            var failure: String?
            func emit(_ phase: Phase) {
                guard phase != .writing || Date().timeIntervalSince(lastSent) > 0.25 else { return }
                lastSent = Date()
                sent = text
                progress(phase, text)
            }
            func line(_ data: Data) {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let type = json["type"] as? String
                switch engine {
                case .claude:
                    if type == "stream_event", let event = json["event"] as? [String: Any] {
                        if let delta = event["delta"] as? [String: Any], let chunk = delta["text"] as? String {
                            text += chunk
                            emit(.writing)
                        } else if event["type"] as? String == "content_block_start",
                                  (event["content_block"] as? [String: Any])?["type"] as? String == "tool_use" {
                            // A new turn after tools: what it wrote before was thinking aloud.
                            text = ""
                            emit(.reading)
                        }
                    } else if type == "result" {
                        final = (json["result"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                        if json["is_error"] as? Bool == true { failure = final ?? "The run failed." }
                    }
                case .codex:
                    if let item = json["item"] as? [String: Any] {
                        switch item["type"] as? String {
                        case "reasoning": emit(.thinking)
                        case "command_execution", "file_read": emit(.reading)
                        case "agent_message":
                            if let message = item["text"] as? String {
                                text = message
                                emit(.writing)
                            }
                        default: break
                        }
                    }
                    if type == "error" || type == "turn.failed" {
                        failure = (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? "The run failed."
                    }
                }
            }
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    line(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { line(buffer) }
            process.waitUntilExit()
            timeout.cancel()
            errorRead.wait()
            // The last words, which the throttle may have held back.
            if text != sent, !run.isStopped { progress(.writing, text) }
            let errorText = String(bytes: errorData, encoding: .utf8) ?? ""
            let answer = final ?? (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text)
            if run.timedOut {
                finish(.failure(StreamError.failed("\(engine.title) took longer than \(Int(streamLimit / 60)) minutes and was stopped.")))
            } else if run.isStopped {
                finish(.failure(StreamError.stopped))
            } else if let failure {
                finish(.failure(StreamError.failed(failure)))
            } else if let answer {
                finish(.success(answer))
            } else {
                let detail = errorText.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
                finish(.failure(StreamError.failed("\(engine.title) didn't answer: \(detail)")))
            }
        }
        return run
    }

    enum StreamError: LocalizedError {
        case missing(String), stopped, failed(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): return "\(name) isn't installed."
            case .stopped: return "Stopped."
            case .failed(let text): return text
            }
        }
    }

    static func parse(_ result: AgentTools.Result, engine: Engine) -> Parsed {
        engine == .claude ? parseClaude(result) : parseCodex(result)
    }

    static func parseClaude(_ result: AgentTools.Result) -> Parsed {
        guard let json = claudeAnswer(in: result.output) else {
            return Parsed(error: failure(result, "Claude Code"))
        }
        var parsed = Parsed(session: json["session_id"] as? String)
        if let structured = json["structured_output"] as? [String: Any] {
            parsed.json = try? JSONSerialization.data(withJSONObject: structured)
        }
        if parsed.json == nil, let text = json["result"] as? String { parsed.json = object(in: text) }
        if parsed.json == nil {
            parsed.error = (json["is_error"] as? Bool == true ? json["result"] as? String : nil) ?? failure(result, "Claude Code")
        }
        return parsed
    }

    /// Claude Code's answer object: its whole output (`--output-format json`), or the `result`
    /// line of a stream (how it answers a prompt with pictures).
    static func claudeAnswer(in output: String) -> [String: Any]? {
        if let data = output.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        for line in output.split(separator: "\n").reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "result" else { continue }
            return json
        }
        return nil
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
        parsed.json = message.flatMap(object(in:))
        if parsed.json == nil, parsed.error == nil { parsed.error = message ?? failure(result, "Codex") }
        return parsed
    }

    /// The JSON object in an answer's text, with or without a code fence around it.
    static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    private static func failure(_ result: AgentTools.Result, _ name: String) -> String {
        if result.status == 15 { return "Stopped." }
        let detail = result.error.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        if let detail, !detail.isEmpty { return "\(name) didn't answer: \(detail)" }
        return "\(name) didn't answer (exit \(result.status))."
    }
}
#endif
