#if os(macOS)
import AppKit

/// Kanban cards and checklist items as tasks for agents: what an item shows and where it goes
/// from what its agent (and the project's check) is doing, and who gets the next item when a
/// To Do column is being worked through. Only rules here, nothing that touches the board, so
/// they can be tested on their own.
enum BoardTasks {
    /// What the tile an item was sent to is doing.
    enum Agent: Equatable {
        /// The tile is gone.
        case closed
        /// A new tile whose agent hasn't come up yet.
        case starting
        /// The tile is there with no agent in it: it quit.
        case noAgent
        case idle, working, needsYou, done, failed
    }

    static func agent(_ activity: VerticalTabAgentActivity) -> Agent {
        switch activity {
        case .ready: return .idle
        case .working: return .working
        case .needsPermission, .needsInput: return .needsYou
        case .done: return .done
        case .failed: return .failed
        }
    }

    /// The project's check after the agent's turn.
    enum Check: Equatable {
        case running, passed, failed
    }

    /// The small status on an item.
    enum Chip: Equatable {
        case queued, notSent, starting, sent, working, needsYou, checking, checkFailed, done, failed, noAgent, closed, idle

        var label: String {
            switch self {
            case .queued: return "queued"
            case .notSent: return "not sent"
            case .starting: return "starting"
            case .sent: return "sent"
            case .working: return "working"
            case .needsYou: return "needs you"
            case .checking: return "checking…"
            case .checkFailed: return "check failed"
            case .done: return "done"
            case .failed: return "failed"
            case .noAgent: return "no agent running"
            case .closed: return "tile closed"
            case .idle: return "idle"
            }
        }

        var color: NSColor {
            switch self {
            case .working, .starting, .sent, .checking: return .systemBlue
            case .needsYou: return .systemOrange
            case .done: return .systemGreen
            case .failed, .checkFailed: return .systemRed
            case .queued, .notSent, .noAgent, .closed, .idle: return .secondaryLabelColor
            }
        }
    }

    /// What an item remembers about being sent.
    struct Sent: Equatable {
        /// In Done (a checklist item: checked).
        var finished: Bool
        /// It hasn't been typed in yet: the agent was busy.
        var waiting: Bool
        /// The message is still waiting for the agent (false after a relaunch: it's gone).
        var queued: Bool
        /// When it was typed in.
        var at: Date?
        /// Moved by hand since: it stays where it was put.
        var manual: Bool
    }

    /// What's known about the tile right now.
    struct Live: Equatable {
        var agent: Agent
        /// When the agent's status last changed.
        var since: Date?
        /// The project has a check command.
        var hasCheck = false
        /// The check's result for the turn that just ended (nil: none yet).
        var check: Check?
    }

    struct Outcome: Equatable {
        var chip: Chip
        /// The item is finished: it goes to Done.
        var finish = false
    }

    /// The chip for an item that was sent to an agent, and whether it's finished.
    ///
    /// Done only counts for a turn that started after the item was typed in: an agent that was
    /// already done, or that finishes what it was doing while the item waits, hasn't done it.
    /// With a check command, the item is finished when the check passes.
    static func outcome(_ sent: Sent, _ live: Live) -> Outcome {
        if sent.finished { return Outcome(chip: .done) }
        if live.agent == .closed { return Outcome(chip: .closed) }
        if sent.waiting { return Outcome(chip: sent.queued ? .queued : .notSent) }
        switch live.agent {
        case .closed: return Outcome(chip: .closed)
        case .starting: return Outcome(chip: .starting)
        case .noAgent: return Outcome(chip: .noAgent)
        case .working: return Outcome(chip: .working)
        case .needsYou: return Outcome(chip: .needsYou)
        case .idle, .done, .failed: break
        }
        // Its status is from before the item reached it.
        if let at = sent.at, let since = live.since, since <= at { return Outcome(chip: .sent) }
        switch live.agent {
        case .idle: return Outcome(chip: .idle)
        case .failed: return Outcome(chip: .failed)
        default: break
        }
        if sent.manual { return Outcome(chip: .done) }
        guard live.hasCheck else { return Outcome(chip: .done, finish: true) }
        switch live.check {
        case .passed: return Outcome(chip: .done, finish: true)
        case .failed: return Outcome(chip: .checkFailed)
        case .running, nil: return Outcome(chip: .checking)
        }
    }

