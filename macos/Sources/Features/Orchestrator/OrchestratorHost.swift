#if os(macOS)
import AppKit

/// Where an orchestrator lives: a card on a board, or a project's tabs in a classic window.
enum OrchestratorPlace {
    case board
    case tabs
}

/// A wired pane, as an orchestrator sees it.
struct OrchestratorAgent {
    /// The pane's id (its terminal's).
    let pane: UUID
    /// The terminal itself.
    let surface: Ghostty.SurfaceView?
    let role: String?
    /// The name of the group it came with, if it wasn't wired by itself.
    let group: String?

    init(pane: UUID, surface: Ghostty.SurfaceView? = nil, role: String? = nil, group: String? = nil) {
        self.pane = pane
        self.surface = surface
        self.role = role
        self.group = group
    }
}

/// What an orchestrator's brain needs from where it lives: its team, the panes wired to it,
/// and ways to message them and start new ones. A board is one (its orchestrator cards), a
/// project's classic orchestrator another. Everything here is called on the main thread.
protocol OrchestratorHost: AnyObject {
    var orchestratorPlace: OrchestratorPlace { get }
    /// Groups what one reply did into one step to undo, where there is undo.
    var orchestratorUndo: UndoManager? { get }

    /// The orchestrator's team: who is wired, their roles, the goal and the turn limit.
    func orchestrator(_ id: UUID) -> BoardTeam?
    /// The same, made on the spot if it's missing; nil when the orchestrator is gone.
    func ensureTeam(_ id: UUID) -> BoardTeam?
    func setGoal(_ goal: String, for id: UUID)
    func orchestratorName(_ id: UUID) -> String
    /// Everything wired, each pane once.
    func orchestratorAgents(_ id: UUID) -> [OrchestratorAgent]

    func surface(of pane: UUID) -> Ghostty.SurfaceView?
    /// A pane's name, as you'd @mention it.
    func paneLabel(_ pane: UUID) -> String
    func paneFolder(_ pane: UUID) -> String?
    func isPaused(_ pane: UUID) -> Bool
    /// The agent in a pane, if one has reported a status.
    func agentInfo(_ pane: UUID) -> VerticalTabAgentInfo?
    /// The agent's last answer, from the transcript it reported.
    func lastAnswer(of pane: UUID) -> String?
    /// One line about the project's check, if it failed for the agent's finished turn.
    func failedCheck(of pane: UUID) -> String?

    /// The panes @mentioned in `text`, and the text without the mentions.
    func mentionedPanes(in text: String, for id: UUID) -> (panes: [UUID], rest: String)
    /// A message for the agent in a pane: queued until Claude Code or Codex is ready for it,
    /// typed straight in for other agents.
    func deliver(_ text: String, toAgentIn pane: UUID, label: String)
    /// One line typed into a pane, then Enter.
    func typeLine(_ line: String, into pane: UUID)
    /// Starts an agent (or, with none, a plain terminal) wired to the orchestrator.
    func spawnWired(_ agent: BoardAgent?, role: String?, task: String?, folder: String?, for id: UUID) -> UUID?
    /// The agent programs running in panes that haven't reported a status, by pane.
    func detectAgents(in panes: Set<UUID>, done: @escaping ([UUID: String]) -> Void)
}

extension OrchestratorHost {
    func agentInfo(_ pane: UUID) -> VerticalTabAgentInfo? {
        surface(of: pane).flatMap { VerticalTabsAgents.shared.info(for: $0) }
    }

    func lastAnswer(of pane: UUID) -> String? {
        surface(of: pane).flatMap(OrchestratorAnswers.last)
    }

    func failedCheck(of pane: UUID) -> String? {
        guard let surface = surface(of: pane), let result = ProjectChecks.shared.result(for: surface),
              result.state == .failed else { return nil }
        let summary = result.summary.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return summary.isEmpty ? result.command : BoardTeams.clip(summary, 200)
    }

    func deliver(_ text: String, toAgentIn pane: UUID, label: String) {
        guard let surface = surface(of: pane) else { return }
        let kind = VerticalTabsAgents.shared.info(for: surface)?.kind
        if kind == .claude || kind == .codex {
            AgentInbox.shared.deliver(text, to: surface, label: label)
        } else {
            typeLine(text, into: pane)
        }
    }

    func typeLine(_ line: String, into pane: UUID) {
        guard let surface = surface(of: pane) else { return }
        // Always on the main thread, as everything here is.
        MainActor.assumeIsolated {
            guard let model = surface.surfaceModel else { return }
            model.sendText(line)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
        }
    }

    func detectAgents(in panes: Set<UUID>, done: @escaping ([UUID: String]) -> Void) {
        BoardPause.queue.async {
            let found = BoardPause.agents(in: panes)
            DispatchQueue.main.async { done(found) }
        }
    }
}

/// The wired agents in words, with a handle for each.
struct OrchestratorContext {
    var text: String
    var handles: [String: UUID]

    func handle(_ tile: UUID) -> String? { handles.first { $0.value == tile }?.key }
}

