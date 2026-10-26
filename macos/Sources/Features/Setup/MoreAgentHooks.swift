#if os(macOS)
import Foundation

/// Live status for agents beyond Claude Code and Codex. Each has its own hook format and
/// config file; all of them run the same observer, `agent-event.py <agent> <event>`, which
/// never approves, blocks or changes anything.
///
/// Where the agent reads a folder of hook files, Tellurion writes a file of its own
/// there. Where hooks share a settings file with the user's, only our entries are added
/// or removed, and the file is backed up first. OpenCode and Amp take a plugin instead.
enum MoreAgent: String, CaseIterable, Identifiable {
    case copilot, droid, kiro, gemini, antigravity, cursor, opencode, qwen, kimi, goose, amp, mistral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copilot: return "Copilot CLI"
        case .droid: return "Droid"
        case .kiro: return "Kiro CLI"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity CLI"
        case .cursor: return "Cursor CLI"
        case .opencode: return "OpenCode"
        case .qwen: return "Qwen Code"
        case .kimi: return "Kimi Code"
        case .goose: return "Goose"
        case .amp: return "Amp"
        case .mistral: return "Mistral Vibe"
        }
    }

    /// The command that starts it, for finding whether it's installed.
    var commands: [String] {
        switch self {
        case .copilot: return ["copilot"]
        case .droid: return ["droid"]
        case .kiro: return ["kiro-cli"]
        case .gemini: return ["gemini"]
        case .antigravity: return ["agy"]
        case .cursor: return ["cursor-agent", "agent"]
        case .opencode: return ["opencode"]
        case .qwen: return ["qwen"]
        case .kimi: return ["kimi"]
        case .goose: return ["goose"]
        case .amp: return ["amp"]
        case .mistral: return ["vibe"]
        }
    }

    /// What it can report: not every agent says when it's waiting for permission.
    var reports: String {
        switch self {
        case .copilot, .droid, .gemini, .opencode, .qwen, .kimi: return "working, needs permission, done"
        case .kiro, .antigravity, .cursor, .goose, .amp: return "working and done (it doesn't report permission prompts)"
        case .mistral: return "working and done, from its first tool (it doesn't report prompts or permission)"
        }
    }

    /// The agent's own hook events, in the order they're written.
    var events: [(name: String, matcher: String?)] {
        switch self {
        case .copilot:
            return [("sessionStart", nil), ("userPromptSubmitted", nil), ("postToolUse", nil), ("notification", nil),
                    ("agentStop", nil), ("errorOccurred", nil), ("sessionEnd", nil)]
        case .droid:
            return [("SessionStart", nil), ("UserPromptSubmit", nil), ("PostToolUse", "*"), ("Notification", nil),
                    ("Stop", nil), ("SessionEnd", nil)]
        case .kiro:
            return [("SessionStart", nil), ("UserPromptSubmit", nil), ("PostToolUse", nil), ("Stop", nil), ("SessionEnd", nil)]
        case .gemini:
            return [("SessionStart", nil), ("BeforeAgent", nil), ("AfterTool", "*"), ("Notification", nil),
                    ("AfterAgent", nil), ("SessionEnd", nil)]
        case .antigravity:
            return [("PreInvocation", nil), ("PostToolUse", "*"), ("Stop", nil)]
        case .cursor:
            return [("sessionStart", nil), ("beforeSubmitPrompt", nil), ("postToolUse", nil), ("afterFileEdit", nil),
                    ("stop", nil), ("sessionEnd", nil)]
        case .qwen:
            return [("SessionStart", nil), ("UserPromptSubmit", nil), ("PostToolUse", "*"), ("Notification", nil),
                    ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil)]
        case .kimi:
            return [("SessionStart", nil), ("UserPromptSubmit", nil), ("PostToolUse", nil), ("PermissionRequest", nil),
                    ("PermissionResult", nil), ("Stop", nil), ("StopFailure", nil), ("Interrupt", nil), ("SessionEnd", nil)]
        case .goose:
            return [("SessionStart", nil), ("UserPromptSubmit", nil), ("PostToolUse", nil), ("Stop", nil), ("SessionEnd", nil)]
        case .mistral:
            return [("post_tool", nil), ("post_agent", nil)]
        case .opencode, .amp:
            return []
        }
    }

    /// The file its hooks go in.
    func file(home: String) -> URL {
        let path: String
        switch self {
        case .copilot: path = "/.copilot/hooks/ghostty-extreme.json"
        case .droid:
            // A hooks.json replaces the settings file's hooks, so never create one.
            path = FileManager.default.fileExists(atPath: home + "/.factory/hooks.json") ? "/.factory/hooks.json" : "/.factory/settings.json"
        case .kiro: path = "/.kiro/hooks/ghostty-extreme.json"
        case .gemini: path = "/.gemini/settings.json"
        case .antigravity: path = "/.gemini/config/hooks.json"
        case .cursor: path = "/.cursor/hooks.json"
        case .opencode: path = "/.config/opencode/plugins/ghostty-extreme.js"
        case .qwen: path = "/.qwen/settings.json"
        case .kimi:
            // Kimi Code moved its folder from ~/.kimi; it migrates the old one itself.
            let fm = FileManager.default
            path = fm.fileExists(atPath: home + "/.kimi") && !fm.fileExists(atPath: home + "/.kimi-code")
                ? "/.kimi/config.toml" : "/.kimi-code/config.toml"
        case .goose: path = "/.agents/plugins/tellurion/hooks/hooks.json"
        case .amp: path = "/.config/amp/plugins/tellurion.ts"
        case .mistral: path = "/.vibe/hooks.toml"
        }
        return URL(fileURLWithPath: home + path)
    }

    /// The whole file is ours (deleted to disconnect), rather than entries in a shared one.
    var ownsFile: Bool { [.copilot, .kiro, .opencode, .goose, .amp].contains(self) }

    /// A plugin file copied as is from the app, instead of hook entries.
    var plugin: String? {
        switch self {
        case .opencode: return "opencode-plugin.js"
        case .amp: return "amp-plugin.ts"
        default: return nil
        }
    }

    /// Its hooks live in a TOML file shared with its other settings.
    var isTOML: Bool { self == .kimi || self == .mistral }

    /// Signs of it on this Mac, besides its command.
    func isPresent(home: String, tools: [String: String]) -> Bool {
        if commands.contains(where: { tools[$0] != nil }) { return true }
        switch self {
        case .copilot: return FileManager.default.fileExists(atPath: home + "/.copilot")
        case .droid: return FileManager.default.fileExists(atPath: home + "/.factory")
        case .kiro: return FileManager.default.fileExists(atPath: home + "/.kiro")
        case .antigravity: return FileManager.default.fileExists(atPath: home + "/.gemini/antigravity-cli")
        case .qwen: return FileManager.default.fileExists(atPath: home + "/.qwen")
        case .kimi: return FileManager.default.fileExists(atPath: home + "/.kimi-code") || FileManager.default.fileExists(atPath: home + "/.kimi")
        case .goose: return FileManager.default.fileExists(atPath: home + "/.config/goose")
        case .amp: return FileManager.default.fileExists(atPath: home + "/.config/amp")
        case .mistral: return FileManager.default.fileExists(atPath: home + "/.vibe")
        // Cursor's and Gemini's folders also belong to their apps; only the CLI counts.
        case .gemini, .cursor, .opencode: return false
        }
    }

    func command(script: String, event: String) -> String {
        "\(script) \(rawValue) \(event)"
    }

    fileprivate func isOurs(_ command: String) -> Bool {
        command.contains("agent-event.py \(rawValue) ")
    }
}

