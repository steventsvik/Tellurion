#if os(macOS)
import AppKit
import CryptoKit
import os

/// Tellurion on Even G2 glasses: the sidebar's projects and tabs, the chosen tab's screen,
/// answering a permission prompt, pressing a key in an agent's pane, and talking to an
/// agent or a project's orchestrator.
///
/// It's a second kind of client of the phone server (see `PhoneServer`), with the same
/// protection: the same local listener behind `tailscale serve`, the owner's Tailscale
/// login, and a paired device's token sent first. On top of that:
/// - A permission answer names the prompt it's for, and is dropped if the agent is showing
///   another one by then (`GlassesRules.answerRefusal`), or if the prompt isn't on screen.
/// - Text only ever goes to a pane with an agent in it, never one with a bare shell, and
///   never with control characters (`GlassesRules.sayRefusal`). The same goes for the few
///   keys the glasses may press (`GlassesKey`), which are also refused while the agent
///   shows a permission prompt (`GlassesRules.keyRefusal`).
/// - What the glasses hear is turned into text on this Mac and sent back to the glasses.
///   Nothing is done with it here: the glasses send a separate message once you confirm.
/// - Answers, messages and audio are limited per device.
final class GlassesServer {
    static let shared = GlassesServer()

    /// The protocol's version, in the hello reply. Glasses that say 1 in theirs are still
    /// sent version 1's list of agents.
    static let version = 2
    static let actionsPerMinute = 30.0
    /// A minute and a half of sound each minute.
    static let audioBytesPerMinute = Double(GlassesAudio.bytesPerSecond * 90)

    /// A connected device, as the phone server hands it over once it has said who it is.
    struct Peer {
        let id: ObjectIdentifier
        let device: PhoneDevice
        /// The protocol version its hello gave.
        var version = 1
        let send: (String) -> Void
        let isBackedUp: () -> Bool
        let close: () -> Void
    }

    /// The pane a device is reading: its last answer, or (`screen`) its screen as it is,
    /// `before` lines back.
    struct Reading {
        var id: UUID
        var lines: Int
        var screen = false
        var before = 0
    }

    final class Session {
        let peer: Peer
        var glance = false
        var orchestrators = false
        var tools = false
        var tail: Reading?
        var lastAgents = ""
        var lastTail = ""
        var lastOrchestrators = ""
        var lastTools = ""
        /// The tool whose page is open, what was last sent for it and when it was last built.
        var toolPage: GlassesTool?
        var lastToolPage = ""
        var toolPageBuilt = Date.distantPast
        /// What its last search found.
        var found: [GlassesSearchHit] = []
        var searching = false
        var utterance: Utterance?
        init(peer: Peer) { self.peer = peer }
    }

    final class Utterance {
        let transcriber: SpeechTranscriber
        var bytes = 0
        var lastPartial = Date.distantPast
        init(transcriber: SpeechTranscriber) { self.transcriber = transcriber }
    }

    private(set) var sessions: [ObjectIdentifier: Session] = [:]
    private var timer: Timer?
    /// Per device: answers and messages, and bytes of sound.
    private var actions: [String: GlassesRateLimiter] = [:]
    private var audio: [String: GlassesRateLimiter] = [:]
    static let log = StoredFile.logger("Glasses")

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
            session.tail = Reading(id: id, lines: lines)
            session.lastTail = ""
        case .screen(let id, let lines, let before):
            session.tail = Reading(id: id, lines: lines, screen: true, before: before)
            session.lastTail = ""
        case .untail:
            session.tail = nil
        case .tools(let on):
            session.tools = on
            session.lastTools = ""
        case .key(let id, let key):
            guard allowAction(session) else { return }
            press(key, in: id, for: session)
        case .tool(let tool):
            guard allowAction(session) else { return }
            open(tool, for: session)
        case .toolPage(let tool):
            session.toolPage = tool
            session.lastToolPage = ""
            session.toolPageBuilt = .distantPast
            if let tool { prepare(tool) }
        case .toolAction(let tool, let row, let action, let text):
            guard allowAction(session) else { return }
            perform(action, on: row, of: tool, text: text, for: session)
        case .orchestratorAction(let id, let action):
            guard allowAction(session) else { return }
            orchestrate(action, project: id, for: session)
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

