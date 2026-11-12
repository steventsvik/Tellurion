#if os(macOS)
import AppKit
import CryptoKit
import os

/// Tellurion on Even G2 glasses: who needs you, answering a permission prompt, an agent's
/// latest output, and talking to an agent or a project's orchestrator.
///
/// It's a second kind of client of the phone server (see `PhoneServer`), with the same
/// protection: the same local listener behind `tailscale serve`, the owner's Tailscale
/// login, and a paired device's token sent first. On top of that:
/// - A permission answer names the prompt it's for, and is dropped if the agent is showing
///   another one by then (`GlassesRules.answerRefusal`), or if the prompt isn't on screen.
/// - Text only ever goes to a pane with an agent in it, never one with a bare shell, and
///   never with control characters (`GlassesRules.sayRefusal`).
/// - What the glasses hear is turned into text on this Mac and sent back to the glasses.
///   Nothing is done with it here: the glasses send a separate message once you confirm.
/// - Answers, messages and audio are limited per device.
final class GlassesServer {
    static let shared = GlassesServer()

    /// The protocol's version, in the hello reply.
    static let version = 1
    static let actionsPerMinute = 30.0
    /// A minute and a half of sound each minute.
    static let audioBytesPerMinute = Double(GlassesAudio.bytesPerSecond * 90)

    /// A connected device, as the phone server hands it over once it has said who it is.
    struct Peer {
        let id: ObjectIdentifier
        let device: PhoneDevice
        let send: (String) -> Void
        let isBackedUp: () -> Bool
        let close: () -> Void
    }

    private final class Session {
        let peer: Peer
        var glance = false
        var orchestrators = false
        var tail: (id: UUID, lines: Int)?
        var lastAgents = ""
        var lastTail = ""
        var lastOrchestrators = ""
        var utterance: Utterance?
        init(peer: Peer) { self.peer = peer }
    }

    private final class Utterance {
        let transcriber: SpeechTranscriber
        var bytes = 0
        var lastPartial = Date.distantPast
        init(transcriber: SpeechTranscriber) { self.transcriber = transcriber }
    }

    private var sessions: [ObjectIdentifier: Session] = [:]
    private var timer: Timer?
    /// Per device: answers and messages, and bytes of sound.
    private var actions: [String: GlassesRateLimiter] = [:]
    private var audio: [String: GlassesRateLimiter] = [:]
    private static let log = StoredFile.logger("Glasses")

    private init() {}

    // MARK: Messages

    /// A message from a device that has said who it is.
    func receive(_ message: [String: Any], from peer: Peer) {
        guard TellurionSettings.isOn(.glasses) else {
            peer.send(Self.error("off", "Glasses are turned off in Tellurion's settings."))
            return
        }
        let request: GlassesRequest
        switch GlassesRequest.parse(message) {
        case .unknown: return
        case .invalid(let reason):
            peer.send(Self.error("bad", reason))
            return
        case .request(let parsed): request = parsed
        }
        let session = sessions[peer.id] ?? Session(peer: peer)
        sessions[peer.id] = session
        switch request {
        case .glance(let on):
            session.glance = on
            session.lastAgents = ""
        case .orchestrators(let on):
            session.orchestrators = on
            session.lastOrchestrators = ""
        case .tail(let id, let lines):
            session.tail = (id, lines)
            session.lastTail = ""
        case .untail:
            session.tail = nil
        case .answer(let id, let allow, let prompt):
            guard allowAction(session) else { return }
            answer(id, allow: allow, prompt: prompt, for: session)
        case .say(let id, let text):
            guard allowAction(session) else { return }
            say(text, to: id, for: session)
        case .orchestratorCommand(let id, let text):
            guard allowAction(session) else { return }
            command(text, project: id, for: session)
        case .listen:
            listen(session)
        case .heard:
            session.utterance?.transcriber.finish()
        case .unlisten:
            stopListening(session)
        }
        updateTimer()
        push()
    }

