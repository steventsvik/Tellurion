#if os(macOS)
import Foundation

/// Tails an agent's session transcript (JSONL) and turns new records into timeline items
/// for the editor's Agent panel: prompts, thinking, messages, tool calls and results.
///
/// Only bytes appended since the last read are processed, on a background queue, and only
/// while something shows them (the editor panel, or a board's Agent Map).
final class AgentFeed {
    typealias Item = [String: Any]

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.agent-feed", qos: .utility)
    private var kind: VerticalTabAgentKind = .unknown
    private(set) var path: String?

    /// The session transcript, plus one per sub-agent (Claude Code runs sub-agents with
    /// their own transcripts in `<session>/subagents/`; they often do the actual reading).
    private var main: Tail?
    private var subagents: [String: Tail] = [:]
    private var subagentDir: String?
    private var scanTimer: DispatchSourceTimer?
    private let codex = CodexFeed()
    private var codexSession: CodexTracking.Session?
    private var codexMetadata: [String: CodexTracking.Session] = [:]
    private var codexHooks: [String: Tail] = [:]

    /// Called on the main queue with (items, isReset).
    var onItems: (([Item], Bool) -> Void)?

    /// How far back to look when starting to follow a session: enough to reach the start of
    /// the current turn, so an editor opened mid-prompt shows everything the agent did.
    private let backlog: UInt64 = 8 * 1024 * 1024
    /// Most items sent when starting to follow.
    private let maxBacklogItems = 500
    private let maxText = 4000

