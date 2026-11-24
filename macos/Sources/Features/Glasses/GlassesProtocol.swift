#if os(macOS)
import CryptoKit
import Foundation

/// One agent as the glasses see it: who it is, what it's doing and what it's waiting on.
/// Plain values, so the message built from them can be tested without a window.
struct GlassesAgent: Equatable {
    struct Check: Equatable {
        /// "running", "passed" or "failed".
        var state: String
        var summary: String
    }

    struct Budget: Equatable {
        var fraction: Double
        /// "ok", "warning", "reached" or "paused".
        var state: String
    }

    /// The pane's id.
    var id: UUID
    /// The tab's or tile's name, or the agent's.
    var name: String
    var kind: String
    var activity: VerticalTabAgentActivity
    /// Finished or blocked, and not looked at yet.
    var unseen = false
    var task: String?
    /// What it's waiting on: the command or the question.
    var detail: String?
    /// When `activity` last changed.
    var since: Date
    var project: String?
    var check: Check?
    var budget: Budget?
    var conflicts = 0
    /// Wired to an orchestrator.
    var wired = false
    /// False for a pane with a plain shell and no agent in it.
    var isAgent = true
    /// The agent's name as the sidebar shows it ("Claude Code").
    var agentName: String?
    /// The project the pane's folder is in, for grouping.
    var group: GlassesProject?
}

/// A project as the glasses know it: never its real path.
struct GlassesProject: Equatable {
    /// The same id its orchestrator goes by (see `GlassesProjects.id`).
    var id: String
    var name: String
    /// The folder with the home folder written as "~".
    var path: String
}