/// Pure merging, so it can be checked on its own (like `HookConfig`).
enum MoreAgentConfig {
    /// The config with our hooks in it.
    /// `eventsAtTop`: the file keeps events at its top level instead of under "hooks"
    /// (Droid's hooks.json).
    static func connected(_ agent: MoreAgent, config: [String: Any], script: String, eventsAtTop: Bool = false) -> [String: Any] {
        let config = disconnected(agent, config: config, eventsAtTop: eventsAtTop)
        switch agent {
        case .copilot:
            var hooks: [String: Any] = [:]
            for event in agent.events {
                hooks[event.name] = [["type": "command", "bash": agent.command(script: script, event: event.name), "timeoutSec": 5]]
            }
            return ["version": 1, "hooks": hooks]
        case .kiro:
            return ["version": "v1", "hooks": agent.events.map { event in
                ["name": "ghostty-extreme-\(event.name)", "trigger": event.name, "timeout": 5, "enabled": true,
                 "action": ["type": "command", "command": agent.command(script: script, event: event.name)]] as [String: Any]
            }]
        case .goose:
            var hooks: [String: Any] = [:]
            for event in agent.events {
                hooks[event.name] = [["hooks": [["type": "command", "command": agent.command(script: script, event: event.name)]]]]
            }
            return ["hooks": hooks]
        case .droid, .gemini, .qwen:
            let topLevel = eventsAtTop
            var hooks = topLevel ? config : config["hooks"] as? [String: Any] ?? [:]
            for event in agent.events {
                var handler: [String: Any] = ["type": "command", "command": agent.command(script: script, event: event.name)]
                // Gemini counts milliseconds; Qwen's unit isn't documented, so it keeps its default.
                if agent != .qwen { handler["timeout"] = agent == .gemini ? 5000 : 5 }
                if agent == .gemini { handler["name"] = "ghostty-extreme" }
                var groups = hooks[event.name] as? [[String: Any]] ?? []
                groups.append(["matcher": event.matcher ?? "", "hooks": [handler]])
                hooks[event.name] = groups
            }
            if topLevel { return hooks }
            var result = config
            result["hooks"] = hooks
            return result
        case .antigravity:
            var entry: [String: Any] = ["enabled": true]
            for event in agent.events {
                entry[event.name] = [["matcher": event.matcher ?? "", "hooks": [
                    ["type": "command", "command": agent.command(script: script, event: event.name), "timeout": 5],
                ]]]
            }
            var result = config
            result["ghostty-extreme"] = entry
            return result
        case .cursor:
            var result = config
            if result["version"] == nil { result["version"] = 1 }
            var hooks = result["hooks"] as? [String: Any] ?? [:]
            for event in agent.events {
                var list = hooks[event.name] as? [[String: Any]] ?? []
                list.append(["command": agent.command(script: script, event: event.name), "timeout": 5])
                hooks[event.name] = list
            }
            result["hooks"] = hooks
            return result
        case .opencode, .amp, .kimi, .mistral:
            return config
        }
    }

