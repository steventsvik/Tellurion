#if os(macOS)
import Foundation

/// The agent hook entries Tellurion adds to Claude Code's `settings.json` and Codex's
/// `hooks.json`, and the line it adds to `~/.zshrc`.
///
/// Pure data in, data out: it never touches files itself (`HookInstaller` does), so the
/// merging can be checked on its own. Merging only adds or repoints our own handlers
/// (`agent-hook.sh <agent> <event>`); everything else in the file is left as it was.
enum HookConfig {
    enum Agent: String {
        case claude, codex
    }

    /// An agent hook event and the argument our script takes for it.
    struct Event {
        let name: String
        let argument: String
        let matcher: String?
    }

    static let claudeEvents: [Event] = [
        Event(name: "SessionStart", argument: "session_start", matcher: nil),
        Event(name: "UserPromptSubmit", argument: "prompt_submit", matcher: nil),
        Event(name: "PostToolUse", argument: "tool_complete", matcher: nil),
        Event(name: "PermissionRequest", argument: "permission_request", matcher: nil),
        Event(name: "Notification", argument: "notification", matcher: nil),
        Event(name: "Stop", argument: "stop", matcher: nil),
        Event(name: "StopFailure", argument: "stop_failure", matcher: nil),
        Event(name: "SessionEnd", argument: "session_end", matcher: nil),
        // Moves dev servers into localhost sessions.
        Event(name: "PreToolUse", argument: "pre_tool_use", matcher: "Bash"),
    ]

    static let codexEvents: [Event] = [
        Event(name: "SessionStart", argument: "session_start", matcher: nil),
        Event(name: "UserPromptSubmit", argument: "prompt_submit", matcher: nil),
        Event(name: "PreToolUse", argument: "pre_tool_use", matcher: "*"),
        Event(name: "PermissionRequest", argument: "permission_request", matcher: nil),
        Event(name: "PostToolUse", argument: "tool_complete", matcher: "*"),
        Event(name: "Stop", argument: "stop", matcher: nil),
        Event(name: "SessionEnd", argument: "session_end", matcher: nil),
        Event(name: "SubagentStart", argument: "subagent_start", matcher: nil),
        Event(name: "SubagentStop", argument: "subagent_stop", matcher: nil),
        Event(name: "Interrupt", argument: "interrupt", matcher: nil),
    ]

    static func events(for agent: Agent) -> [Event] {
        agent == .claude ? claudeEvents : codexEvents
    }

    /// Where the hooks are installed. Agents run them from here rather than from the repo:
    /// macOS privacy protection can block terminal processes from reading ~/Desktop or
    /// ~/Documents, which silently breaks every hook.
    static func hooksFolder(home: String) -> String { home + "/.ghostty-extreme/agent-hooks" }

    /// Before the rebrand the hooks lived here. Codex ties its hook approvals to the exact
    /// command, so a working legacy path is kept rather than replaced.
    static func legacyHooksFolder(home: String) -> String { home + "/.ghostty-custom/agent-hooks" }

    static func command(script: String, agent: Agent, event: Event) -> String {
        "\(script) \(agent.rawValue) \(event.argument)"
    }

    // MARK: State

    /// How one of our hook entries stands in an agent's config.
    enum EntryState: Equatable {
        case ok
        /// Not there.
        case missing
        /// There, but runs the script from somewhere other than the installed hooks folder
        /// (usually the repo itself).
        case elsewhere(String)
    }

    struct Report: Equatable {
        var entries: [String: EntryState] = [:]

        var missing: [String] { entries.filter { $0.value == .missing }.map(\.key).sorted() }
        var elsewhere: [String] {
            entries.compactMap { if case .elsewhere = $0.value { return $0.key } else { return nil } }.sorted()
        }
        var isComplete: Bool { entries.values.allSatisfy { $0 == .ok } }
        var isEmpty: Bool { entries.values.allSatisfy { $0 == .missing } }
    }

    /// Which of our entries `config` has, and whether they point at the installed hooks.
    static func report(_ config: [String: Any], agent: Agent, home: String) -> Report {
        let hooks = config["hooks"] as? [String: Any] ?? [:]
        var report = Report()
        for event in events(for: agent) {
            let commands = handlers(in: hooks[event.name]).compactMap { $0["command"] as? String }
            if let ours = commands.first(where: { isOurs($0, agent: agent, event: event) }) {
                let script = String(ours.dropLast(" \(agent.rawValue) \(event.argument)".count))
                report.entries[event.name] = isInstalledScript(script, home: home) ? .ok : .elsewhere(script)
            } else {
                report.entries[event.name] = .missing
            }
        }
        return report
    }

    // MARK: Merging

    struct Merge {
        var config: [String: Any]
        /// What changed, for the user: "Added Stop", "Repointed SessionStart".
        var changes: [String]
    }