enum GlassesProjects {
    /// A project's id on the wire: a hash of its folder, not the folder.
    static func id(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A path with the home folder written as "~".
    static func shortPath(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func project(root: String, name: String, home: String) -> GlassesProject {
        GlassesProject(id: id(root), name: root == home ? "Home" : name, path: shortPath(root, home: home))
    }
}

/// The order tabs are in: each window's tabs left to right, windows in the order given.
enum GlassesOrder {
    /// `tabs` gives a window's whole tab group in its order, or nil for a window by itself.
    static func tabOrder<ID: Hashable>(_ windows: [ID], tabs: (ID) -> [ID]?) -> [ID] {
        var seen: Set<ID> = []
        var ordered: [ID] = []
        for window in windows where !seen.contains(window) {
            // Only tabs that are in the list: a closed tab can linger in its group.
            for tab in tabs(window) ?? [window] where windows.contains(tab) && seen.insert(tab).inserted {
                ordered.append(tab)
            }
            if seen.insert(window).inserted { ordered.append(window) }
        }
        return ordered
    }
}

/// The `agents` message: every agent, the ones that need you first.
enum GlassesAgents {
    static let taskLength = 120
    static let detailLength = 200
    static let nameLength = 40
    static let summaryLength = 80

    static func activity(_ activity: VerticalTabAgentActivity) -> String {
        switch activity {
        case .ready: return "ready"
        case .working: return "working"
        case .needsPermission: return "permission"
        case .needsInput: return "input"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// The mark the glasses' sidebar gives a state, for rows written here.
    static func glyph(_ activity: VerticalTabAgentActivity, unseen: Bool = false) -> String {
        switch activity {
        case .needsPermission: return "●"
        case .needsInput: return "○"
        case .failed: return "▲"
        case .done: return unseen ? "★" : "☆"
        case .working: return "▶"
        case .ready: return "□"
        }
    }

    /// Where an agent sorts: permission, input, failed, finished and not seen, working, the rest.
    static func rank(_ agent: GlassesAgent) -> Int {
        switch agent.activity {
        case .needsPermission: return 0
        case .needsInput: return 1
        case .failed: return 2
        case .done: return agent.unseen ? 3 : 5
        case .working: return 4
        case .ready: return 6
        }
    }

    /// Sorted by rank; within one, the longest in that state first.
    static func ordered(_ agents: [GlassesAgent]) -> [GlassesAgent] {
        agents.enumerated().sorted { a, b in
            let (x, y) = (rank(a.element), rank(b.element))
            if x != y { return x < y }
            if a.element.since != b.element.since { return a.element.since < b.element.since }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    /// Which prompt an agent is showing: changes when it asks for something else, or asks
    /// again. An answer has to carry it back, so a tap meant for one command can't allow another.
    static func promptIdentity(_ agent: GlassesAgent) -> String? {
        guard agent.isAgent, agent.activity == .needsPermission else { return nil }
        let text = "\(agent.id.uuidString)\n\(agent.since.timeIntervalSince1970)\n\(agent.detail ?? "")"
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// One line, no control characters, at most `length` characters.
    static func clip(_ text: String, _ length: Int) -> String {
        let scalars = text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) }
        let line = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return line.count > length ? String(line.prefix(length - 1)) + "…" : line
    }

    /// Names as they're shown and spoken: two alike become "Ada" and "Ada 2".
    static func names(_ agents: [GlassesAgent]) -> [String] {
        var seen: [String: Int] = [:]
        return agents.map { agent in
            let base = clip(agent.name, nameLength)
            let n = (seen[base.lowercased()] ?? 0) + 1
            seen[base.lowercased()] = n
            return n == 1 ? base : "\(base) \(n)"
        }
    }

    /// Panes with their projects together, as the sidebar brackets them: projects in the
    /// order their first pane comes, panes in the order given within each, and the ones
    /// with no project last.
    static func grouped(_ panes: [GlassesAgent]) -> [GlassesAgent] {
        var order: [String] = []
        var members: [String: [GlassesAgent]] = [:]
        for pane in panes {
            let key = pane.group?.id ?? ""
            if members[key] == nil, !key.isEmpty { order.append(key) }
            members[key, default: []].append(pane)
        }
        return order.flatMap { members[$0] ?? [] } + (members[""] ?? [])
    }

    /// The message's content, without the clock (so an unchanged list gives the same text).
    /// Version 1: only the agents, the ones that need you first. Version 2: every pane, a
    /// plain terminal too, in the app's own order with its project.
    static func message(_ unordered: [GlassesAgent], version: Int = 1) -> [String: Any] {
        let agents = version >= 2 ? grouped(unordered) : ordered(unordered.filter(\.isAgent))
        let names = names(agents)
        let list: [[String: Any]] = zip(agents, names).map { agent, name in
            var item: [String: Any] = [
                "id": agent.id.uuidString,
                "name": name,
                "kind": agent.kind,
                "act": agent.isAgent ? activity(agent.activity) : "none",
                "since": Int(agent.since.timeIntervalSince1970),
            ]
            if version >= 2 {
                item["agent"] = agent.isAgent
                if let agentName = agent.agentName, !agentName.isEmpty { item["agentName"] = clip(agentName, nameLength) }
                if let group = agent.group {
                    item["proj"] = ["id": group.id, "name": clip(group.name, nameLength), "path": clip(group.path, detailLength)]
                }
            }
            if agent.unseen { item["unseen"] = true }
            if let task = agent.task, !task.isEmpty { item["task"] = clip(task, taskLength) }
            if let detail = agent.detail, !detail.isEmpty { item["detail"] = clip(detail, detailLength) }
            if let project = agent.project, !project.isEmpty { item["project"] = clip(project, nameLength) }
            if let check = agent.check { item["check"] = ["s": check.state, "sum": clip(check.summary, summaryLength)] }
            if let budget = agent.budget { item["budget"] = ["f": (budget.fraction * 100).rounded() / 100, "s": budget.state] }
            if agent.conflicts > 0 { item["conflicts"] = agent.conflicts }
            if agent.wired { item["wired"] = true }
            if let prompt = promptIdentity(agent) { item["prompt"] = prompt }
            return item
        }
        let needs = agents.filter { $0.isAgent && ($0.activity == .needsPermission || $0.activity == .needsInput) }.count
        return version >= 2 ? ["t": "agents", "v": 2, "agents": list, "needs": needs] : ["t": "agents", "agents": list, "needs": needs]
    }
}

/// What may and may not be done for the glasses, as plain checks.
enum GlassesRules {
    /// Why a permission answer isn't sent, or nil when it may be: the agent has to be
    /// showing the very prompt the glasses saw.
    static func answerRefusal(agent: GlassesAgent?, prompt: String) -> String? {
        guard let agent else { return "That agent is gone." }
        guard let current = GlassesAgents.promptIdentity(agent) else { return "It isn't waiting for permission any more." }
        guard PhoneDevices.equal(current, prompt) else { return "It's asking for something else now. Look again." }
        return nil
    }

    /// Why text isn't delivered, or nil when it may be. Never into a pane with no agent:
    /// there it would run as a command.
    static func sayRefusal(hasAgent: Bool, text: String) -> String? {
        guard hasAgent else { return "No agent is running there. Nothing was typed." }
        guard AgentTools.typedLine(text) != nil else { return "That text has characters that can't be typed." }
        return nil
    }

    /// Why a key isn't pressed, or nil when it may be. A key is typing: never into a pane
    /// with no agent (Enter there would run whatever is on the shell's line), and never
    /// while the agent shows a permission prompt, which is only answered as that prompt.
    static func keyRefusal(hasAgent: Bool, waitingForPermission: Bool, key: GlassesKey) -> String? {
        guard hasAgent else { return "No agent is running there. Nothing was pressed." }
        guard !waitingForPermission else { return "It's asking for permission. Answer that instead." }
        return nil
    }
}

/// The only keys the glasses may press in an agent's pane.
enum GlassesKey: String, CaseIterable {
    case enter, escape, up, down, tab, y, n
    case interrupt = "ctrl-c"

    /// What it's called in the reply.
    var label: String {
        switch self {
        case .enter: return "Enter"
        case .escape: return "Esc"
        case .up: return "Up"
        case .down: return "Down"
        case .tab: return "Tab"
        case .y: return "y"
        case .n: return "n"
        case .interrupt: return "Ctrl-C"
        }
    }
}

/// A message from the glasses, checked.
enum GlassesRequest: Equatable {
    case glance(Bool)
    case orchestrators(Bool)
    case tail(id: UUID, lines: Int)
    /// The pane's screen as it is, `before` lines back from its end.
    case screen(id: UUID, lines: Int, before: Int)
    case untail
    case tools(Bool)
    case key(id: UUID, key: GlassesKey)
    /// Open a tool's window on the Mac.
    case tool(GlassesTool)
    /// The tool whose page is open, or nil when none is.
    case toolPage(GlassesTool?)
    case toolAction(tool: GlassesTool, row: String, action: GlassesToolAction, text: String?)
    case orchestratorAction(id: String, action: GlassesOrchestratorAction)
    case answer(id: UUID, allow: Bool, prompt: String)
    case say(id: UUID, text: String)
    case orchestratorCommand(id: String, text: String)
    case listen
    case heard
    case unlisten

    enum Parsed: Equatable {
        case request(GlassesRequest)
        /// One of ours, but not acceptable; the reason goes back.
        case invalid(String)
        /// Not a glasses message.
        case unknown
    }

    static let maxText = 2000
    static let maxLines = 60
    /// How far back the screen can be read, in lines.
    static let maxBefore = 5000

    static func parse(_ message: [String: Any]) -> Parsed {
        guard let type = message["t"] as? String else { return .unknown }
        func pane() -> UUID? {
            guard let text = message["id"] as? String, text.count == 36 else { return nil }
            return UUID(uuidString: text)
        }
        /// Trimmed, not empty and not too long. Control characters are refused where it's delivered.
        func text() -> String? {
            guard let raw = message["text"] as? String, raw.utf8.count <= maxText * 4 else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > maxText ? nil : trimmed
        }
        switch type {
        case "glance": return .request(.glance(true))
        case "unglance": return .request(.glance(false))
        case "orch": return .request(.orchestrators(true))
        case "unorch": return .request(.orchestrators(false))
        case "untail": return .request(.untail)
        case "listen": return .request(.listen)
        case "heard?": return .request(.heard)
        case "unlisten": return .request(.unlisten)
        case "tail":
            guard let id = pane() else { return .invalid("Which agent?") }
            let lines = message["lines"] as? Int ?? 12
            guard (1...maxLines).contains(lines) else { return .invalid("Too many lines.") }
            guard message["src"] as? String == "screen" else { return .request(.tail(id: id, lines: lines)) }
            let before = message["before"] as? Int ?? 0
            guard (0...maxBefore).contains(before) else { return .invalid("That's too far back.") }
            return .request(.screen(id: id, lines: lines, before: before))
        case "tools": return .request(.tools(true))
        case "untools": return .request(.tools(false))
        case "untoolpage": return .request(.toolPage(nil))
        case "tool", "toolpage":
            // Only a tool from the list, by its own name.
            guard let name = message["id"] as? String, let tool = GlassesTool(rawValue: name) else { return .invalid("That isn't one of the tools.") }
            if type == "toolpage" {
                guard tool.hasPage else { return .invalid("That tool opens on your Mac.") }
                return .request(.toolPage(tool))
            }
            guard tool.opensOnMac else { return .invalid("That tool has no window to open.") }
            return .request(.tool(tool))
        case "toolact":
            guard let name = message["tool"] as? String, let tool = GlassesTool(rawValue: name),
                  let wanted = message["action"] as? String, let action = GlassesToolAction(rawValue: wanted), tool.actions.contains(action) else {
                return .invalid("That can't be done from here.")
            }
            let row = message["row"] as? String ?? ""
            guard row.count <= 80, row.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else { return .invalid("Which one?") }
            guard action.takesText else { return .request(.toolAction(tool: tool, row: row, action: action, text: nil)) }
            guard let text = text() else { return .invalid("Nothing was said, or too much.") }
            return .request(.toolAction(tool: tool, row: row, action: action, text: text))
        case "orchstop", "orchgo", "orchwire", "orchclear":
            guard let id = message["id"] as? String, (1...64).contains(id.count), let action = GlassesOrchestratorAction(rawValue: type) else {
                return .invalid("Which project?")
            }
            return .request(.orchestratorAction(id: id, action: action))
        case "key":
            guard let id = pane() else { return .invalid("Which agent?") }
            guard let name = message["key"] as? String, let key = GlassesKey(rawValue: name) else { return .invalid("That key can't be pressed from here.") }
            return .request(.key(id: id, key: key))
        case "answer":
            guard let id = pane(), let allow = message["allow"] as? Bool,
                  let prompt = message["prompt"] as? String, (1...64).contains(prompt.count) else {
                return .invalid("That answer is missing something.")
            }
            return .request(.answer(id: id, allow: allow, prompt: prompt))
        case "say":
            guard let id = pane() else { return .invalid("Which agent?") }
            guard let text = text() else { return .invalid("Nothing to send, or too much.") }
            return .request(.say(id: id, text: text))
        case "orchcmd":
            guard let id = message["id"] as? String, (1...64).contains(id.count) else { return .invalid("Which project?") }
            guard let text = text() else { return .invalid("Nothing to send, or too much.") }
            return .request(.orchestratorCommand(id: id, text: text))
        default:
            return .unknown
        }
    }
}

/// Plain text for the small display.
enum GlassesText {
    static let tailLimit = 1800

    /// The last `lines` lines that aren't empty, without trailing spaces or control
    /// characters, cut from the front to fit `limit` characters.
    static func tail(_ text: String, lines count: Int, limit: Int = tailLimit) -> String {
        let lines = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .control }))
            let trimmed = plain.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return trimmed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : trimmed
        }
        let joined = lines.suffix(max(count, 0)).joined(separator: "\n")
        return joined.count > limit ? String(joined.suffix(limit)) : joined
    }

    /// A terminal's screen as it is: `count` lines ending `before` lines above its last
    /// one, each as the terminal shows it without trailing spaces or control characters.
    /// Runs of empty lines become one and the empty ones at the end are dropped. Cut from
    /// the top, at a line, to fit `limit` characters. `more`: whether there are lines above.
    static func screen(_ text: String, lines count: Int, before: Int = 0, limit: Int = tailLimit) -> (text: String, more: Bool) {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let plain = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .control }))
            let trimmed = plain.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed)
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        let end = max(0, lines.count - max(before, 0))
        let start = max(0, end - max(count, 0))
        guard end > start else { return ("", false) }
        // As many whole lines as fit, counted up from the last one.
        var first = end
        var used = 0
        while first > start {
            let cost = lines[first - 1].count + (first == end ? 0 : 1)
            if used + cost > limit { break }
            used += cost
            first -= 1
        }
        // One line too long by itself: its end.
        if first == end { return (String(lines[end - 1].suffix(limit)), end > 1) }
        return (lines[first..<end].joined(separator: "\n"), first > 0)
    }
}