    func allowAction(_ session: Session) -> Bool {
        let device = session.peer.device.id
        var limiter = actions[device] ?? GlassesRateLimiter(capacity: Self.actionsPerMinute, per: 60)
        let allowed = limiter.allow()
        actions[device] = limiter
        if !allowed { session.peer.send(Self.error("rate", "Too many at once. Wait a moment.")) }
        return allowed
    }

    // MARK: Agents

    /// Open classic windows and boards with each window's tabs in their own order.
    private func orderedControllers() -> [BaseTerminalController] {
        let open = PhoneServer.shared.openControllers
        var byWindow: [ObjectIdentifier: BaseTerminalController] = [:]
        var windows: [ObjectIdentifier] = []
        var groups: [ObjectIdentifier: [ObjectIdentifier]] = [:]
        for controller in open {
            guard let window = controller.window else { continue }
            let id = ObjectIdentifier(window)
            byWindow[id] = controller
            windows.append(id)
            if let tabs = window.tabGroup?.windows, tabs.count > 1 { groups[id] = tabs.map { ObjectIdentifier($0) } }
        }
        return GlassesOrder.tabOrder(windows) { groups[$0] }.compactMap { byWindow[$0] }
    }

    /// Every pane in an open classic window or board, in the app's own order: one with an
    /// agent, or a plain terminal.
    func panes() -> [(agent: GlassesAgent, surface: Ghostty.SurfaceView)] {
        var found: [(GlassesAgent, Ghostty.SurfaceView)] = []
        let home = NSHomeDirectory()
        for controller in orderedControllers() {
            let board = controller as? BoardController
            for surface in controller.surfaceTree {
                let info = VerticalTabsAgents.shared.info(for: surface)
                let title = TerminalWindows.title(of: surface, in: controller)
                var agent = GlassesAgent(id: surface.id, name: title ?? info?.name ?? (surface.title.isEmpty ? "Terminal" : surface.title),
                                         kind: info?.kind.rawValue ?? "", activity: info?.activity ?? .ready,
                                         unseen: info?.unseen ?? false, task: info?.task, detail: info?.detail,
                                         since: info?.since ?? Date(timeIntervalSince1970: 0))
                agent.isAgent = info != nil
                agent.agentName = info?.name
                if let folder = surface.pwd {
                    let root = ClassicOrchestrators.shared.root(of: folder)
                    agent.project = ProjectPath.displayName(root)
                    agent.group = GlassesProjects.project(root: root, name: ProjectPath.displayName(root), home: home)
                }
                guard info != nil else {
                    found.append((agent, surface))
                    continue
                }
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

    func surface(_ id: UUID) -> Ghostty.SurfaceView? {
        for controller in PhoneServer.shared.openControllers {
            if let match = controller.surfaceTree.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    private func answer(_ id: UUID, allow: Bool, prompt: String, for session: Session) {
        let found = panes().first { $0.agent.id == id && $0.agent.isAgent }
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

    /// One of the few keys the glasses may press, in a pane with an agent that isn't asking
    /// for permission. Logged without saying which key.
    private func press(_ key: GlassesKey, in id: UUID, for session: Session) {
        let target = surface(id)
        let info = target.flatMap { VerticalTabsAgents.shared.info(for: $0) }
        var message = GlassesRules.keyRefusal(hasAgent: info != nil, waitingForPermission: info?.activity == .needsPermission, key: key)
        var sent = false
        if message == nil, let target {
            sent = MainActor.assumeIsolated { Self.press(key, on: target) }
            message = sent ? "Pressed \(key.label)" : "That tab isn't ready for keys."
        }
        Self.log.info("Key from \(session.peer.device.id, privacy: .public): pressed \(sent)")
        session.peer.send(GlassesRoutes.json(["t": "keyed", "id": id.uuidString, "ok": sent, "message": message ?? ""]))
    }

    @MainActor
    private static func press(_ key: GlassesKey, on surface: Ghostty.SurfaceView) -> Bool {
        guard let model = surface.surfaceModel else { return false }
        let input: Ghostty.Input.Key
        var text: String?
        var mods: Ghostty.Input.Mods = []
        var codepoint: UInt32 = 0
        switch key {
        case .enter:
            input = .enter
            text = "\r"
        case .escape:
            input = .escape
            text = "\u{1b}"
        case .tab:
            input = .tab
            text = "\t"
        case .up: input = .arrowUp
        case .down: input = .arrowDown
        case .y:
            input = .y
            text = "y"
            codepoint = 121
        case .n:
            input = .n
            text = "n"
            codepoint = 110
        case .interrupt:
            input = .c
            mods = [.ctrl]
            codepoint = 99
        }
        model.sendKeyEvent(.init(key: input, action: .press, text: text, mods: mods, unshiftedCodepoint: codepoint))
        model.sendKeyEvent(.init(key: input, action: .release, mods: mods, unshiftedCodepoint: codepoint))
        return true
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

    /// A project's id on the wire: not its path. A pane's project goes by the same one.
    static func projectID(_ root: String) -> String { GlassesProjects.id(root) }

    /// The projects that have an orchestrator, or classic panes with agents it could run.
    func projectRoots() -> [String] {
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
            var project = GlassesOrchestrator(id: Self.projectID(root), name: ProjectPath.displayName(root),
                                              status: orchestrator?.status.line ?? "Not started")
            project.goal = orchestrator?.team.goal ?? ClassicOrchestrators.shared.record(root: root)?.goal
            guard let orchestrator else { return project.item() }
            let log = orchestrator.brain.log
            project.running = orchestrator.brain.running || orchestrator.brain.busy
            project.log = log.map { entry in
                (entry.kind == .user ? "You: " : entry.kind == .error ? "! " : "") + entry.text
            }
            project.says = log.last { $0.kind == .say }?.text
            project.last = log.last { $0.kind == .action }?.text
            project.members = orchestrator.labels().map { entry in
                let info = orchestrator.agentInfo(entry.pane)
                return .init(id: entry.pane, name: entry.label, role: orchestrator.role(of: entry.pane),
                             activity: info.map { GlassesAgents.activity($0.activity) }, detail: info?.detail ?? info?.task)
            }
            return project.item()
        }
        return GlassesRoutes.json(["t": "orch", "projects": projects])
    }

    /// Stop, carry on, wire all, clear: what the orchestrator's window has buttons for.
    private func orchestrate(_ action: GlassesOrchestratorAction, project id: String, for session: Session) {
        var message = "That project has no orchestrator or agents now."
        var done = false
        if let root = projectRoots().first(where: { PhoneDevices.equal(Self.projectID($0), id) }) {
            let existing = ClassicOrchestrators.shared.orchestrator(root: root)
            switch action {
            case .stop:
                existing?.brain.stop()
                done = existing != nil
                message = done ? "Stopped" : "It isn't running."
            case .clear:
                existing?.brain.clear()
                done = existing != nil
                message = done ? "Cleared" : "Nothing to clear."
            case .carryOn:
                if let goal = existing?.team.goal ?? ClassicOrchestrators.shared.record(root: root)?.goal, !goal.isEmpty {
                    ClassicOrchestrators.shared.open(root: root).command(goal)
                    done = true
                    message = "Carrying on"
                } else {
                    message = "It has no goal yet. Hold to give it one."
                }
            case .wireAll:
                let orchestrator = ClassicOrchestrators.shared.open(root: root)
                let agents = ClassicOrchestrators.shared.wireChoices(for: orchestrator).first { $0.id == orchestrator.root }?.agents ?? []
                let fresh = agents.filter { !orchestrator.isWired($0) }
                if !fresh.isEmpty { orchestrator.wire(fresh) }
                done = !fresh.isEmpty
                message = fresh.isEmpty ? "Everyone is wired already." : "Wired \(fresh.count)"
            }
        }
        Self.log.info("Orchestrator \(action.rawValue, privacy: .public) from \(session.peer.device.id, privacy: .public): done \(done)")
        session.peer.send(GlassesRoutes.json(["t": "did", "ok": done, "message": message]))
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
        let wanted = sessions.values.contains { $0.glance || $0.orchestrators || $0.tools || $0.tail != nil || $0.toolPage != nil }
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
        var agentsContent: [Int: (core: String, message: [String: Any])] = [:]
        var orchestrators: String?
        var tools: String?
        var all: [GlassesAgent]?
        for session in sessions.values where !session.peer.isBackedUp() {
            if session.glance {
                let version = min(max(session.peer.version, 1), Self.version)
                if agentsContent[version] == nil {
                    let found = all ?? panes().map(\.agent)
                    all = found
                    let message = GlassesAgents.message(found, version: version)
                    agentsContent[version] = (GlassesRoutes.json(message), message)
                }
                if let content = agentsContent[version], content.core != session.lastAgents {
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
            if session.tools {
                let message = tools ?? toolsMessage(all ?? panes().map(\.agent))
                tools = message
                if message != session.lastTools {
                    session.lastTools = message
                    session.peer.send(message)
                }
            }
            // A tool's page: looked at again once a second, sent when it changed.
            if let tool = session.toolPage, Date().timeIntervalSince(session.toolPageBuilt) >= 1 {
                session.toolPageBuilt = Date()
                let message = GlassesRoutes.json(page(tool, for: session, panes: all ?? panes().map(\.agent)).message())
                if message != session.lastToolPage {
                    session.lastToolPage = message
                    session.peer.send(message)
                }
            }
            if let tail = session.tail {
                let message = tail.screen ? screenMessage(tail.id, lines: tail.lines, before: tail.before)
                    : tailMessage(tail.id, lines: tail.lines)
                if message != session.lastTail {
                    session.lastTail = message
                    session.peer.send(message)
                }
            }
        }
    }

    /// A pane's screen as it is: what's showing, or `before` lines up into its scrollback.
    private func screenMessage(_ id: UUID, lines: Int, before: Int) -> String {
        guard let surface = surface(id) else {
            return GlassesRoutes.json(["t": "tail", "id": id.uuidString, "text": "", "gone": true])
        }
        // What's on screen is the cheap one to read; the whole scrollback only to look back.
        // There may always be more above the screen: asking for it is how the glasses find out.
        let found = before == 0
            ? (text: GlassesText.screen(surface.cachedVisibleContents.get(), lines: lines).text, more: true)
            : GlassesText.screen(surface.cachedScreenContents.get(), lines: lines, before: before)
        var message: [String: Any] = ["t": "tail", "id": id.uuidString, "src": "screen", "before": before,
                                      "text": found.text, "more": found.more]
        // The agent's own last words, for when its screen is mostly its input box and status bar.
        if before == 0, let answer = OrchestratorAnswers.last(surface), !answer.isEmpty {
            message["ans"] = GlassesText.tail(answer, lines: 8, limit: 600)
        }
        return GlassesRoutes.json(message)
    }

    /// The Tools row's numbers, from what the sidebar and the tools already keep.
    private func toolsMessage(_ panes: [GlassesAgent]) -> String {
        var tools = GlassesTools()
        if TellurionSettings.isOn(.usage) {
            tools.usage = UsageMonitor.shared.entries.map { entry in
                .init(name: entry.name, windows: entry.windows.map { .init(label: $0.label, percent: $0.usedPercent, resets: $0.resetsAt) })
            }
        }
        if TellurionSettings.isOn(.localhost) {
            tools.servers = LocalhostSessions.shared.sessions.filter { $0.state == .live }.compactMap { session in
                guard let url = session.url, let host = url.host else { return nil }
                let address = host + (url.port.map { ":\($0)" } ?? "") + (url.path == "/" ? "" : url.path)
                return .init(name: session.project.name, address: address,
                             project: GlassesProjects.id(ClassicOrchestrators.shared.root(of: session.cwd)))
            }
        }
        if TellurionSettings.isOn(.review) { tools.review = ReviewInbox.shared.items.filter { $0.stage == .ready }.count }
        let names = GlassesAgents.names(panes)
        for (pane, name) in zip(panes, names) where pane.isAgent {
            if pane.check?.state == "failed" { tools.failedChecks.append(name) }
            if let budget = pane.budget { tools.budgets.append(.init(name: name, fraction: budget.fraction)) }
        }
        tools.conflicts = Set(AgentConflicts.shared.byPane.values.flatMap { $0.map(\.id) }).count
        var message = tools.message()
        message["list"] = toolList(tools, panes: panes)
        return GlassesRoutes.json(message)
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