    /// The config without our hooks; everything else as it was.
    static func disconnected(_ agent: MoreAgent, config: [String: Any], eventsAtTop: Bool = false) -> [String: Any] {
        switch agent {
        case .copilot, .kiro, .opencode, .goose, .amp, .kimi, .mistral:
            return [:]
        case .antigravity:
            var result = config
            result.removeValue(forKey: "ghostty-extreme")
            return result
        case .cursor:
            var result = config
            guard var hooks = result["hooks"] as? [String: Any] else { return result }
            for (event, value) in hooks {
                let kept = (value as? [[String: Any]] ?? []).filter { !(($0["command"] as? String).map(agent.isOurs) ?? false) }
                if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
            }
            result["hooks"] = hooks
            return result
        case .droid, .gemini, .qwen:
            let topLevel = eventsAtTop
            var hooks = topLevel ? config : config["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                for index in groups.indices {
                    let handlers = groups[index]["hooks"] as? [[String: Any]] ?? []
                    groups[index]["hooks"] = handlers.filter { !(($0["command"] as? String).map(agent.isOurs) ?? false) }
                }
                groups.removeAll { ($0["hooks"] as? [[String: Any]])?.isEmpty == true }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if topLevel { return hooks }
            var result = config
            if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
            return result
        }
    }

    /// Whether every one of our hooks is in the config.
    static func isConnected(_ agent: MoreAgent, config: [String: Any]) -> Bool {
        let text = (try? JSONSerialization.data(withJSONObject: config)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        return agent.events.allSatisfy { text.contains("agent-event.py \(agent.rawValue) \($0.name)") }
    }
}

/// Kimi's and Mistral Vibe's hooks are `[[hooks]]` tables in a TOML file that also holds
/// the user's settings. Ours go in one marked block at the end, so taking them out never
/// touches anything else.
enum MoreAgentTOML {
    static let begin = "# >>> Tellurion agent status (added by Tellurion; remove in its Settings) >>>"
    static let end = "# <<< Tellurion agent status <<<"

    static func connected(_ agent: MoreAgent, text: String, script: String) -> String {
        var lines = [begin]
        for event in agent.events {
            let command = tomlString(agent.command(script: script, event: event.name))
            switch agent {
            case .kimi:
                lines += ["[[hooks]]", "event = \(tomlString(event.name))", "command = \(command)", "timeout = 5", ""]
            default:
                lines += ["[[hooks]]", "name = \(tomlString("tellurion-" + event.name))", "type = \(tomlString(event.name))",
                          "command = \(command)", ""]
            }
        }
        lines.removeLast()
        lines.append(end)
        var kept = disconnected(text)
        if !kept.isEmpty && !kept.hasSuffix("\n") { kept += "\n" }
        if !kept.isEmpty { kept += "\n" }
        return kept + lines.joined(separator: "\n") + "\n"
    }