/// The Tools row: what the Mac's sidebar and tools show that fits a few lines. Plain
/// values in, so the message can be tested without the app.
struct GlassesTools: Equatable {
    struct Window: Equatable {
        var label: String
        var percent: Double
        var resets: Date?
    }

    struct Usage: Equatable {
        var name: String
        var windows: [Window]
    }

    struct Server: Equatable {
        var name: String
        /// "localhost:5173": where it listens, without the scheme.
        var address: String
        var project: String?
    }

    struct Budget: Equatable {
        var name: String
        var fraction: Double
    }

    var usage: [Usage] = []
    var servers: [Server] = []
    /// Changes waiting in the review inbox.
    var review = 0
    /// The panes whose check failed, by name.
    var failedChecks: [String] = []
    var budgets: [Budget] = []
    var conflicts = 0

    /// A budget is worth a line from here on.
    static let budgetFloor = 0.8
    static let most = 8

    func message(now: Date = Date()) -> [String: Any] {
        let usage: [[String: Any]] = usage.prefix(4).map { entry in
            let windows: [[String: Any]] = entry.windows.prefix(4).map { window in
                // A window that has reset is unused until new numbers arrive.
                let passed = window.resets.map { $0 <= now } ?? false
                var item: [String: Any] = ["label": GlassesAgents.clip(window.label, 8),
                                           "pct": passed ? 0 : Int(max(0, window.percent).rounded())]
                if let resets = window.resets, !passed { item["resets"] = Int(resets.timeIntervalSince1970) }
                return item
            }
            return ["name": GlassesAgents.clip(entry.name, 24), "windows": windows]
        }
        let servers: [[String: Any]] = servers.prefix(Self.most).map { server in
            var item: [String: Any] = ["name": GlassesAgents.clip(server.name, 24), "url": GlassesAgents.clip(server.address, 60)]
            if let project = server.project { item["proj"] = project }
            return item
        }
        let budgets: [[String: Any]] = budgets.filter { $0.fraction >= Self.budgetFloor }.prefix(Self.most).map {
            ["name": GlassesAgents.clip($0.name, 24), "pct": Int(($0.fraction * 100).rounded())]
        }
        return [
            "t": "tools", "usage": usage, "servers": servers, "review": max(0, review),
            "checks": failedChecks.prefix(Self.most).map { GlassesAgents.clip($0, 24) },
            "budgets": budgets, "conflicts": max(0, conflicts),
        ]
    }
}

