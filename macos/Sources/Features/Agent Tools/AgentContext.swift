#if os(macOS)
import AppKit

/// What one agent knows that another needs: its task, the recent conversation, what it
/// changed, and commands that failed. Shared by handoffs, pipelines and "send to agent".
struct AgentContext {
    enum Part: String, CaseIterable, Identifiable {
        case conversation
        case changes
        case memory
        case failures

        var id: String { rawValue }

        var title: String {
            switch self {
            case .conversation: return "Conversation"
            case .changes: return "Changes"
            case .memory: return "Project notes"
            case .failures: return "Failed commands"
            }
        }

        var detail: String {
            switch self {
            case .conversation: return "The task and the last few messages"
            case .changes: return "What this agent changed, as a diff"
            case .memory: return "What this agent remembers about the project (see Project Memory)"
            case .failures: return "Commands that failed in this tab, with their output"
            }
        }
    }

    struct Turn {
        enum Role { case user, agent }
        let role: Role
        let text: String
    }

    let folder: String
    let agent: VerticalTabAgentKind?
    var task: String?
    var lastMessage: String?
    var conversation: [Turn] = []
    /// `git diff --stat` and the diff itself, from the agent's first turn (or HEAD).
    var changeSummary: String?
    var diff: String?
    /// "since Claude Code's first prompt here" or "uncommitted, against HEAD".
    var changeScope: String?
    var failures: [CommandBlock] = []
    /// What the agent remembers about the project, from `ProjectMemory`.
    var memory: String?

    /// Size limits, so a message stays something an agent can take in at once.
    private static let diffLimit = 24_000
    private static let turnLimit = 1_500
    private static let outputLimit = 3_000

    // MARK: Gathering

    /// Collects the parts from `surface` off the main thread, then calls back on it.
    static func gather(from surface: Ghostty.SurfaceView, parts: Set<Part>, completion: @escaping (AgentContext) -> Void) {
        let folder = surface.pwd ?? NSHomeDirectory()
        let info = VerticalTabsAgents.shared.info(for: surface)
        // The hooks can't report very long transcript paths (a terminal notification holds
        // 255 bytes); then look for the newest transcript for this folder.
        let transcriptPath = info?.transcriptPath
            ?? info.flatMap { AgentTranscripts.find(kind: $0.kind, folder: folder, recent: 24 * 3600) }
        let baseline = parts.contains(.changes) ? TurnCheckpoints.shared.list(for: surface).first { !$0.isRestorePoint } : nil
        let controller = surface.window?.windowController as? TerminalController
        let failures = parts.contains(.failures)
            ? (controller?.surfaceTree.flatMap { CommandBlocks.shared.blocks(for: $0) } ?? CommandBlocks.shared.blocks(for: surface))
                .filter(\.failed).sorted { $0.finished < $1.finished }.suffix(3)
            : []
        DispatchQueue.global(qos: .userInitiated).async {
            var context = AgentContext(folder: folder, agent: info?.kind, task: info?.task)
            context.lastMessage = AgentTools.lastAssistantMessage(transcript: transcriptPath)
            let turns = recentTurns(transcript: transcriptPath, limit: 6)
            // The hooks only report the first 48 characters of a prompt; the transcript has it all.
            if let prompt = turns.last(where: { $0.role == .user })?.text { context.task = prompt }
            if parts.contains(.conversation) { context.conversation = turns }
            if parts.contains(.changes) { context.readChanges(baseline: baseline) }
            if parts.contains(.memory), let kind = info?.kind {
                context.memory = ProjectMemory.sharedText(folder: folder, from: kind)
            }
            context.failures = Array(failures)
            DispatchQueue.main.async { completion(context) }
        }
    }

    /// The diff since the agent's first turn here, when there's a snapshot of it; otherwise
    /// the uncommitted changes.
    private mutating func readChanges(baseline: TurnCheckpoints.Checkpoint?) {
        if let baseline, let current = ReviewInbox.snapshot(baseline.repoRoot, gitDir: baseline.gitDir) {
            let who = baseline.agent?.displayName ?? "the agent"
            changeScope = "since \(who)'s first prompt here, \(Self.relative(baseline.time))"
            changeSummary = ReviewInbox.git(["diff"] + AgentTools.diffGuards + ["--stat", baseline.tree, current], in: baseline.repoRoot, gitDir: baseline.gitDir)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            diff = ReviewInbox.git(["diff"] + AgentTools.diffGuards + [baseline.tree, current], in: baseline.repoRoot, gitDir: baseline.gitDir).output
        } else if AgentTools.repoRoot(of: folder) != nil {
            changeScope = "uncommitted, against the last commit"
            changeSummary = AgentTools.git(["diff"] + AgentTools.diffGuards + ["--stat", "HEAD"], in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines)
            diff = AgentTools.git(["diff"] + AgentTools.diffGuards + ["HEAD"], in: folder).output
            // New files aren't in `git diff HEAD` until they're added.
            let untracked = AgentTools.git(["ls-files", "--others", "--exclude-standard"], in: folder).output
                .split(separator: "\n").prefix(20)
            if !untracked.isEmpty {
                changeSummary = (changeSummary ?? "") + "\nNew files: " + untracked.joined(separator: ", ")
            }
        }
        if changeSummary?.isEmpty == true { changeSummary = nil }
        if diff?.isEmpty == true { diff = nil }
    }

