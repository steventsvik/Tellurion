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