    /// Sound from the glasses, between `listen` and `heard?`.
    func receiveAudio(_ pcm: Data, from id: ObjectIdentifier) {
        guard TellurionSettings.isOn(.glasses), let session = sessions[id], let utterance = session.utterance else { return }
        let device = session.peer.device.id
        var limiter = audio[device] ?? GlassesRateLimiter(capacity: Self.audioBytesPerMinute, per: 60)
        let allowed = limiter.allow(Double(pcm.count))
        audio[device] = limiter
        guard allowed else {
            stopListening(session)
            session.peer.send(GlassesRoutes.json(["t": "heard", "error": "That's a lot of talking. Try again in a minute."]))
            return
        }
        utterance.bytes += pcm.count
        utterance.transcriber.append(pcm)
        // A minute is the most one utterance may be: what was said so far is what counts.
        if utterance.bytes >= GlassesAudio.maxUtterance { utterance.transcriber.finish() }
    }

    /// The device's connection closed.
    func dropped(_ id: ObjectIdentifier) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        stopListening(session)
        updateTimer()
    }

    /// Glasses were turned off in Settings: nobody stays connected or paired halfway.
    func turnedOff() {
        for session in sessions.values {
            stopListening(session)
            session.peer.close()
        }
        sessions = [:]
        GlassesPairing.shared.close()
        updateTimer()
    }

    private static func error(_ code: String, _ message: String) -> String {
        GlassesRoutes.json(["t": "error", "code": code, "message": message])
    }

    private func allowAction(_ session: Session) -> Bool {
        let device = session.peer.device.id
        var limiter = actions[device] ?? GlassesRateLimiter(capacity: Self.actionsPerMinute, per: 60)
        let allowed = limiter.allow()
        actions[device] = limiter
        if !allowed { session.peer.send(Self.error("rate", "Too many at once. Wait a moment.")) }
        return allowed
    }

    // MARK: Agents

    /// Every pane with an agent in an open classic window or board.
    private func agents() -> [(agent: GlassesAgent, surface: Ghostty.SurfaceView)] {
        var found: [(GlassesAgent, Ghostty.SurfaceView)] = []
        for controller in PhoneServer.shared.openControllers {
            let board = controller as? BoardController
            for surface in controller.surfaceTree {
                guard let info = VerticalTabsAgents.shared.info(for: surface) else { continue }
                var agent = GlassesAgent(id: surface.id, name: TerminalWindows.title(of: surface, in: controller) ?? info.name,
                                         kind: info.kind.rawValue, activity: info.activity, unseen: info.unseen,
                                         task: info.task, detail: info.detail, since: info.since)
                agent.project = surface.pwd.map { ProjectPath.displayName(ClassicOrchestrators.shared.root(of: $0)) }
                if let result = ProjectChecks.shared.result(for: surface) {
                    let state: String
                    switch result.state {
                    case .running: state = "running"
                    case .passed: state = "passed"
                    case .failed, .timedOut: state = "failed"
                    }
                    agent.check = .init(state: state, summary: result.summary)
                }
                if let budget = AgentBudgets.shared.status(for: surface) {
                    let state: String
                    switch budget.state {
                    case .ok: state = "ok"
                    case .warning: state = "warning"
                    case .reached: state = "reached"
                    case .paused: state = "paused"
                    }
                    agent.budget = .init(fraction: budget.fraction, state: state)
                }
                agent.conflicts = AgentConflicts.shared.conflicts(for: surface).count
                agent.wired = ClassicOrchestrators.shared.wired.contains(surface.id)
                    || board?.orchestrators(of: surface.id).isEmpty == false
                found.append((agent, surface))
            }
        }
        return found
    }

    private func surface(_ id: UUID) -> Ghostty.SurfaceView? {
        for controller in PhoneServer.shared.openControllers {
            if let match = controller.surfaceTree.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    private func answer(_ id: UUID, allow: Bool, prompt: String, for session: Session) {
        let found = agents().first { $0.agent.id == id }
        var message = GlassesRules.answerRefusal(agent: found?.agent, prompt: prompt)
        var sent = false
        if message == nil, let surface = found?.surface {
            // Messages arrive on the main queue. The prompt has to be on screen with "Yes"
            // selected, as for the sidebar's buttons; otherwise no key is pressed.
            sent = MainActor.assumeIsolated { AgentPermissions.answer(allow ? .allow : .deny, on: surface) }
            message = sent ? (allow ? "Allowed" : "Denied") : "Not answered: answer it on your Mac"
        }
        Self.log.info("Answer \(allow ? "allow" : "deny", privacy: .public) from \(session.peer.device.id, privacy: .public): sent \(sent)")
        session.peer.send(GlassesRoutes.json(["t": "answered", "id": id.uuidString, "ok": sent, "message": message ?? ""]))
    }

    private func say(_ text: String, to id: UUID, for session: Session) {
        let target = surface(id)
        let info = target.flatMap { VerticalTabsAgents.shared.info(for: $0) }
        var message = GlassesRules.sayRefusal(hasAgent: info != nil, text: text)
        var sent = false
        if message == nil, let target, let info {
            sent = true
            if info.kind == .claude || info.kind == .codex {
                // Waits until the agent is between turns with an empty input box.
                let ready = AgentInbox.readiness(of: target) == .ready
                AgentInbox.shared.deliver(text, to: target, label: "From your glasses")
                message = ready ? "Sent" : "Queued until it's ready"
            } else {
                Self.typeLine(text, into: target)
                message = "Sent"
            }
        }
        Self.log.info("Message from \(session.peer.device.id, privacy: .public): delivered \(sent)")
        session.peer.send(GlassesRoutes.json(["t": "said", "id": id.uuidString, "ok": sent, "message": message ?? ""]))
    }

    /// One line typed into an agent's input box, then Enter.
    private static func typeLine(_ line: String, into surface: Ghostty.SurfaceView) {
        MainActor.assumeIsolated {
            guard let model = surface.surfaceModel else { return }
            model.sendText(line.replacingOccurrences(of: "\n", with: " "))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
        }
    }

    // MARK: Orchestrators

    /// A project's id on the wire: not its path.
    static func projectID(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The projects that have an orchestrator, or classic panes with agents it could run.
    private func projectRoots() -> [String] {
        guard TellurionSettings.isOn(.orchestrator) else { return [] }
        var roots = ClassicOrchestrators.shared.list.map(\.root)
        for (_, surface) in ClassicPanes.all where VerticalTabsAgents.shared.info(for: surface) != nil {
            guard let folder = surface.pwd else { continue }
            let root = ClassicOrchestrators.shared.root(of: folder)
            if !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    private func orchestratorsMessage() -> String {
        let projects: [[String: Any]] = projectRoots().map { root in
            let orchestrator = ClassicOrchestrators.shared.orchestrator(root: root)
            var project: [String: Any] = [
                "id": Self.projectID(root),
                "name": GlassesAgents.clip(ProjectPath.displayName(root), GlassesAgents.nameLength),
                "status": orchestrator?.status.line ?? "Not started",
            ]
            if let goal = orchestrator?.team.goal ?? ClassicOrchestrators.shared.record(root: root)?.goal, !goal.isEmpty {
                project["goal"] = GlassesAgents.clip(goal, GlassesAgents.detailLength)
            }
            project["log"] = (orchestrator?.brain.log.suffix(6) ?? []).map { entry -> String in
                let prefix = entry.kind == .user ? "You: " : entry.kind == .error ? "! " : ""
                return GlassesAgents.clip(prefix + entry.text, 160)
            }
            return project
        }
        return GlassesRoutes.json(["t": "orch", "projects": projects])
    }

    private func command(_ text: String, project id: String, for session: Session) {
        var message: String
        var sent = false
        if AgentTools.typedLine(text) == nil {
            message = "That text has characters that can't be sent."
        } else if let root = projectRoots().first(where: { PhoneDevices.equal(Self.projectID($0), id) }) {
            ClassicOrchestrators.shared.open(root: root).command(text)
            sent = true
            message = "Sent to the orchestrator"
        } else {
            message = "That project has no orchestrator or agents now."
        }
        Self.log.info("Orchestrator command from \(session.peer.device.id, privacy: .public): sent \(sent)")
        session.peer.send(GlassesRoutes.json(["t": "orchsent", "id": id, "ok": sent, "message": message]))
    }

    // MARK: Voice

    private func listen(_ session: Session) {
        stopListening(session)
        let utterance = Utterance(transcriber: GlassesSpeech.makeTranscriber())
        session.utterance = utterance
        let peer = session.peer
        utterance.transcriber.start(update: { [weak session, weak utterance] text, final in
            guard let session, let utterance, session.utterance === utterance else { return }
            if final {
                session.utterance = nil
            } else {
                // Words so far, a few times a second.
                guard Date().timeIntervalSince(utterance.lastPartial) > 0.3 else { return }
                utterance.lastPartial = Date()
            }
            peer.send(GlassesRoutes.json(["t": "heard", "text": String(text.prefix(GlassesRequest.maxText)), "final": final]))
        }, failed: { [weak session, weak utterance] reason in
            guard let session, let utterance, session.utterance === utterance else { return }
            session.utterance = nil
            peer.send(GlassesRoutes.json(["t": "heard", "error": reason]))
        })
    }

    private func stopListening(_ session: Session) {
        session.utterance?.transcriber.cancel()
        session.utterance = nil
    }

    // MARK: Pushing

    private func updateTimer() {
        let wanted = sessions.values.contains { $0.glance || $0.orchestrators || $0.tail != nil }
        if wanted, timer == nil {
            // Twice a second, sent only when something changed.
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.push() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    private func push() {
        guard TellurionSettings.isOn(.glasses), !sessions.isEmpty else { return }
        // Each is built once a tick, however many glasses are connected.
        var agentsContent: (core: String, message: [String: Any])?
        var orchestrators: String?
        var all: [(agent: GlassesAgent, surface: Ghostty.SurfaceView)]?
        for session in sessions.values where !session.peer.isBackedUp() {
            if session.glance {
                if agentsContent == nil {
                    let found = all ?? agents()
                    all = found
                    let message = GlassesAgents.message(found.map(\.agent))
                    agentsContent = (GlassesRoutes.json(message), message)
                }
                if let content = agentsContent, content.core != session.lastAgents {
                    session.lastAgents = content.core
                    // The clock goes with what's sent, so "for 3m" can be counted on the glasses.
                    var message = content.message
                    message["now"] = Int(Date().timeIntervalSince1970)
                    session.peer.send(GlassesRoutes.json(message))
                }
            }
            if session.orchestrators {
                let message = orchestrators ?? orchestratorsMessage()
                orchestrators = message
                if message != session.lastOrchestrators {
                    session.lastOrchestrators = message
                    session.peer.send(message)
                }
            }
            if let tail = session.tail {
                let message = tailMessage(tail.id, lines: tail.lines)
                if message != session.lastTail {
                    session.lastTail = message
                    session.peer.send(message)
                }
            }
        }
    }

    /// An agent's latest words: its last answer from its transcript when it has one, or
    /// the end of its screen.
    private func tailMessage(_ id: UUID, lines: Int) -> String {
        guard let surface = surface(id) else {
            return GlassesRoutes.json(["t": "tail", "id": id.uuidString, "text": "", "gone": true])
        }
        if let answer = OrchestratorAnswers.last(surface), !answer.isEmpty {
            return GlassesRoutes.json(["t": "tail", "id": id.uuidString, "src": "answer",
                                       "text": GlassesText.tail(answer, lines: lines)])
        }
        return GlassesRoutes.json(["t": "tail", "id": id.uuidString, "src": "screen",
                                   "text": GlassesText.tail(surface.cachedVisibleContents.get(), lines: lines)])
    }
}
#endif
