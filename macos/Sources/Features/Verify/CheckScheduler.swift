#if os(macOS)
import Foundation

/// Decides when a project's check runs: one at a time per project, and however many turns
/// finish while it runs, once more afterwards.
///
/// It only keeps the bookkeeping. The caller starts a run when `request` or `finished` hands
/// back what to run, and calls `finished` when that run ends.
struct CheckScheduler<Trigger> {
    private var running: Set<String> = []
    private var waiting: [String: Trigger] = [:]

    /// Asks for a run of `project`'s check. Returns `trigger` when it should start now. Nil
    /// when one is already running: this one follows it, in place of any that was waiting.
    mutating func request(_ project: String, _ trigger: Trigger) -> Trigger? {
        guard !running.contains(project) else {
            waiting[project] = trigger
            return nil
        }
        running.insert(project)
        return trigger
    }

    /// The run of `project`'s check ended. Returns what to run next, if anything was asked for
    /// meanwhile; the project then counts as running again.
    mutating func finished(_ project: String) -> Trigger? {
        guard running.contains(project) else { return nil }
        if let next = waiting.removeValue(forKey: project) { return next }
        running.remove(project)
        return nil
    }

    /// Forgets a waiting run (the project's check was removed). One that's running still
    /// ends with `finished`.
    mutating func dropWaiting(_ project: String) {
        waiting.removeValue(forKey: project)
    }

    func isRunning(_ project: String) -> Bool { running.contains(project) }
    func hasWaiting(_ project: String) -> Bool { waiting[project] != nil }
}

/// How many failed checks have gone back to an agent by themselves since the user last gave
/// it a prompt. It stops at `limit`, so an agent that can't make the check pass isn't sent
/// around forever.
struct AutoSendRounds<Agent: Hashable> {
    let limit: Int
    private var used: [Agent: Int] = [:]
    /// Agents whose next turn is the one a failure message starts.
    private var expecting: Set<Agent> = []

    init(limit: Int = 3) {
        self.limit = limit
    }

    func used(by agent: Agent) -> Int { used[agent] ?? 0 }

    /// Whether another failure may go to `agent` automatically; counts it when it may.
    mutating func take(for agent: Agent) -> Bool {
        guard used(by: agent) < limit else { return false }
        used[agent] = used(by: agent) + 1
        expecting.insert(agent)
        return true
    }

    /// The user sent a failure to `agent` by hand: its next turn isn't a new task either.
    mutating func sentByHand(to agent: Agent) {
        expecting.insert(agent)
    }

    /// `agent` started a turn on `prompt`. A prompt the user wrote starts the count again;
    /// the turn a failure message started doesn't.
    mutating func turnStarted(by agent: Agent, prompt: String?) {
        let expected = expecting.remove(agent) != nil
        if expected || prompt?.hasPrefix(CheckOutput.promptOpening) == true { return }
        used.removeValue(forKey: agent)
    }

    mutating func forget(_ agent: Agent) {
        used.removeValue(forKey: agent)
        expecting.remove(agent)
    }
}
#endif
