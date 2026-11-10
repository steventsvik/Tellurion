#if os(macOS)
import AppKit
import Combine
import CryptoKit

/// How a project's check went, or that it's running.
struct CheckResult: Equatable {
    enum State { case running, passed, failed, timedOut }

    var state: State
    /// The command that ran, as the user saved it.
    var command: String
    var started: Date
    var finished: Date?
    /// One short line: usually the last thing the command printed.
    var summary: String
}

/// Done means verified: when an agent finishes a turn that changed the project, the project's
/// own check (`npm test`, `swift build`, `make lint`) runs, and the agent's card says whether
/// it passed.
///
/// A project is a git repository, and its check is whatever the user saved for it in the
/// Checks window (see `ProjectCheckStore`); nothing in the repository can set or change it.
/// The command runs in the project's root through the user's login shell, off the main
/// thread, one run per project at a time (see `CheckScheduler`). Agents working in the same
/// project share its result.
///
/// Everything here is used from the main thread.
final class ProjectChecks: ObservableObject {
    static let shared = ProjectChecks()

    /// Posted on the main thread, with the pane as the object, whenever `result(for:)` may
    /// have changed for it.
    static let didChange = Notification.Name("com.steventsvik.ghostty-extreme.projectCheckDidChange")
    static let windowID = "checks"

    /// A check's latest run, with what the card and the log window say about it.
    struct Run: Equatable {
        var result: CheckResult
        /// The command's exit status, once it has one.
        var exitStatus: Int32?
        /// What set it off: "Codex's turn: fix the login form", "Run by hand".
        var triggeredBy: String
        /// Seconds the command was given.
        var timeout: TimeInterval
    }

    /// What asked for a run.
    struct Trigger {
        /// The pane whose agent finished a turn, or that the run was asked for from.
        weak var surface: Ghostty.SurfaceView?
        let label: String
        /// Set off by a finished turn, not by a button: only these send failures back by themselves.
        let automatic: Bool
    }

    @Published private(set) var store: ProjectCheckStore
    @Published private(set) var runs: [String: Run] = [:]
    /// Panes whose agent has started a new turn since their project's last result: that
    /// result isn't about their work any more.
    /// Not published by itself: most panes it changes for have no result showing.
    private var stale: Set<ObjectIdentifier> = []

    private var scheduler = CheckScheduler<Trigger>()
    private var rounds = AutoSendRounds<ObjectIdentifier>(limit: ProjectChecks.autoSendLimit)
    private var lastActivity: [ObjectIdentifier: VerticalTabAgentActivity] = [:]
    /// The project's files when a pane's current turn started.
    private var turnStart: [ObjectIdentifier: String] = [:]
    /// Counts a pane's turn starts and ends, so a late answer about an old turn is dropped.
    private var turnSerial: [ObjectIdentifier: Int] = [:]
    /// Folders whose repository is known.
    private var roots: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.checks", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []

    /// How many failures in a row go back to an agent by themselves.
    static let autoSendLimit = 3

    /// Starts listening for agent turns. Called once at launch.
    static func start() { _ = shared }

    private init() {
        store = ProjectCheckStore()
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let surface = note.object as? Ghostty.SurfaceView { self?.agentChanged(surface) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let controller = TerminalWindows.controller(of: note.object as? NSWindow) else { return }
                for surface in controller.surfaceTree { self?.forget(ObjectIdentifier(surface)) }
            }
            .store(in: &cancellables)
    }

    // MARK: Results

    /// The check result that covers `surface`'s agent's latest finished turn. Nil when the
    /// feature is off, its project has no check or hasn't run it, or the agent has started a
    /// new turn since.
    func result(for surface: Ghostty.SurfaceView) -> CheckResult? {
        run(for: surface)?.result
    }

    /// `result(for:)` with what set the run off and its exit status.
    func run(for surface: Ghostty.SurfaceView) -> Run? {
        guard TellurionSettings.isOn(.checks), !stale.contains(ObjectIdentifier(surface)),
              let root = project(of: surface) else { return nil }
        return runs[root]
    }

    /// Whether the project `folder` is in has a check saved.
    func hasCheck(forFolder folder: String) -> Bool {
        guard TellurionSettings.isOn(.checks), let root = root(forFolder: folder) else { return false }
        return store.check(for: root) != nil
    }

    /// The project a pane is in, if it's one that's known: a repository found before, or a
    /// folder inside a project with a saved check.
    func project(of surface: Ghostty.SurfaceView) -> String? {
        surface.pwd.flatMap(root(forFolder:))
    }

    func root(forFolder folder: String) -> String? {
        roots[folder] ?? store.root(containing: folder)
    }