    /// An item moved (or checked) by hand: it keeps its agent, and nothing moves it after
    /// that. One that was still waiting to be typed in was never sent, so it has no agent.
    static func movedByHand(_ item: inout CardItem) {
        guard item.agent != nil else { return }
        if item.waiting == true {
            unlink(&item)
        } else {
            item.manual = true
        }
    }

    /// Forgets the agent an item was sent to.
    static func unlink(_ item: inout CardItem) {
        item.agent = nil
        item.agentName = nil
        item.sent = nil
        item.waiting = nil
        item.manual = nil
    }

    /// Marks an item as sent to a tile: typed in at `at`, or waiting for the agent when nil.
    static func link(_ item: inout CardItem, to tile: UUID, name: String, at: Date?) {
        item.agent = tile
        item.agentName = name
        item.sent = at
        item.waiting = at == nil ? true : nil
        item.manual = nil
        item.done = false
    }

    // MARK: Working through To Do

    /// An agent a queue started.
    enum Worker: Equatable {
        /// Can take the next item.
        case free
        /// On an item, or doing something else.
        case busy
        /// Its item didn't finish (its check failed, the agent failed or quit, the item never
        /// reached it): it gets nothing new until the item is moved by hand or finishes.
        case held
        /// Its tile is closed, or its agent quit with nothing left to do.
        case gone
    }

    /// What a queue's agent can do next. `chip` is its unfinished item's on this card, if it has one.
    static func worker(_ agent: Agent, item chip: Chip?) -> Worker {
        if agent == .closed { return .gone }
        guard let chip else {
            switch agent {
            case .idle, .done, .failed: return .free
            case .working, .needsYou: return .busy
            case .starting: return .busy
            case .noAgent, .closed: return .gone
            }
        }
        switch chip {
        case .checkFailed, .failed, .notSent, .noAgent, .closed: return .held
        case .queued, .starting, .sent, .working, .needsYou, .checking, .done, .idle: return .busy
        }
    }

    enum Step: Equatable {
        /// Type the item into an agent the queue already started.
        case give(item: UUID, worker: UUID)
        /// Start another agent on the item.
        case start(item: UUID)
    }

    static let agentLimit = 1...6

    /// Who takes what now: To Do from the top, free agents first, then new ones while fewer
    /// than `limit` are on the board. Held agents count, so failures don't pile up.
    static func plan(todo: [UUID], workers: [(id: UUID, state: Worker)], limit: Int) -> [Step] {
        let limit = min(max(limit, agentLimit.lowerBound), agentLimit.upperBound)
        var free = workers.filter { $0.state == .free }.map(\.id)
        var count = workers.filter { $0.state != .gone }.count
        var steps: [Step] = []
        for item in todo {
            if !free.isEmpty {
                steps.append(.give(item: item, worker: free.removeFirst()))
            } else if count < limit {
                steps.append(.start(item: item))
                count += 1
            } else {
                break
            }
        }
        return steps
    }

    /// The items a queue takes, top to bottom: To Do cards with something written on them.
    static func todo(_ items: [CardItem]) -> [UUID] {
        items.filter { $0.column == CardItem.todo && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id)
    }

    /// The item of this card a tile's agent is still on (not finished, not moved by hand).
    static func current(_ items: [CardItem], of tile: UUID) -> CardItem? {
        items.first { $0.agent == tile && $0.column != CardItem.done && $0.manual != true }
    }

    // MARK: Dropping on a tile

    /// The tile, card or sketch on top at `point` (board points). `order` is back to front.
    static func node(at point: CGPoint, order: [UUID], frames: [UUID: CGRect], hidden: Set<UUID> = []) -> UUID? {
        order.last { !hidden.contains($0) && frames[$0]?.contains(point) == true }
    }
}
#endif