extension OrchestratorHost {
    /// `detected`: agents found running by process in panes that haven't reported any status.
    func orchestratorContext(_ id: UUID, agents installed: [BoardAgent], detected: [UUID: String] = [:]) -> OrchestratorContext {
        var handles: [String: UUID] = [:]
        var lines: [String] = []
        let wired = orchestratorAgents(id)
        if wired.isEmpty { lines.append("No agents are wired yet.") }
        for (index, agent) in wired.enumerated() {
            let handle = "A\(index + 1)"
            handles[handle] = agent.pane
            var parts = ["\(handle) \"\(paneLabel(agent.pane))\""]
            if let role = agent.role { parts.append("role \(role)") }
            if let group = agent.group { parts.append("in group \(group)") }
            let info = agentInfo(agent.pane)
            if let info {
                parts.append("\(info.kind.displayName), \(info.activity.label.lowercased())")
                if let detail = info.detail, AgentAlerts.isWaiting(info.activity) { parts.append("waiting on: \(detail)") }
            } else if let binary = detected[agent.pane] {
                let name = BoardAgent.catalog.first { $0.binary == binary }?.kind.displayName ?? binary
                parts.append("\(name), running (it hasn't reported a status yet; it takes messages)")
            } else {
                parts.append("terminal (no agent)")
            }
            if isPaused(agent.pane) { parts.append("paused by the user") }
            if let folder = paneFolder(agent.pane) { parts.append("in \((folder as NSString).abbreviatingWithTildeInPath)") }
            // So it can send the agent back to fix what its turn broke.
            if info != nil, info?.activity != .working, let check = failedCheck(of: agent.pane) {
                parts.append("its project check failed: \(check)")
            }
            lines.append("- " + parts.joined(separator: "; "))
            if let answer = lastAnswer(of: agent.pane), info?.activity != .working {
                lines.append("  Last answer: " + BoardTeams.clip(answer.replacingOccurrences(of: "\n", with: " "), 600))
            }
        }
        lines.append("Installed agents: " + (installed.isEmpty ? "none found" : installed.map(\.binary).joined(separator: ", ")) + ".")
        return OrchestratorContext(text: lines.joined(separator: "\n"), handles: handles)
    }

    /// One action from an orchestrator's brain; what was done, in words.
    /// `detected`: panes running an agent that hasn't reported a status, which take messages
    /// typed in directly.
    func performOrchestration(_ action: OrchestratorAction, for id: UUID, handles: [String: UUID],
                              detected: Set<UUID> = []) -> String? {
        guard orchestrator(id) != nil else { return nil }
        let wired = orchestratorAgents(id)
        let from = orchestratorName(id)
        func target(_ name: String?) -> OrchestratorAgent? {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            if let pane = handles[name.uppercased()] { return wired.first { $0.pane == pane } }
            let lower = name.lowercased()
            return wired.first { $0.role?.lowercased() == lower }
                ?? wired.first { paneLabel($0.pane).lowercased() == lower }
                ?? wired.first { $0.role?.lowercased().hasPrefix(lower) == true }
        }
        /// Only to agents: text typed into a plain shell would run as a command.
        func send(_ text: String, to agent: OrchestratorAgent) -> Bool {
            if agentInfo(agent.pane) == nil {
                guard detected.contains(agent.pane) else { return false }
                // An agent's input box takes one line (a newline would send it early).
                let line = text.replacingOccurrences(of: "\n", with: " ")
                typeLine("From \(from)" + (agent.role.map { ", to you as the \($0)" } ?? "") + ": " + line, into: agent.pane)
            } else {
                deliver("From \(from)" + (agent.role.map { ", to you as the \($0)" } ?? "") + ":\n\n" + text,
                        toAgentIn: agent.pane, label: "From \(from)")
            }
            return true
        }
        switch action.type {
        case "send":
            guard let agent = target(action.agent), let text = action.text, !text.isEmpty else { return nil }
            guard send(text, to: agent) else { return "\(paneLabel(agent.pane)) has no agent running; not sent" }
            return "Sent \(paneLabel(agent.pane)): " + BoardTeams.clip(text.replacingOccurrences(of: "\n", with: " "), 120)
        case "broadcast":
            guard let text = action.text, !text.isEmpty, !wired.isEmpty else { return nil }
            let skipped = wired.filter { !send(text, to: $0) }.map { paneLabel($0.pane) }
            if skipped.count == wired.count { return "Not sent: no agent running in \(skipped.joined(separator: ", "))" }
            if !skipped.isEmpty { return "Sent everyone with an agent (not \(skipped.joined(separator: ", "))): " + BoardTeams.clip(text.replacingOccurrences(of: "\n", with: " "), 100) }
            return "Sent everyone: " + BoardTeams.clip(text.replacingOccurrences(of: "\n", with: " "), 120)
        case "spawn":
            guard wired.count < BoardTeams.maxAgents else { return "Can't start more than \(BoardTeams.maxAgents) agents" }
            let name = (action.agent ?? "claude").lowercased()
            let agent = BoardAgent.catalog.first { $0.binary == name || $0.kind.rawValue == name }
            guard agent != nil || name == "shell" else { return "Unknown agent \(name)" }
            let folder = action.folder.map { ($0 as NSString).expandingTildeInPath }
            if let folder, !FileManager.default.fileExists(atPath: folder) { return "No folder \(action.folder ?? "")" }
            let role = action.role?.isEmpty == false ? action.role : nil
            guard spawnWired(agent, role: role, task: action.task, folder: folder, for: id) != nil else { return nil }
            return "Started " + (agent?.kind.displayName ?? "a terminal") + (role.map { " · \($0)" } ?? "")
        case "wait":
            return nil
        default:
            return nil
        }
    }

