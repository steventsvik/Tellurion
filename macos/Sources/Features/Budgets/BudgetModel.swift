#if os(macOS)
import Foundation

/// What happens when an agent reaches its budget.
enum BudgetAction: String, Codable, CaseIterable, Identifiable {
    /// Freeze the agent and everything it started, the way a board's Pause all does.
    case pause
    /// Leave it running and only say so.
    case notify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pause: return "Pause the agent"
        case .notify: return "Just tell me"
        }
    }
}

/// A cap on one agent session: what it has cost at API prices, its tokens, or both.
struct AgentBudget: Codable, Equatable {
    /// Dollars at API prices. Nil or zero: no dollar cap.
    var dollars: Double?
    /// Tokens in and out, cached context included. Nil or zero: no token cap.
    var tokens: Int?
    var action: BudgetAction = .pause
    /// When it was set. A default only covers sessions that started after this, so setting
    /// one never stops an agent that's already far into its work.
    var since: Date?

    /// Whether it caps anything. A pane's own budget with no caps means "none for this pane",
    /// whatever the defaults say.
    var isSet: Bool { (dollars ?? 0) > 0 || (tokens ?? 0) > 0 }

    /// The fixed step "Add" raises a cap by.
    static let dollarStep = 5.0
    static let tokenStep = 1_000_000

    /// How far along the caps a session is: the larger of the two, 1 at a cap. A dollar cap
    /// can't be measured while the cost is unknown.
    func fraction(spent: Double?, tokens used: Int) -> Double {
        var fraction = 0.0
        if let dollars, dollars > 0, let spent { fraction = max(fraction, spent / dollars) }
        if let tokens, tokens > 0 { fraction = max(fraction, Double(used) / Double(tokens)) }
        return fraction
    }

    /// Which caps a raise changes: the ones that are reached, or every cap if none is yet.
    func capsToRaise(spent: Double?, tokens used: Int) -> (dollars: Bool, tokens: Bool) {
        let hasDollars = (dollars ?? 0) > 0, hasTokens = (tokens ?? 0) > 0
        let dollarsReached = hasDollars && (spent ?? 0) >= (dollars ?? 0)
        let tokensReached = hasTokens && used >= (tokens ?? 0)
        if dollarsReached || tokensReached { return (dollarsReached, tokensReached) }
        return (hasDollars, hasTokens)
    }

    /// The budget with more room. A cap is raised from what's already used when that's past
    /// it, so the session isn't over its budget again the moment it carries on.
    func raised(_ step: BudgetStep, spent: Double?, tokens used: Int) -> AgentBudget {
        var next = self
        let raise = capsToRaise(spent: spent, tokens: used)
        if raise.dollars, let cap = dollars {
            next.dollars = max(cap, spent ?? 0) + (step == .fixed ? Self.dollarStep : cap * 0.5)
        }
        if raise.tokens, let cap = tokens {
            next.tokens = max(cap, used) + (step == .fixed ? Self.tokenStep : Int((Double(cap) * 0.5).rounded()))
        }
        return next
    }
}

/// How much "Add $5" or "+50%" raises a budget by.
enum BudgetStep: Equatable {
    /// $5, or a million tokens for a token cap.
    case fixed
    /// Half the cap again.
    case half
}

/// Where a pane's budget comes from.
enum BudgetScope: Equatable {
    /// Set on the pane's own card.
    case pane
    /// The default for its project.
    case project
    /// The default for every session.
    case everywhere

    var label: String {
        switch self {
        case .pane: return "This agent"
        case .project: return "Project default"
        case .everywhere: return "Default for every session"
        }
    }
}

/// Every budget that's set: the default, each project's, and each pane's own.
struct BudgetSettings: Codable, Equatable {
    /// For every new agent session. Nil: off.
    var everywhere: AgentBudget?
    /// By repository root (or the folder itself outside a repository).
    var projects: [String: AgentBudget] = [:]
    /// By pane (its surface id).
    var panes: [String: AgentBudget] = [:]

    /// How many panes' own budgets are kept; the oldest are forgotten first.
    static let panesKept = 200

    /// Nothing is set anywhere, so nothing has to be measured.
    var isEmpty: Bool {
        everywhere?.isSet != true && !projects.values.contains(where: \.isSet) && !panes.values.contains(where: \.isSet)
    }

    /// The budget for a session: the pane's own, else its project's, else the default.
    /// A default only covers a session that started after it was set; `sessionStart` is nil
    /// while that isn't known.
    func budget(pane: UUID, project: String?, sessionStart: Date?) -> (budget: AgentBudget, scope: BudgetScope)? {
        if let own = panes[pane.uuidString] { return own.isSet ? (own, .pane) : nil }
        func covers(_ budget: AgentBudget) -> Bool {
            guard budget.isSet else { return false }
            guard let since = budget.since else { return true }
            guard let sessionStart else { return false }
            return sessionStart >= since
        }
        if let project, let budget = projects[project], covers(budget) { return (budget, .project) }
        if let budget = everywhere, covers(budget) { return (budget, .everywhere) }
        return nil
    }

