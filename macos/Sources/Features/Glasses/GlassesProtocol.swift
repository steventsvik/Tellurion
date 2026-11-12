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
        guard agent.activity == .needsPermission else { return nil }
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

    /// The message's content, without the clock (so an unchanged list gives the same text).
    static func message(_ unordered: [GlassesAgent]) -> [String: Any] {
        let agents = ordered(unordered)
        let names = names(agents)
        let list: [[String: Any]] = zip(agents, names).map { agent, name in
            var item: [String: Any] = [
                "id": agent.id.uuidString,
                "name": name,
                "kind": agent.kind,
                "act": activity(agent.activity),
                "since": Int(agent.since.timeIntervalSince1970),
            ]
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
        let needs = agents.filter { $0.activity == .needsPermission || $0.activity == .needsInput }.count
        return ["t": "agents", "agents": list, "needs": needs]
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
}

/// A message from the glasses, checked.
enum GlassesRequest: Equatable {
    case glance(Bool)
    case orchestrators(Bool)
    case tail(id: UUID, lines: Int)
    case untail
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
            return .request(.tail(id: id, lines: lines))
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
