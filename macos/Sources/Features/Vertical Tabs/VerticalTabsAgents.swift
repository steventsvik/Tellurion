#if os(macOS)
import AppKit

/// What a coding agent running in a pane is doing, as reported by its hooks.
enum VerticalTabAgentActivity: Equatable {
    case ready
    case working
    case needsPermission
    case needsInput
    case done
    case failed

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .working: return "Working"
        case .needsPermission: return "Needs permission"
        case .needsInput: return "Needs input"
        case .done: return "Done"
        case .failed: return "Error"
        }
    }

    var badge: VerticalTabBadge {
        switch self {
        case .ready: return .none
        case .working: return .working
        case .needsPermission: return .permission
        case .needsInput: return .input
        case .done: return .done
        case .failed: return .error
        }
    }
}

struct VerticalTabAgentInfo: Equatable {
    let kind: VerticalTabAgentKind
    var activity: VerticalTabAgentActivity
    /// The prompt the agent is working on.
    var task: String?
    /// What it's blocked on: the tool awaiting permission, or the question asked.
    var detail: String?
    /// A finished or blocked agent the user hasn't looked at yet.
    var unseen: Bool
    /// The session transcript, which the code editor tails to show the agent live.
    var transcriptPath: String?
    /// When `activity` last changed, for "working for 3m" in Mission Control.
    var since = Date()
    /// The most recent tool the agent used, e.g. "Edit: src/app.ts".
    var lastAction: String?
    /// Codex's exact session identity; prevents cross-talk between same-folder panes.
    var codexSessionID: String?
    /// The model, for Tellurion's local chat ("qwen3:4b").
    var localModel: String?

    /// The local model's name, or the agent's.
    var name: String { localModel ?? kind.displayName }
}

/// Receives agent status events and remembers the latest state per pane.
///
/// Events arrive as OSC 777 notifications titled `ghostty-extreme://agent` with a small
/// JSON body, emitted by the agents' hooks (see `agent-hooks/` in the repo root). The
/// core forwards these without rate limiting; we consume them here so they never
/// become desktop notifications.
final class VerticalTabsAgents {
    static let shared = VerticalTabsAgents()

    static let titlePrefix = "ghostty-extreme://"
    /// Posted (object: the surface) whenever a pane's agent state changes.
    static let didChange = Notification.Name("com.steventsvik.ghostty-extreme.agentDidChange")
    static let agentTitle = "ghostty-extreme://agent"

    private final class Box {
        var info: VerticalTabAgentInfo
        init(_ info: VerticalTabAgentInfo) { self.info = info }
    }

    /// Weak keys: a closed pane's agent state disappears with it.
    private let states = NSMapTable<Ghostty.SurfaceView, Box>.weakToStrongObjects()

    private struct Event: Decodable {
        let agent: String?
        let event: String
        let detail: String?
        let session: String?
    }

    func info(for surface: Ghostty.SurfaceView) -> VerticalTabAgentInfo? {
        states.object(forKey: surface)?.info
    }

    /// How many live panes have an agent matching `predicate`.
    func count(where predicate: (VerticalTabAgentInfo) -> Bool) -> Int {
        (states.objectEnumerator()?.allObjects as? [Box] ?? []).filter { predicate($0.info) }.count
    }

    /// Labels a pane with an agent that doesn't report status itself (e.g. a Hermes tab).
    func setStaticAgent(_ kind: VerticalTabAgentKind, task: String?, on surface: Ghostty.SurfaceView) {
        states.setObject(Box(VerticalTabAgentInfo(kind: kind, activity: .ready, task: task, detail: nil, unseen: false)),
                         forKey: surface)
        VerticalTabsTicker.shared.tickNow()
    }

    /// Clears the "unseen" flag once the user is looking at the pane.
    func markSeen(_ surface: Ghostty.SurfaceView) {
        guard let box = states.object(forKey: surface), box.info.unseen else { return }
        box.info.unseen = false
    }