    func follow(path: String, kind: VerticalTabAgentKind) {
        guard path != self.path else { return }
        stop()
        self.path = path
        self.kind = kind
        queue.async { [self] in
            guard let tail = Tail(path: path, startFromEnd: backlog) else { return }
            main = tail
            var hookItems: [Item] = []
            if kind == .codex {
                codex.reset()
                codexSession = CodexTracking.metadata(path)
                if let session = codexSession { hookItems = followCodexHooks(session, subagent: nil, initial: true) }
            }
            var backlogItems = tail.readNew().flatMap { self.items(from: $0, subagent: nil) }
            if kind == .codex {
                backlogItems += hookItems
                backlogItems.sort { ($0["time"] as? String ?? "") < ($1["time"] as? String ?? "") }
            }
            let items = Self.fromPreviousTurn(backlogItems, limit: maxBacklogItems)
            DispatchQueue.main.async { self.onItems?(items, true) }
            tail.watch(on: queue) { [weak self] in self?.drain(tail, subagent: nil) }

            // Sub-agents that already exist are followed from now on; new ones from the start.
            subagentDir = (path as NSString).deletingPathExtension + "/subagents"
            scanSubagents(existingFromEnd: true)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.scanSubagents(existingFromEnd: false) }
            timer.resume()
            scanTimer = timer
        }
    }

    func stop() {
        path = nil
        queue.async { [self] in
            scanTimer?.cancel()
            scanTimer = nil
            main?.close()
            main = nil
            subagents.values.forEach { $0.close() }
            subagents.removeAll()
            subagentDir = nil
            codexHooks.values.forEach { $0.close() }
            codexHooks.removeAll()
            codexMetadata.removeAll()
            codexSession = nil
        }
    }

    /// The current turn and the one before it (from the second-to-last prompt), capped.
    private static func fromPreviousTurn(_ items: [Item], limit: Int) -> [Item] {
        let prompts = items.indices.filter { items[$0]["kind"] as? String == "prompt" }
        let start = prompts.count >= 2 ? prompts[prompts.count - 2] : 0
        return Array(items[start...].suffix(limit))
    }

    private func scanSubagents(existingFromEnd: Bool) {
        if kind == .codex {
            guard let session = codexSession else { return }
            followCodexHooks(session, subagent: nil)
            for child in CodexTracking.children(of: session, cached: &codexMetadata) {
                let label = "\(child.label) · \(child.id.prefix(8))"
                followCodexHooks(child, subagent: label)
                guard subagents[child.id] == nil,
                      let tail = Tail(path: child.path, startFromEnd: backlog) else { continue }
                subagents[child.id] = tail
                drainCodexChild(tail, session: child, label: label)
                tail.watch(on: queue) { [weak self] in self?.drainCodexChild(tail, session: child, label: label) }
            }
            return
        }
        guard let dir = subagentDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names where name.hasSuffix(".jsonl") && subagents[name] == nil {
            let file = dir + "/" + name
            // Sub-agents already running when following starts show their recent work too.
            let modified = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? .distantPast
            let recent = Date().timeIntervalSince(modified) < 600
            guard let tail = Tail(path: file, startFromEnd: existingFromEnd ? (recent ? 512 * 1024 : 0) : nil) else { continue }
            let label = Self.subagentLabel(meta: (file as NSString).deletingPathExtension + ".meta.json")
            subagents[name] = tail
            drain(tail, subagent: label)
            tail.watch(on: queue) { [weak self] in self?.drain(tail, subagent: label) }
        }
    }

    @discardableResult
    private func followCodexHooks(_ session: CodexTracking.Session, subagent: String?, initial: Bool = false) -> [Item] {
        guard codexHooks[session.id] == nil, let path = CodexTracking.hookPath(session.id),
              let tail = Tail(path: path, startFromEnd: backlog) else { return [] }
        codexHooks[session.id] = tail
        var items: [Item] = []
        if initial { items = tail.readNew().flatMap { codex.hookItems($0, scope: session.id) } } else { drainCodexHooks(tail, session: session, label: subagent) }
        tail.watch(on: queue) { [weak self] in self?.drainCodexHooks(tail, session: session, label: subagent) }
        return items
    }

    private func drainCodexHooks(_ tail: Tail, session: CodexTracking.Session, label: String?) {
        var items = tail.readNew().flatMap { codex.hookItems($0, scope: session.id) }
        if let label {
            for index in items.indices {
                items[index]["sub"] = label
                if let id = items[index]["id"] as? String { items[index]["id"] = session.id + ":" + id }
            }
        }
        guard !items.isEmpty else { return }
        DispatchQueue.main.async { self.onItems?(items, false) }
    }

    private func drainCodexChild(_ tail: Tail, session: CodexTracking.Session, label: String) {
        let items = tail.readNew().filter { record in
            guard let start = session.historyStart, let ordinal = record["ordinal"] as? Int else { return true }
            return ordinal >= start
        }.flatMap { record -> [Item] in
            var items = codex.items(record, scope: session.id, hooks: codexHooks[session.id] != nil)
                .filter { $0["kind"] as? String != "prompt" }
            for index in items.indices {
                items[index]["sub"] = label
                if let id = items[index]["id"] as? String { items[index]["id"] = session.id + ":" + id }
            }
            return items
        }
        guard !items.isEmpty else { return }
        DispatchQueue.main.async { self.onItems?(items, false) }
    }

    private func drain(_ tail: Tail, subagent: String?) {
        let items = tail.readNew().flatMap { self.items(from: $0, subagent: subagent) }
        guard !items.isEmpty else { return }
        DispatchQueue.main.async { self.onItems?(items, false) }
    }

    private static func subagentLabel(meta: String) -> String {
        guard let data = FileManager.default.contents(atPath: meta),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = json["description"] as? String, !description.isEmpty else { return "Sub-agent" }
        return description
    }

    private func items(from record: [String: Any], subagent: String?) -> [Item] {
        var items: [Item]
        if kind == .codex {
            let name = (record["payload"] as? [String: Any])?["name"] as? String
            if codexHooks.isEmpty && (name == "exec" || name == "functions.exec") {
                // Completed native items carry every nested action with its real id.
                // Do not invent a single command by extracting one string from a script.
                items = []
            } else {
                let scope = codexSession?.id ?? path ?? "codex"
                items = codex.items(record, scope: scope, hooks: codexHooks[scope] != nil)
            }
        } else {
            items = claudeItems(record)
        }
        if let subagent {
            // A sub-agent's first message is its instructions, not the user's prompt.
            items = items.filter { $0["kind"] as? String != "prompt" }
            for index in items.indices { items[index]["sub"] = subagent }
        }
        return items
    }

    /// Follows one JSONL file: reads only appended bytes, keeps partial lines for later.
    private final class Tail {
        private let handle: FileHandle
        private var offset: UInt64
        private var partial = Data()
        private var skipFirstLine: Bool
        private var source: DispatchSourceFileSystemObject?

        /// `startFromEnd`: nil = whole file, 0 = only new data, n = the last n bytes.
        init?(path: String, startFromEnd: UInt64?) {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            self.handle = handle
            let size = (try? handle.seekToEnd()) ?? 0
            if let n = startFromEnd { offset = size > n ? size - n : 0 } else { offset = 0 }
            skipFirstLine = offset > 0 && startFromEnd != 0
        }

        func watch(on queue: DispatchQueue, _ handler: @escaping () -> Void) {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: handle.fileDescriptor, eventMask: [.extend, .write], queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            self.source = source
        }

        func readNew() -> [[String: Any]] {
            try? handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset += UInt64(data.count)
            var buffer = partial + data
            if skipFirstLine, let newline = buffer.firstIndex(of: 0x0A) {
                buffer = buffer[(newline + 1)...]
                skipFirstLine = false
            }
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else {
                partial = Data(buffer)
                return []
            }
            partial = Data(buffer[(lastNewline + 1)...])
            return buffer[..<lastNewline].split(separator: 0x0A).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
        }

        func close() {
            source?.cancel()
            try? handle.close()
        }
    }

    private func clip(_ text: String?, _ limit: Int? = nil) -> String {
        guard let text else { return "" }
        let limit = limit ?? maxText
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: Claude Code

    private func claudeItems(_ record: [String: Any]) -> [Item] {
        guard let type = record["type"] as? String, let message = record["message"] as? [String: Any] else { return [] }
        let time = record["timestamp"] as? String ?? ""
        if type == "user" {
            if let text = message["content"] as? String {
                // Local command output and system reminders aren't prompts.
                return text.hasPrefix("<") ? [] : [["kind": "prompt", "text": clip(text), "time": time]]
            }
            var items: [Item] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_result":
                    items.append([
                        "kind": "result",
                        "id": block["tool_use_id"] as? String ?? "",
                        "error": block["is_error"] as? Bool ?? false,
                        "text": clip(resultText(block["content"]), 1500),
                    ])
                case "text":
                    let text = block["text"] as? String ?? ""
                    if !text.hasPrefix("<") { items.append(["kind": "prompt", "text": clip(text), "time": time]) }
                default: break
                }
            }
            return items
        }
        guard type == "assistant" else { return [] }
        var items: [Item] = []
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "thinking":
                // Thinking can be hidden; still show that the agent was thinking.
                items.append(["kind": "thinking", "text": clip(block["thinking"] as? String), "time": time])
            case "redacted_thinking":
                items.append(["kind": "thinking", "text": "", "time": time])
            case "text":
                let text = block["text"] as? String ?? ""
                if !text.isEmpty { items.append(["kind": "message", "text": clip(text), "time": time]) }
            case "tool_use":
                items.append(toolItem(
                    id: block["id"] as? String ?? "",
                    name: block["name"] as? String ?? "Tool",
                    input: block["input"] as? [String: Any] ?? [:],
                    time: time))
            default: break
            }
        }
        return items
    }

    private func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Normalizes a tool call: which kind of action it is and its most useful details.
    private func toolItem(id: String, name: String, input: [String: Any], time: String) -> Item {
        var item: Item = ["kind": "tool", "id": id, "tool": name, "time": time]
        item["action"] = Self.action(for: name)
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? input["path"] as? String {
            item["path"] = path
        }
        if let command = input["command"] as? String { item["command"] = clip(command, 600) }
        // Where a read looks: Read's 1-based start line and line count.
        if let offset = input["offset"] as? Int { item["offset"] = offset }
        if let limit = input["limit"] as? Int { item["limit"] = limit }
        // Codex runs commands in a working directory; relative paths resolve against it.
        if let workdir = input["workdir"] as? String ?? input["cwd"] as? String { item["cwd"] = workdir }
        if let description = input["description"] as? String { item["description"] = clip(description, 200) }
        if let pattern = input["pattern"] as? String { item["pattern"] = clip(pattern, 200) }
        if let query = input["query"] as? String ?? input["url"] as? String ?? input["prompt"] as? String {
            item["query"] = clip(query, 300)
        }
        if let old = input["old_string"] as? String { item["old"] = clip(old, 2500) }
        if let new = input["new_string"] as? String { item["new"] = clip(new, 2500) }
        if let content = input["content"] as? String { item["new"] = clip(content, 2500) }
        if let edits = input["edits"] as? [[String: Any]], !edits.isEmpty {
            item["old"] = clip(edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n⋯\n"), 2500)
            item["new"] = clip(edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n⋯\n"), 2500)
        }
        if let todos = input["todos"] as? [[String: Any]] {
            item["todos"] = todos.prefix(12).map { ["text": $0["content"] ?? "", "status": $0["status"] ?? ""] }
        }
        return item
    }

    static func action(for name: String) -> String {
        switch name {
        case "Read", "NotebookRead": return "read"
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch": return "edit"
        case "Write": return "write"
        case "Bash", "BashOutput", "KillShell", "shell", "exec_command", "local_shell": return "run"
        case "Grep", "Glob", "LS", "ToolSearch": return "search"
        case "WebFetch", "WebSearch", "web_search": return "web"
        case "Task", "Agent": return "agent"
        case "TodoWrite", "update_plan": return "todo"
        default: return "other"
        }
    }

}
#endif
