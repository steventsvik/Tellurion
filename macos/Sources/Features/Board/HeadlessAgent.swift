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
    static func arguments(_ engine: Engine, instructions: String, schema: String, session: String?) -> [String] {
        switch engine {
        case .claude:
            // No tools, MCP servers, hooks or settings: it can only answer, and the board acts.
            var arguments = ["-p", "--output-format", "json", "--model", "sonnet", "--tools", "",
                             "--strict-mcp-config", "--setting-sources", "",
                             "--system-prompt", instructions, "--json-schema", schema]
            if let session { arguments += ["--resume", session] }
            return arguments
        case .codex:
            let options = ["--json", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "notify=[]"]
            if let session { return ["exec", "resume"] + options + [session, "-"] }
            return ["exec"] + options + ["-"]
        }
    }

    /// The prompt for one turn: Codex's first one starts with the instructions.
    static func prompt(_ engine: Engine, instructions: String, session: String?, body: String) -> String {
        (session == nil && engine == .codex ? instructions + "\n\n" : "") + body
    }

    /// Runs in its own folder, so its sessions stay out of your projects' histories. Gets your
    /// login shell's PATH and nothing else from Tellurion's environment (no event token).
    static func run(_ process: Process, tool: String, arguments: [String], input: String) -> AgentTools.Result {
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

    // MARK: Streaming, read-only, in a project

    /// What a streaming run is doing.
    enum Phase: Equatable {
        case thinking, reading, writing, finishing
    }

    /// Runs the engine in `folder` with read-only tools (it can look at the project, not change
    /// it), streaming: `progress` gets the phase and the answer so far (on a background
    /// queue), `done` the whole answer or an error (on the main queue). Returns the process,
    /// to stop it.
    @discardableResult
    static func stream(_ engine: Engine, instructions: String, prompt: String, folder: String, model: String?,
                       progress: @escaping (Phase, String) -> Void,
                       done: @escaping (Result<String, Error>) -> Void) -> Process? {
        guard let tool = ToolPath.find(engine.rawValue) else {
            done(.failure(StreamError.missing(engine.title)))
            return nil
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
            process.arguments = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "notify=[]", "-"]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME": NSHomeDirectory(), "PATH": SetupChecks.loginPath.joined(separator: ":"),
                           "LANG": inherited["LANG"] ?? "en_US.UTF-8", "TERM": "dumb"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR"] { environment[key] = inherited[key] }
        process.environment = environment
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            done(.failure(error))
            return nil
        }
        stdin.fileHandleForWriting.write(Data(((engine == .codex ? instructions + "\n\n" : "") + prompt).utf8))
        try? stdin.fileHandleForWriting.close()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            var text = ""
            var final: String?
            var failure: String?
            let handle = out.fileHandleForReading
            func line(_ data: Data) {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let type = json["type"] as? String
                switch engine {
                case .claude:
                    if type == "stream_event", let event = json["event"] as? [String: Any] {
                        if let delta = event["delta"] as? [String: Any], let chunk = delta["text"] as? String {
                            text += chunk
                            progress(.writing, text)
                        } else if event["type"] as? String == "content_block_start",
                                  (event["content_block"] as? [String: Any])?["type"] as? String == "tool_use" {
                            // A new turn after tools: what it wrote before was thinking aloud.
                            text = ""
                            progress(.reading, text)
                        }
                    } else if type == "result" {
                        final = json["result"] as? String
                        if json["is_error"] as? Bool == true { failure = final ?? "The run failed." }
                    }
                case .codex:
                    if let item = json["item"] as? [String: Any] {
                        switch item["type"] as? String {
                        case "reasoning": progress(.thinking, text)
                        case "command_execution", "file_read": progress(.reading, text)
                        case "agent_message":
                            if let message = item["text"] as? String {
                                text = message
                                progress(.writing, text)
                            }
                        default: break
                        }
                    }
                    if type == "error" || type == "turn.failed" {
                        failure = (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? "The run failed."
                    }
                }
            }
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
            let errorText = String(bytes: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if process.terminationStatus == 15 || process.terminationReason == .uncaughtSignal {
                    done(.failure(StreamError.stopped))
                } else if let failure {
                    done(.failure(StreamError.failed(failure)))
                } else if let answer = final ?? (text.isEmpty ? nil : text) {
                    done(.success(answer))
                } else {
                    let detail = errorText.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
                    done(.failure(StreamError.failed("\(engine.title) didn't answer: \(detail)")))
                }
            }
        }
        return process
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
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