/// So many at once, refilled evenly over a period: 30 actions a minute, or a minute's audio.
struct GlassesRateLimiter {
    let capacity: Double
    let period: TimeInterval
    private var tokens: Double
    private var updated: Date

    init(capacity: Double, per period: TimeInterval, now: Date = Date()) {
        self.capacity = capacity
        self.period = period
        tokens = capacity
        updated = now
    }

    /// Takes `cost` if there's that much left.
    mutating func allow(_ cost: Double = 1, now: Date = Date()) -> Bool {
        // A clock that steps back gives nothing, and isn't remembered.
        tokens = min(capacity, tokens + max(0, now.timeIntervalSince(updated)) * capacity / period)
        updated = max(updated, now)
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}

/// Where the glasses app reaches the server, and what it may do from another origin.
///
/// The app packaged for the glasses' menu runs from the Even app's own origin, not this
/// server's, so its paths answer any origin. That's safe to allow because a browser page
/// gets nothing from it without a device token; the phone's paths keep their own-origin rule.
enum GlassesRoutes {
    static let prefix = "/glasses/"
    static let socket = "/glasses/ws"
    static let api = "/glasses/api/"

    /// Whether a WebSocket may open on `path`. `phoneOriginOK`: the phone's own-origin check.
    static func acceptsSocket(path: String, phoneOriginOK: Bool, glassesOn: Bool) -> Bool {
        switch path {
        case "/api/ws": return phoneOriginOK
        case socket: return glassesOn
        default: return false
        }
    }