    /// Where a project's log is kept: `~/.ghostty-extreme/checks/logs/<name>-<hash>.log`.
    static func logFile(for root: String, in folder: URL = ProjectCheckStore.folder) -> URL {
        let key = ProjectCheckStore.key(root)
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = (key as NSString).lastPathComponent.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return folder.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(name.isEmpty ? "project" : String(name.prefix(40)))-\(hash).log")
    }

    // MARK: Settings

    /// Saves (or, with nil or an empty command, removes) a project's check. Returns whether
    /// it could be written.
    @discardableResult
    func save(_ check: ProjectCheck?, for root: String) -> Bool {
        let key = ProjectCheckStore.key(root)
        let before = store.check(for: key)?.command
        let saved = store.set(check, for: key)
        let after = store.check(for: key)?.command
        if after == nil { scheduler.dropWaiting(key) }
        // A result is about the command that ran. (A run that's still going is left to end.)
        if after != before, !scheduler.isRunning(key) { runs.removeValue(forKey: key) }
        announce(key)
        return saved
    }

    /// Records that `folder` is in the repository at `root` (found by the Checks window).
    func remember(root: String, forFolder folder: String) {
        roots[folder] = ProjectCheckStore.key(root)
    }

    // MARK: Following agents

    private func agentChanged(_ surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        let info = VerticalTabsAgents.shared.info(for: surface)
        let previous = lastActivity[key]
        lastActivity[key] = info?.activity
        guard TellurionSettings.isOn(.checks), let info, info.kind != .hermes, let folder = surface.pwd else { return }
        let wasBusy = previous == .working || previous == .needsPermission
        if info.activity == .working, !wasBusy {
            turnStarted(surface, folder: folder, prompt: info.task)
        } else if info.activity == .done, wasBusy {
            turnFinished(surface, folder: folder, info: info)
        }
    }

    private func turnStarted(_ surface: Ghostty.SurfaceView, folder: String, prompt: String?) {
        let key = ObjectIdentifier(surface)
        rounds.turnStarted(by: key, prompt: prompt)
        turnStart.removeValue(forKey: key)
        let turn = (turnSerial[key] ?? 0) + 1
        turnSerial[key] = turn
        // Whatever the last check said, it wasn't about the work starting now.
        if run(for: surface) != nil {
            objectWillChange.send()
            stale.insert(key)
            NotificationCenter.default.post(name: Self.didChange, object: surface)
        } else {
            stale.insert(key)
        }
        withRoot(of: folder) { [weak self] root in
            guard let self, let root, self.store.check(for: root) != nil else { return }
            self.queue.async {
                let files = CheckFingerprint.take(root)
                DispatchQueue.main.async {
                    guard self.turnSerial[key] == turn else { return }
                    self.turnStart[key] = files
                }
            }
        }
    }

    private func turnFinished(_ surface: Ghostty.SurfaceView, folder: String, info: VerticalTabAgentInfo) {
        let key = ObjectIdentifier(surface)
        let before = turnStart.removeValue(forKey: key)
        let turn = (turnSerial[key] ?? 0) + 1
        turnSerial[key] = turn
        let label = Self.label(agent: info.name, task: info.task)
        withRoot(of: folder) { [weak self, weak surface] root in
            guard let self, let surface, let root, self.store.check(for: root) != nil else { return }
            let trigger = Trigger(surface: surface, label: label, automatic: true)
            // Not known how the files were when the turn started: check.
            guard let before else {
                self.request(root, trigger)
                return
            }
            self.queue.async { [weak surface] in
                let after = CheckFingerprint.take(root)
                DispatchQueue.main.async {
                    guard let surface else { return }
                    if after == before {
                        // The turn changed no files: the last result still stands.
                        guard self.turnSerial[key] == turn, self.stale.contains(key) else { return }
                        self.objectWillChange.send()
                        self.stale.remove(key)
                        NotificationCenter.default.post(name: Self.didChange, object: surface)
                    } else {
                        self.request(root, trigger)
                    }
                }
            }
        }
    }

    /// "Codex's turn: fix the login form".
    static func label(agent: String, task: String?) -> String {
        let task = task.map { CheckOutput.short($0, 60) } ?? ""
        return task.isEmpty ? "\(agent)'s turn" : "\(agent)'s turn: \(task)"
    }

    private func forget(_ key: ObjectIdentifier) {
        lastActivity.removeValue(forKey: key)
        turnStart.removeValue(forKey: key)
        turnSerial.removeValue(forKey: key)
        rounds.forget(key)
        stale.remove(key)
    }

    /// Finds the repository `folder` is in (asking git once per folder) and calls back on the
    /// main thread; right away when it's known.
    private func withRoot(of folder: String, then: @escaping (String?) -> Void) {
        if let known = roots[folder] {
            then(known)
            return
        }
        queue.async {
            let root = AgentTools.repoRoot(of: folder).map(ProjectCheckStore.key)
            DispatchQueue.main.async {
                if let root { self.roots[folder] = root }
                then(root)
            }
        }
    }