    /// Adds the entries `config` is missing and repoints ones that run the script from
    /// somewhere else. Everything that isn't ours is kept as it was.
    static func merge(_ config: [String: Any], agent: Agent, home: String) -> Merge {
        var config = config
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        let script = preferredScript(hooks, agent: agent, home: home)
        var changes: [String] = []
        for event in events(for: agent) {
            var groups = hooks[event.name] as? [[String: Any]] ?? []
            var found = false
            for g in groups.indices {
                guard var handlers = groups[g]["hooks"] as? [[String: Any]] else { continue }
                for h in handlers.indices {
                    guard let command = handlers[h]["command"] as? String, isOurs(command, agent: agent, event: event) else { continue }
                    found = true
                    let current = String(command.dropLast(" \(agent.rawValue) \(event.argument)".count))
                    if !isInstalledScript(current, home: home) {
                        handlers[h]["command"] = self.command(script: script, agent: agent, event: event)
                        changes.append("Repointed \(event.name)")
                    }
                }
                groups[g]["hooks"] = handlers
            }
            if !found {
                var handler: [String: Any] = ["type": "command", "command": command(script: script, agent: agent, event: event)]
                handler["timeout"] = agent == .claude ? 5 : 3
                var group: [String: Any] = ["hooks": [handler]]
                if let matcher = event.matcher { group["matcher"] = matcher }
                groups.append(group)
                changes.append("Added \(event.name)")
            }
            hooks[event.name] = groups
        }
        config["hooks"] = hooks
        return Merge(config: config, changes: changes)
    }

    /// Takes out every entry of ours, and any group or event left empty by that.
    static func remove(_ config: [String: Any], agent: Agent) -> Merge {
        var config = config
        guard var hooks = config["hooks"] as? [String: Any] else { return Merge(config: config, changes: []) }
        var changes: [String] = []
        for event in events(for: agent) {
            guard var groups = hooks[event.name] as? [[String: Any]] else { continue }
            for g in groups.indices {
                guard let handlers = groups[g]["hooks"] as? [[String: Any]] else { continue }
                let kept = handlers.filter { handler in
                    !((handler["command"] as? String).map { isOurs($0, agent: agent, event: event) } ?? false)
                }
                if kept.count != handlers.count { changes.append("Removed \(event.name)") }
                groups[g]["hooks"] = kept
            }
            groups.removeAll { ($0["hooks"] as? [[String: Any]])?.isEmpty == true }
            if groups.isEmpty { hooks.removeValue(forKey: event.name) } else { hooks[event.name] = groups }
        }
        if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
        return Merge(config: config, changes: changes)
    }

    // MARK: Shell

    /// The line added to ~/.zshrc. It does nothing outside Tellurion.
    static let zshrcBlock = """

    # Tellurion: shows which coding agent each pane runs (does nothing in other terminals)
    [[ -n "$GHOSTTY_EXTREME_AGENT_EVENTS" ]] && source ~/.ghostty-extreme/agent-hooks/ghostty-extreme.zsh

    """

    static func zshrcHasIntegration(_ text: String) -> Bool {
        text.contains("ghostty-extreme.zsh") || text.contains("ghostty-custom.zsh")
    }

    /// The comment above the `source` line, as this and earlier versions wrote it.
    private static let zshrcComments = Set([
        "# Tellurion: shows which coding agent each pane runs (does nothing in other terminals)",
        "# GhosttyEXTREME: shows which coding agent each pane runs (does nothing in other terminals)",
    ].map(squeezed))

    /// The `source` line, with its spacing squeezed.
    private static let zshrcSource = squeezed(String(zshrcBlock.split(whereSeparator: \.isNewline).last ?? ""))

    /// `text` without our lines: the `source` line, the comment above it and the blank line
    /// the block starts with. Spacing doesn't matter (a re-indented or re-spaced block
    /// still goes), but any other wording stays: only lines we wrote are removed.
    static func zshrcRemovingIntegration(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            guard squeezed(lines[i]) == zshrcSource else {
                i += 1
                continue
            }
            var start = i
            if start > 0, zshrcComments.contains(squeezed(lines[start - 1])) { start -= 1 }
            if start > 0, squeezed(lines[start - 1]).isEmpty { start -= 1 }
            lines.removeSubrange(start...i)
            i = start
        }
        return lines.joined(separator: "\n")
    }

    /// Runs of spaces and tabs become one space, and the ends are trimmed.
    private static func squeezed(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Helpers

    private static func handlers(in groups: Any?) -> [[String: Any]] {
        (groups as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    /// `…/agent-hook.sh claude stop` for this agent and event, wherever the script is.
    private static func isOurs(_ command: String, agent: Agent, event: Event) -> Bool {
        command.hasSuffix("agent-hook.sh \(agent.rawValue) \(event.argument)")
    }

    private static func isInstalledScript(_ script: String, home: String) -> Bool {
        let expanded = script.hasPrefix("~/") ? home + script.dropFirst(1) : script
        return expanded == hooksFolder(home: home) + "/agent-hook.sh"
            || expanded == legacyHooksFolder(home: home) + "/agent-hook.sh"
    }

    /// The installed script, or the legacy one when the agent already runs that (for Codex,
    /// switching would throw away the user's hook approvals).
    private static func preferredScript(_ hooks: [String: Any], agent: Agent, home: String) -> String {
        let legacy = legacyHooksFolder(home: home) + "/agent-hook.sh"
        let usesLegacy = events(for: agent).contains { event in
            handlers(in: hooks[event.name]).contains { $0["command"] as? String == command(script: legacy, agent: agent, event: event) }
        }
        return usesLegacy ? legacy : hooksFolder(home: home) + "/agent-hook.sh"
    }
}
#endif