    /// What to tell an orchestrator's brain about these events: the latest per agent still
    /// wired to it, with its answer and whether its project's check failed.
    func orchestratorUpdates(_ id: UUID, events: [OrchestratorRelay.Event]) -> [OrchestratorBrain.Update] {
        let wired = Set(orchestratorAgents(id).map(\.pane))
        return OrchestratorRelay.latest(events).compactMap { event in
            guard wired.contains(event.pane) else { return nil }
            let quiet = event.activity == .needsPermission || event.activity == .failed
            let finished = event.activity == .done || event.activity == .ready
            return OrchestratorBrain.Update(tile: event.pane, name: paneLabel(event.pane), activity: event.activity,
                                            detail: event.detail, answer: quiet ? nil : lastAnswer(of: event.pane),
                                            failedCheck: finished ? failedCheck(of: event.pane) : nil)
        }
    }
}

/// What orchestrators have yet to hear from their agents, sent together a moment after the
/// last of it.
final class OrchestratorRelay {
    /// Something an orchestrator hears about: a pane's agent finished, asks or failed.
    struct Event: Equatable {
        let pane: UUID
        let activity: VerticalTabAgentActivity
        let detail: String?
    }

    /// A few seconds, so agents finishing together arrive as one update, and their
    /// transcripts are written.
    static let delay: TimeInterval = 3

    /// Each pane's agent status when last seen.
    var last: [UUID: VerticalTabAgentActivity] = [:]
    /// Per orchestrator: what happened to its agents.
    var pending: [UUID: [Event]] = [:]
    var flush: [UUID: DispatchWorkItem] = [:]

    /// Whether an agent going from `before` to `now` is news for its orchestrators: a turn
    /// that ended, a question, a permission prompt or an error. Starting work, or sitting
    /// ready without having worked, isn't.
    static func reports(from before: VerticalTabAgentActivity?, to now: VerticalTabAgentActivity) -> Bool {
        guard now != before else { return false }
        let finished = before == .working || before == .needsPermission
        switch now {
        case .done, .ready: return finished
        case .needsInput, .needsPermission, .failed: return true
        case .working: return false
        }
    }

    /// The latest event per pane, in the order those happened.
    static func latest(_ events: [Event]) -> [Event] {
        var seen = Set<UUID>()
        return events.reversed().filter { seen.insert($0.pane).inserted }.reversed()
    }

    /// Remembers a pane's status; the event to report, if the change is one.
    func note(_ pane: UUID, info: VerticalTabAgentInfo?) -> Event? {
        let before = last[pane]
        last[pane] = info?.activity
        guard let info, Self.reports(from: before, to: info.activity) else { return nil }
        return Event(pane: pane, activity: info.activity, detail: info.detail)
    }

    /// Adds an event for an orchestrator; `send` gets everything gathered for it once
    /// nothing more has come for `delay` seconds.
    func schedule(_ event: Event, for id: UUID, send: @escaping ([Event]) -> Void) {
        pending[id, default: []].append(event)
        flush[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let events = self.pending.removeValue(forKey: id) ?? []
            self.flush[id] = nil
            if !events.isEmpty { send(events) }
        }
        flush[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Forgets an orchestrator, or a pane that closed.
    func forget(orchestrator id: UUID) {
        flush.removeValue(forKey: id)?.cancel()
        pending[id] = nil
    }

    func forget(pane: UUID) {
        last[pane] = nil
    }
}

/// Agents' last answers, read from the transcripts they reported.
enum OrchestratorAnswers {
    private static var answers: [String: (stamp: String, answer: String?)] = [:]

    /// The agent's last answer, from the transcript it reported. Never guessed from its
    /// folder: that could be another session there (yours, or another agent's).
    /// Read again only when the transcript has changed.
    static func last(_ surface: Ghostty.SurfaceView) -> String? {
        guard let transcript = VerticalTabsAgents.shared.info(for: surface)?.transcriptPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: transcript) else { return nil }
        let stamp = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\(attributes[.size] as? Int ?? 0)"
        if let cached = answers[transcript], cached.stamp == stamp { return cached.answer }
        let answer = AgentTools.lastAssistantMessage(transcript: transcript)?.trimmingCharacters(in: .whitespacesAndNewlines)
        answers[transcript] = (stamp, answer)
        return answer
    }
}
#endif