    /// The cross-origin headers for a path: only the glasses' own API gets any.
    static func corsHeaders(path: String) -> [String: String] {
        guard path.hasPrefix(api) else { return [:] }
        return [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Max-Age": "600",
        ]
    }

    /// Files under /glasses/ that are never served: the tests and the packaging helper.
    static func isHidden(path: String) -> Bool {
        path.hasPrefix("/glasses/test/") || path.hasPrefix("/glasses/pack/")
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif

#if os(macOS)
/// The Mac's tools as the glasses list them: the Tools panel's rows in its order and
/// sections, then the few that only live in the sidebar or the command palette. Each has
/// a page on the glasses, or opens its window on the Mac. This list is the only way a
/// tool is named from the glasses: anything else is turned away.
enum GlassesTool: String, CaseIterable {
    case editor, visualFix, commandHistory
    case mission, orchestrator, races, scoreboard, review, checks, activity, search, budgets, conflicts, worktrees
    case localhost, ports, skills, memory, environment
    case usage, background, phone, localModels
    case layout, design, settings
    case ruler

    var title: String {
        switch self {
        case .editor: return "Code editor"
        case .visualFix: return "Visual Fix"
        case .commandHistory: return "Command history"
        case .mission: return "Mission Control"
        case .orchestrator: return "Orchestrator"
        case .races: return "Agent races"
        case .scoreboard: return "Race scoreboard"
        case .review: return "Review changes"
        case .checks: return "Checks"
        case .activity: return "Agent activity"
        case .search: return "Search sessions"
        case .budgets: return "Budgets"
        case .conflicts: return "Conflicts"
        case .worktrees: return "Worktrees"
        case .localhost: return "Localhost"
        case .ports: return "Ports"
        case .skills: return "Skills"
        case .memory: return "Project memory"
        case .environment: return "Environment"
        case .usage: return "Usage"
        case .background: return "Background processes"
        case .phone: return "Phone"
        case .localModels: return "Local models"
        case .layout: return "Layout"
        case .design: return "Design"
        case .settings: return "Settings"
        case .ruler: return "Display check"
        }
    }

    var section: String {
        switch self {
        case .editor, .visualFix, .commandHistory: return "This tab"
        case .mission, .orchestrator, .races, .scoreboard, .review, .checks, .activity, .search, .budgets, .conflicts, .worktrees: return "Agents"
        case .localhost, .ports, .skills, .memory, .environment: return "Project"
        case .usage, .background, .phone, .localModels: return "This Mac"
        case .layout, .design, .settings: return "View"
        case .ruler: return "Glasses"
        }
    }

    /// The switch in Settings that has to be on for it to be listed; nil for the ones always there.
    var feature: TellurionFeature? {
        switch self {
        case .editor: return .editor
        case .visualFix: return .visualFix
        case .commandHistory: return .commandHistory
        case .mission: return .missionControl
        case .orchestrator: return .orchestrator
        case .races, .scoreboard: return .races
        case .review: return .review
        case .checks: return .checks
        case .activity: return .activity
        case .search: return .sessionSearch
        case .budgets: return .budgets
        case .conflicts, .worktrees: return .conflicts
        case .localhost: return .localhost
        case .ports: return .ports
        case .skills: return .skills
        case .memory: return .memory
        case .environment: return .environment
        case .usage: return .usage
        case .background: return .background
        case .phone: return .phone
        case .localModels: return .localModels
        case .layout, .design, .settings, .ruler: return nil
        }
    }

    /// Whether it has a page of its own on the glasses. The rest open on the Mac.
    var hasPage: Bool {
        switch self {
        case .mission, .orchestrator, .scoreboard, .review, .checks, .activity, .search, .budgets, .conflicts, .worktrees,
             .localhost, .ports, .usage, .background, .ruler:
            return true
        case .editor, .visualFix, .commandHistory, .races, .skills, .memory, .environment, .phone, .localModels, .layout, .design, .settings:
            return false
        }
    }

    /// Whether it has a window on the Mac to open. Some only live in the sidebar.
    var opensOnMac: Bool {
        switch self {
        case .conflicts, .ports, .usage, .ruler: return false
        default: return true
        }
    }

    /// What its page lets the glasses do, beyond looking.
    var actions: Set<GlassesToolAction> {
        switch self {
        case .review: return [.feedback, .open]
        case .checks: return [.run]
        case .budgets: return [.add, .remove]
        case .localhost: return [.stop, .restart]
        case .search: return [.query, .resume]
        default: return []
        }
    }

    /// The tools to list, in order: the ones whose switch is on.
    static func listed(isOn: (TellurionFeature) -> Bool) -> [GlassesTool] {
        allCases.filter { tool in tool.feature.map(isOn) ?? true }
    }
}

/// The few things a tool's page can be asked to do. Each changes something on the Mac, so
/// the glasses only send one from the tap that confirms it.
enum GlassesToolAction: String, CaseIterable {
    case open, feedback, run, add, remove, stop, restart, query, resume

    /// Whether it carries what was said.
    var takesText: Bool { self == .feedback || self == .query }
}

/// What an orchestrator can be told without a word: stop, carry on with its goal, wire
/// every agent of its project, clear its goal and log.
enum GlassesOrchestratorAction: String, CaseIterable {
    case stop = "orchstop", carryOn = "orchgo", wireAll = "orchwire", clear = "orchclear"
}

/// A tool's page: rows of one line each, a line more about each, and what can be done.
struct GlassesToolPage: Equatable {
    struct Action: Equatable {
        var action: GlassesToolAction
        var label: String
        /// The question the glasses ask before sending it.
        var ask: String
        /// Whom speech is for, when it's said rather than tapped.
        var name: String?
    }

    struct Row: Equatable {
        var id: String
        var text: String
        var sub = ""
        var bright = false
        /// Where a tap leads on the glasses: "p:<pane>" or "o:<project>".
        var open: String?
        var actions: [Action] = []
    }

    static let mostRows = 24
    static let textLength = 120
    static let subLength = 200

    var tool: GlassesTool
    var note = ""
    /// What holding to talk does on this page, and what the hint calls it.
    var voice: (action: GlassesToolAction, hint: String)?
    var rows: [Row] = []

    static func == (a: GlassesToolPage, b: GlassesToolPage) -> Bool {
        a.tool == b.tool && a.note == b.note && a.rows == b.rows && a.voice?.action == b.voice?.action && a.voice?.hint == b.voice?.hint
    }

    func message() -> [String: Any] {
        let rows: [[String: Any]] = rows.prefix(Self.mostRows).map { row in
            var item: [String: Any] = ["id": row.id, "text": GlassesAgents.clip(row.text, Self.textLength)]
            if !row.sub.isEmpty { item["sub"] = GlassesAgents.clip(row.sub, Self.subLength) }
            if row.bright { item["hi"] = true }
            if let open = row.open { item["open"] = open }
            // Only what this tool may be asked to do.
            let actions: [[String: Any]] = row.actions.filter { tool.actions.contains($0.action) }.map { action in
                var entry: [String: Any] = ["id": action.action.rawValue, "label": GlassesAgents.clip(action.label, 24),
                                            "ask": GlassesAgents.clip(action.ask, Self.textLength)]
                if action.action.takesText {
                    entry["voice"] = true
                    if let name = action.name { entry["name"] = GlassesAgents.clip(name, GlassesAgents.nameLength) }
                }
                return entry
            }
            if !actions.isEmpty { item["actions"] = actions }
            return item
        }
        var message: [String: Any] = ["t": "toolpage", "id": tool.rawValue, "title": tool.title, "rows": rows]
        if !note.isEmpty { message["note"] = GlassesAgents.clip(note, Self.subLength) }
        if let voice, tool.actions.contains(voice.action), voice.action.takesText {
            message["voice"] = ["action": voice.action.rawValue, "name": tool.title, "hint": GlassesAgents.clip(voice.hint, 16)]
        }
        return message
    }
}

/// The tools list as it's sent with the Tools row's numbers: each tool with its section,
/// whether it has a page, and a few words about it now.
enum GlassesToolList {
    static func items(_ tools: [GlassesTool], summaries: [GlassesTool: String] = [:], bright: Set<GlassesTool> = []) -> [[String: Any]] {
        tools.map { tool in
            var item: [String: Any] = ["id": tool.rawValue, "name": tool.title, "section": tool.section, "page": tool.hasPage]
            if let sum = summaries[tool], !sum.isEmpty { item["sum"] = GlassesAgents.clip(sum, 80) }
            if bright.contains(tool) { item["hi"] = true }
            return item
        }
    }
}

/// A project's orchestrator as the glasses' command centre shows it.
struct GlassesOrchestrator: Equatable {
    struct Member: Equatable {
        var id: UUID
        var name: String
        var role: String?
        /// "working", "permission"…; nil for a pane with no agent in it now.
        var activity: String?
        var detail: String?
    }

    static let mostMembers = 12
    static let logLines = 12

    var id: String
    var name: String
    var status: String
    var goal: String?
    /// Thinking, or following up by itself.
    var running = false
    var members: [Member] = []
    /// Its log, oldest first, each line already marked ("You: …", "! …").
    var log: [String] = []
    /// The last thing it said, and the last thing it did.
    var says: String?
    var last: String?

    func item() -> [String: Any] {
        var project: [String: Any] = [
            "id": id, "name": GlassesAgents.clip(name, GlassesAgents.nameLength), "status": status, "running": running,
            "log": log.suffix(Self.logLines).map { GlassesAgents.clip($0, 160) },
            "members": members.prefix(Self.mostMembers).map { member -> [String: Any] in
                var item: [String: Any] = ["id": member.id.uuidString, "name": GlassesAgents.clip(member.name, GlassesAgents.nameLength)]
                if let role = member.role, !role.isEmpty { item["role"] = GlassesAgents.clip(role, 24) }
                if let activity = member.activity { item["act"] = activity }
                if let detail = member.detail, !detail.isEmpty { item["detail"] = GlassesAgents.clip(detail, 80) }
                return item
            },
        ]
        if let goal, !goal.isEmpty { project["goal"] = GlassesAgents.clip(goal, GlassesAgents.detailLength) }
        if let says, !says.isEmpty { project["says"] = GlassesAgents.clip(says, 240) }
        if let last, !last.isEmpty { project["last"] = GlassesAgents.clip(last, 160) }
        return project
    }
}
#endif