    /// Returns true if the notification was an agent event (and so should not be shown).
    func handle(title: String, body: String, surface: Ghostty.SurfaceView) -> Bool {
        guard title.hasPrefix(Self.titlePrefix) else { return false }
        // Only events from this app's own hooks; printed text can't fake one (see EventToken).
        guard EventToken.verify(body) else { return true }
        if title == LocalhostSessions.eventTitle {
            LocalhostSessions.shared.handle(body: body, from: surface)
            return true
        }
        guard title == Self.agentTitle,
              let data = body.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data) else {
            // Unknown or malformed custom event: swallow it rather than show raw JSON.
            return true
        }
        // `tellurion doctor`'s test event: proves the hooks reach the app, changes nothing.
        if event.event == "check" {
            SetupChecks.shared.liveCheckArrived()
            return true
        }
        SetupChecks.shared.eventArrived()
        let before = info(for: surface)?.activity
        apply(event, to: surface)
        AgentAlerts.shared.agentChanged(on: surface, from: before, to: info(for: surface))
        VerticalTabsTicker.shared.tickNow()
        NotificationCenter.default.post(name: Self.didChange, object: surface)
        return true
    }

    /// A transcript's path from a "transcript" event: the path itself, or (when it was too
    /// long to send) a Claude Code session id, found in ~/.claude/projects.
    static func transcriptPath(_ detail: String, agent: String?) -> String? {
        if detail.hasPrefix("/") { return detail }
        guard agent == "claude", (8...64).contains(detail.count),
              detail.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        if let known = sessionPaths[detail] { return known }
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let path = root.appendingPathComponent(folder).appendingPathComponent(detail + ".jsonl").path
            if FileManager.default.fileExists(atPath: path) {
                sessionPaths[detail] = path
                return path
            }
        }
        return nil
    }

    private static var sessionPaths: [String: String] = [:]

    private func apply(_ event: Event, to surface: Ghostty.SurfaceView) {
        if event.agent == "codex", let session = event.session {
            let existing = states.object(forKey: surface)?.info
            if let current = existing?.codexSessionID, current != session, event.event != "session_start" {
                return
            }
            if event.event == "session_start", existing?.codexSessionID != session {
                states.setObject(Box(VerticalTabAgentInfo(kind: .codex, activity: .ready,
                    task: nil, detail: nil, unseen: false, transcriptPath: CodexTracking.reportedTranscript(session: session),
                    codexSessionID: session)), forKey: surface)
            } else if let box = states.object(forKey: surface) {
                box.info.codexSessionID = session
                if box.info.transcriptPath == nil { box.info.transcriptPath = CodexTracking.reportedTranscript(session: session) }
            }
        }
        // A local chat loads its model when it starts: the model list shows it loaded.
        if event.agent == "local", event.event == "session_start" || event.event == "session_end" {
            Task { @MainActor in LocalModelsModel.shared.load() }
        }
        if event.event == "session_end" {
            states.removeObject(forKey: surface)
            return
        }
        if event.event == "transcript" {
            guard let path = event.detail.flatMap({ Self.transcriptPath($0, agent: event.agent) }) else { return }
            if let box = states.object(forKey: surface) {
                box.info.transcriptPath = path
            } else {
                let kind = event.agent.map(VerticalTabAgentKind.init(id:)) ?? .unknown
                states.setObject(Box(VerticalTabAgentInfo(
                    kind: kind, activity: .ready, task: nil, detail: nil, unseen: false,
                    transcriptPath: path)), forKey: surface)
            }
            return
        }

        let activity: VerticalTabAgentActivity
        switch event.event {
        case "session_start": activity = .ready
        case "prompt_submit", "tool_complete": activity = .working
        case "tool_start" where event.agent == "codex": activity = .working
        case "permission_request": activity = .needsPermission
        case "input_needed": activity = .needsInput
        case "stop": activity = .done
        case "stop_failure": activity = .failed
        default: return
        }

        let existing = states.object(forKey: surface)?.info
        let kind = event.agent.map(VerticalTabAgentKind.init(id:)) ?? existing?.kind ?? .unknown
        let eventDetail = event.detail?.isEmpty == false ? event.detail : nil
        let task = event.event == "prompt_submit" ? eventDetail : existing?.task
        let detail = activity == .needsPermission || activity == .needsInput ? eventDetail : nil
        let needsEyes = activity != .working && activity != .ready
        let lastAction = event.event == "tool_complete" || event.event == "permission_request" ||
            (event.event == "tool_start" && kind == .codex)
            ? eventDetail ?? existing?.lastAction : existing?.lastAction
        let info = VerticalTabAgentInfo(
            kind: kind,
            activity: activity,
            task: task,
            detail: detail,
            unseen: needsEyes && !Self.isBeingViewed(surface),
            transcriptPath: existing?.transcriptPath,
            since: existing?.activity == activity ? existing?.since ?? Date() : Date(),
            lastAction: lastAction,
            codexSessionID: kind == .codex ? event.session ?? existing?.codexSessionID : nil)

        var labeled = info
        // Tellurion's local chat names its model.
        labeled.localModel = event.agent == "local" ? event.session ?? existing?.localModel : nil
        if let box = states.object(forKey: surface) {
            box.info = labeled
        } else {
            states.setObject(Box(labeled), forKey: surface)
        }
    }

    /// True when the pane is focused in the frontmost window of the active app.
    static func isBeingViewed(_ surface: Ghostty.SurfaceView) -> Bool {
        guard NSApp.isActive, let window = surface.window, window.isKeyWindow else { return false }
        return window.firstResponder === surface
    }
}
#endif