    // MARK: Running

    /// Runs `root`'s saved check now (the Checks window's "Run now", the log's "Run again").
    func runNow(_ root: String, from surface: Ghostty.SurfaceView? = nil) {
        let key = ProjectCheckStore.key(root)
        guard TellurionSettings.isOn(.checks), store.check(for: key) != nil else { return }
        request(key, Trigger(surface: surface, label: "Run by hand", automatic: false))
    }

    func isRunning(_ root: String) -> Bool {
        scheduler.isRunning(ProjectCheckStore.key(root))
    }

    private func request(_ root: String, _ trigger: Trigger) {
        // The run that's coming covers this pane's latest turn.
        if let surface = trigger.surface, stale.contains(ObjectIdentifier(surface)) {
            objectWillChange.send()
            stale.remove(ObjectIdentifier(surface))
        }
        if let now = scheduler.request(root, trigger) {
            begin(root, now)
        } else {
            announce(root)
        }
    }

    private func begin(_ root: String, _ trigger: Trigger) {
        guard let check = store.check(for: root) else {
            // Removed while it waited.
            scheduler.dropWaiting(root)
            _ = scheduler.finished(root)
            runs.removeValue(forKey: root)
            announce(root)
            return
        }
        let started = Date()
        runs[root] = Run(result: CheckResult(state: .running, command: check.command, started: started, finished: nil,
                                             summary: "Running…"),
                         exitStatus: nil, triggeredBy: trigger.label, timeout: check.timeout)
        announce(root)
        let log = Self.logFile(for: root)
        DispatchQueue.global(qos: .utility).async {
            let outcome = CheckRunner.run(command: check.command, in: root, timeout: check.timeout, log: log)
            DispatchQueue.main.async {
                self.ended(root, check: check, trigger: trigger, started: started, outcome: outcome)
            }
        }
    }

    private func ended(_ root: String, check: ProjectCheck, trigger: Trigger, started: Date, outcome: CheckRunner.Outcome) {
        // Another turn finished meanwhile: only the run that follows counts.
        if let next = scheduler.finished(root) {
            begin(root, next)
            return
        }
        guard store.check(for: root) != nil else {
            runs.removeValue(forKey: root)
            announce(root)
            return
        }
        runs[root] = Run(result: CheckResult(state: outcome.state, command: check.command, started: started, finished: Date(),
                                             summary: outcome.summary),
                         exitStatus: outcome.status, triggeredBy: trigger.label, timeout: check.timeout)
        announce(root)
        guard outcome.state == .failed || outcome.state == .timedOut, trigger.automatic,
              TellurionSettings.isOn(.checks), store.check(for: root)?.autoSend == true,
              let surface = trigger.surface, Self.canReceive(surface) else { return }
        let key = ObjectIdentifier(surface)
        // Not once the agent is on to something else, and not round after round.
        guard !stale.contains(key), rounds.take(for: key) else { return }
        sendFailure(of: root, to: surface, round: rounds.used(by: key))
    }

    /// Tells everything showing `root`'s result that it changed.
    private func announce(_ root: String) {
        for (_, surface) in TerminalWindows.surfaces where project(of: surface) == root {
            NotificationCenter.default.post(name: Self.didChange, object: surface)
        }
    }

    // MARK: Sending a failure back

    /// Whether a message can be typed to the agent in `surface` (see `AgentInbox`).
    static func canReceive(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let kind = VerticalTabsAgents.shared.info(for: surface)?.kind else { return false }
        return kind == .claude || kind == .codex
    }

    /// Queues the failed run's command, exit status and last lines for the agent in `surface`
    /// (the log window's "Send to agent").
    func sendFailure(of root: String, to surface: Ghostty.SurfaceView) {
        rounds.sentByHand(to: ObjectIdentifier(surface))
        sendFailure(of: ProjectCheckStore.key(root), to: surface, round: nil)
    }

    private func sendFailure(of root: String, to surface: Ghostty.SurfaceView, round: Int?) {
        guard let run = runs[root], run.result.state == .failed || run.result.state == .timedOut else { return }
        let log = Self.logFile(for: root)
        queue.async { [weak surface] in
            let printed = String(decoding: CheckOutput.tail(of: log) ?? Data(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let surface else { return }
                let ending: CheckOutput.Ending = run.result.state == .timedOut ? .timedOut(run.timeout) : .exit(run.exitStatus ?? -1)
                let text = CheckOutput.failurePrompt(command: run.result.command, ending: ending, output: printed)
                let label = round.map { "Check failed (auto \($0) of \(Self.autoSendLimit))" } ?? "Check failed"
                AgentInbox.shared.deliver(text, to: surface, label: label)
            }
        }
    }
}
#endif