    /// Sets (or with nil forgets) a pane's own budget, keeping only the newest `panesKept`.
    mutating func setPane(_ budget: AgentBudget?, for pane: UUID, now: Date = Date()) {
        guard var budget else {
            panes.removeValue(forKey: pane.uuidString)
            return
        }
        budget.since = now
        panes[pane.uuidString] = budget
        let extra = panes.count - Self.panesKept
        guard extra > 0 else { return }
        let oldest = panes.sorted { ($0.value.since ?? .distantPast) < ($1.value.since ?? .distantPast) }.prefix(extra)
        for (key, _) in oldest { panes.removeValue(forKey: key) }
    }
}

/// What a pane's card shows about its budget.
struct BudgetStatus: Equatable {
    /// Dollars at API prices so far. Nil when a model's price isn't known.
    var spent: Double?
    /// Tokens in and out so far.
    var tokens: Int
    var capDollars: Double?
    var capTokens: Int?
    /// 0 to 1 and beyond: the larger of spent/cap and tokens/cap.
    var fraction: Double
    var state: State

    enum State: Equatable {
        case ok
        /// Past 80%.
        case warning
        /// At the cap, and still running.
        case reached
        /// At the cap, and frozen until the budget is raised or removed.
        case paused
    }
}

/// Which of a budget's thresholds a session has already crossed, so each is acted on once.
struct BudgetProgress: Equatable {
    static let warningAt = 0.8

    private(set) var warned = false
    private(set) var reached = false
    /// The agent was already frozen for this crossing of the cap.
    private(set) var froze = false
    /// Frozen at the cap by the budget.
    var paused = false

    enum Event: Equatable {
        case warning
        case reached
    }

    /// Takes a new reading. Returns a threshold the first time it's crossed; dropping back
    /// under one (the cap was raised) arms it again.
    mutating func update(fraction: Double) -> Event? {
        if fraction < 1 {
            reached = false
            froze = false
        }
        if fraction < Self.warningAt { warned = false }
        if fraction >= 1, !reached {
            reached = true
            warned = true
            return .reached
        }
        if fraction >= Self.warningAt, !warned {
            warned = true
            return .warning
        }
        return nil
    }

    /// Whether to freeze the agent now: at the cap with "Pause the agent" chosen, once per
    /// crossing, so an agent the user resumed some other way isn't frozen again.
    mutating func shouldPause(fraction: Double, action: BudgetAction) -> Bool {
        guard fraction >= 1, action == .pause, !froze else { return false }
        froze = true
        paused = true
        return true
    }

    func state(fraction: Double) -> BudgetStatus.State {
        if paused { return .paused }
        if fraction >= 1 { return .reached }
        return fraction >= Self.warningAt ? .warning : .ok
    }
}

/// Budget figures as text.
enum BudgetFormat {
    /// "$1.20", "$5", "$120".
    static func money(_ value: Double) -> String {
        if value >= 100 || value == value.rounded() { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }

    /// "950", "12.5K", "1.2M", "5M".
    static func count(_ value: Int) -> String {
        func short(_ scaled: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", scaled)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if value >= 1_000_000 { return short(Double(value) / 1_000_000, "M") }
        if value >= 1000 { return short(Double(value) / 1000, "K") }
        return "\(value)"
    }

    /// "$1.20 of $5", "1.2M of 5M tokens", or both: whichever caps the budget has.
    static func progress(_ status: BudgetStatus) -> String {
        var parts: [String] = []
        if let cap = status.capDollars, cap > 0 {
            parts.append(status.spent.map { "\(money($0)) of \(money(cap))" } ?? "cost unknown of \(money(cap))")
        }
        if let cap = status.capTokens, cap > 0 {
            parts.append("\(count(status.tokens)) of \(count(cap)) tokens")
        }
        return parts.joined(separator: " · ")
    }

    /// "$5", "2M tokens", "$5 or 2M tokens".
    static func caps(_ budget: AgentBudget) -> String {
        var parts: [String] = []
        if let dollars = budget.dollars, dollars > 0 { parts.append(money(dollars)) }
        if let tokens = budget.tokens, tokens > 0 { parts.append("\(count(tokens)) tokens") }
        return parts.isEmpty ? "No budget" : parts.joined(separator: " or ")
    }

    /// What the fixed step's button says for a session: "Add $5" or "Add 1M tokens".
    static func fixedStep(_ budget: AgentBudget, spent: Double?, tokens: Int) -> String {
        budget.capsToRaise(spent: spent, tokens: tokens).dollars
            ? "Add \(money(AgentBudget.dollarStep))" : "Add \(count(AgentBudget.tokenStep)) tokens"
    }
}
#endif
