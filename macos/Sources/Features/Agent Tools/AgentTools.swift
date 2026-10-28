#if os(macOS)
import AppKit

/// Shared plumbing for Mission Control, agent races and handoffs: running git, and starting
/// an agent CLI with a long prompt in a new tab or split.
enum AgentTools {
    /// Where races and handoff prompts are kept (no spaces, so paths paste cleanly into shells).
    /// Boards and the board agent's files live here too. Test-only: `GHOSTTY_EXTREME_TEST_HOME`
    /// moves it, as it does the hooks, so a test copy stays out of your boards (an app's
    /// NSHomeDirectory ignores HOME).
    static let root = URL(fileURLWithPath: HookInstaller.home).appendingPathComponent(".ghostty-extreme", isDirectory: true)

    struct Result {
        let status: Int32
        let output: String
        let error: String
        var ok: Bool { status == 0 }
    }

    /// Runs git synchronously. Call off the main thread for anything that can be slow.
    @discardableResult
    static func git(_ args: [String], in directory: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = EventToken.scrubbed(environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return Result(status: -1, output: "", error: "\(error)") }
        // Read before waiting so large output can't fill the pipe and block git.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: outData, as: UTF8.self),
                      error: String(decoding: errData, as: UTF8.self))
    }

    /// The repository containing `folder`, if any.
    static func repoRoot(of folder: String) -> String? {
        let result = git(["rev-parse", "--show-toplevel"], in: folder)
        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !root.isEmpty ? root : nil
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The shell line that starts `agent` with the prompt stored in `promptFile`. The prompt
    /// is read by the shell, so it can be any length and contain any characters.
    static func agentCommand(_ agent: VerticalTabAgentKind, promptFile: URL) -> String {
        let binary = agent == .codex ? "codex" : "claude"
        return "\(binary) \"$(cat \(shellQuote(promptFile.path)))\"\n"
    }

    /// Saves a prompt under ~/.ghostty-extreme/<folder>/ and returns its file.
    static func writePrompt(_ text: String, folder: String, name: String) -> URL? {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    /// The agent's most recent reply, read from the end of its transcript.
    static func lastAssistantMessage(transcript path: String?) -> String? {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("assistant") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            // Claude Code: {"type":"assistant","message":{"content":[{"type":"text","text":...}]}}
            if record["type"] as? String == "assistant", let message = record["message"] as? [String: Any] {
                let parts = (message["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
            // Codex: {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":...}]}}
            if let payload = record["payload"] as? [String: Any], payload["type"] as? String == "message",
               payload["role"] as? String == "assistant" {
                let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
        }
        return nil
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(cut)" : text
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
#endif