    static func disconnected(_ text: String) -> String {
        guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return text }
        var before = String(text[..<start.lowerBound])
        var after = String(text[stop.upperBound...])
        if after.hasPrefix("\n") { after.removeFirst() }
        while before.hasSuffix("\n\n") { before.removeLast() }
        return before + after
    }

    static func isConnected(_ agent: MoreAgent, text: String) -> Bool {
        text.contains(begin) && agent.events.allSatisfy { text.contains("agent-event.py \(agent.rawValue) \($0.name)") }
    }

    /// A TOML basic string.
    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension HookInstaller {
    static var moreAgentScript: String { hooksFolder.appendingPathComponent("agent-event.py").path }

    static func isConnected(_ agent: MoreAgent) -> Bool {
        let url = agent.file(home: home)
        if agent.plugin != nil { return FileManager.default.fileExists(atPath: url.path) }
        if agent.isTOML {
            guard let data = FileManager.default.contents(atPath: url.path) else { return false }
            return MoreAgentTOML.isConnected(agent, text: (String(bytes: data, encoding: .utf8) ?? ""))
        }
        guard let config = try? readJSON(url) else { return false }
        return MoreAgentConfig.isConnected(agent, config: config)
    }

    /// Whether any of our hooks is in its file, even if some were taken out by hand.
    static func hasAnyHook(_ agent: MoreAgent) -> Bool {
        let url = agent.file(home: home)
        guard let data = FileManager.default.contents(atPath: url.path) else { return false }
        return agent.ownsFile || (String(bytes: data, encoding: .utf8) ?? "").contains("agent-event.py \(agent.rawValue) ")
    }

    static func connect(_ agent: MoreAgent) throws {
        if filesState() != .current { try installFiles() }
        let url = agent.file(home: home)
        if let plugin = agent.plugin {
            guard let source = bundled?.appendingPathComponent(plugin) else {
                throw Failure(message: "This build of Tellurion doesn't include the \(agent.title) plugin.")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: url, options: .atomic)
            return
        }
        if agent.isTOML {
            let text = FileManager.default.contents(atPath: url.path).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            try writeText(MoreAgentTOML.connected(agent, text: text, script: moreAgentScript), to: url)
            return
        }
        if agent == .goose {
            // A plugin folder of our own: its manifest, and the hooks beside it.
            let manifest = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plugin.json")
            try writeJSON(["name": "tellurion", "version": "1.0.0",
                           "description": "Live agent status for Tellurion's sidebar. Only observes."], to: manifest)
        }
        let config = agent.ownsFile ? [:] : try readJSON(url)
        try writeJSON(MoreAgentConfig.connected(agent, config: config, script: moreAgentScript,
                                                eventsAtTop: url.lastPathComponent == "hooks.json" && agent == .droid), to: url)
    }

    static func disconnect(_ agent: MoreAgent) throws {
        let url = agent.file(home: home)
        if agent == .goose {
            let folder = url.deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            return
        }
        if agent.ownsFile {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        if agent.isTOML {
            guard let data = FileManager.default.contents(atPath: url.path) else { return }
            try writeText(MoreAgentTOML.disconnected((String(bytes: data, encoding: .utf8) ?? "")), to: url)
            return
        }
        let config = try readJSON(url)
        try writeJSON(MoreAgentConfig.disconnected(agent, config: config,
                                                   eventsAtTop: url.lastPathComponent == "hooks.json" && agent == .droid), to: url)
    }

    /// The file's JSON, or an empty object when there's no file; throws when it isn't JSON
    /// we can safely rewrite.
    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "\(display(url)) isn't valid JSON (or has comments), so it was left alone.")
        }
        return object
    }

    /// Writes a text config the same way as a JSON one: through a symlink, backed up first.
    private static func writeText(_ text: String, to link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try backUp(url)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't update \(display(link)): \((error as NSError).localizedFailureReason ?? error.localizedDescription)")
        }
    }

    private static func writeJSON(_ config: [String: Any], to link: URL) throws {
        // A symlinked settings file (a dotfiles repo) stays a link: write to what it points at.
        let url = link.resolvingSymlinksInPath()
        do {
            try writeJSONFile(config, to: url)
        } catch {
            throw Failure(message: "Couldn't update \(display(link)): \((error as NSError).localizedFailureReason ?? error.localizedDescription)")
        }
    }

    private static func writeJSONFile(_ config: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backUp(url)
        var data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
#endif