    // MARK: Writing it out

    /// The context as Markdown sections, for the start of a message.
    func render() -> String {
        var sections: [String] = []
        // The task is the latest prompt, then what came before it, then the agent's reply to it.
        let lastPrompt = conversation.lastIndex { $0.role == .user }
        let before = lastPrompt.map { Array(conversation[..<$0]) } ?? []
        let after = lastPrompt.map { Array(conversation[($0 + 1)...]) } ?? conversation
        let name = agent?.displayName ?? "The agent"
        if let task, !task.isEmpty { sections.append("## Task\n\n\(AgentTools.clip(task, 4000))") }
        if !before.isEmpty {
            let turns = before.map { turn in
                "**\(turn.role == .user ? "User" : name):** \(AgentTools.clip(turn.text, Self.turnLimit))"
            }
            sections.append("## Earlier conversation\n\n" + turns.joined(separator: "\n\n"))
        }
        let reply = after.filter { $0.role == .agent }.map(\.text).joined(separator: "\n\n")
        if !reply.isEmpty {
            sections.append("## \(name)'s reply\n\n\(AgentTools.clip(reply, 4000))")
        } else if let lastMessage, !lastMessage.isEmpty {
            sections.append("## \(name)'s last message\n\n\(AgentTools.clip(lastMessage, 4000))")
        }
        if let memory {
            sections.append("## What \(name) remembers about this project\n\n" +
                            "Notes it kept from earlier sessions; they can be out of date.\n\n\(memory)")
        }
        if let changeSummary {
            var block = "## Changes (\(changeScope ?? "uncommitted"))\n\n```\n\(changeSummary)\n```"
            if let diff {
                let clipped = diff.count > Self.diffLimit
                block += "\n\n```diff\n\(clipped ? String(diff.prefix(Self.diffLimit)) : diff)\n```"
                if clipped { block += "\n(The diff is cut; run `git diff` for the rest.)" }
            }
            sections.append(block)
        }
        for block in failures {
            let lines = block.output.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = AgentTools.clip(lines.suffix(80).joined(separator: "\n"), Self.outputLimit)
            sections.append("## Failed command\n\n$ \(block.command)\n\nExit code \(block.exitCode ?? 1)" +
                            (block.cwd.map { " in \($0)" } ?? "") + ":\n\n```\n\(tail)\n```")
        }
        return sections.joined(separator: "\n\n")
    }

    var isEmpty: Bool {
        (task ?? "").isEmpty && conversation.isEmpty && (lastMessage ?? "").isEmpty && changeSummary == nil && failures.isEmpty && memory == nil
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Transcripts

    /// The last few prompts and replies from a Claude Code or Codex transcript (tool calls
    /// and their output left out).
    static func recentTurns(transcript path: String?, limit: Int) -> [Turn] {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 1_500_000 ? size - 1_500_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var turns: [Turn] = []
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let turn = claudeTurn(record) ?? codexTurn(record) {
                // Replies come in pieces; keep consecutive ones together.
                if let last = turns.last, last.role == turn.role, turn.role == .agent {
                    turns[turns.count - 1] = Turn(role: .agent, text: last.text + "\n\n" + turn.text)
                } else {
                    turns.append(turn)
                }
            }
        }
        return Array(turns.suffix(limit))
    }

    private static func claudeTurn(_ record: [String: Any]) -> Turn? {
        guard let type = record["type"] as? String, type == "user" || type == "assistant",
              record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return nil }
        var text = ""
        if let content = message["content"] as? String {
            text = content
        } else if let parts = message["content"] as? [[String: Any]] {
            // Tool results also arrive as "user" records; only real text counts.
            text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        text = stripPasteTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands and system notes aren't part of the conversation.
        guard !text.isEmpty, !text.hasPrefix("<command-"), !text.hasPrefix("<local-command"), !text.hasPrefix("<system-reminder>"),
              !text.hasPrefix("Caveat:") else { return nil }
        return Turn(role: type == "user" ? .user : .agent, text: text)
    }

    /// Claude Code records pasted text wrapped in `<pasted_content id="…">` tags.
    private static func stripPasteTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
    }

    private static func codexTurn(_ record: [String: Any]) -> Turn? {
        guard let payload = record["payload"] as? [String: Any], payload["type"] as? String == "message",
              let role = payload["role"] as? String, role == "user" || role == "assistant" else { return nil }
        let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<environment_context>"), !text.hasPrefix("<user_instructions>"),
              !text.hasPrefix("# AGENTS.md") else { return nil }
        return Turn(role: role == "user" ? .user : .agent, text: text)
    }
}
#endif
