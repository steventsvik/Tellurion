#if os(macOS)
import AppKit
import Combine
import UserNotifications

/// The conflict radar: warns when two agents are changing the same file in the same
/// working copy.
///
/// Each agent pane's changed files are collected from its status events (see
/// `ConflictSources`) and kept in a `ConflictLedger`. Two panes conflict on a file when both
/// changed it, it's in the same directory tree for both (the same git working tree: two
/// worktrees of one repository are apart), and at least one of the changes was in the last
/// half hour. A file that's been committed since stops counting.
///
/// It only watches and tells: nothing is blocked. Off in Settings, it does no work.
final class AgentConflicts: ObservableObject {
    static let shared = AgentConflicts()

    /// Posted on the main thread whenever any pane's conflicts change.
    static let didChange = Notification.Name("com.steventsvik.ghostty-extreme.agentConflictsDidChange")

    /// A file this pane's agent changed that other agents changed too.
    struct Conflict: Identifiable, Equatable {
        /// Relative to `root`.
        let path: String
        /// The top of the working copy both agents are in.
        let root: String
        /// The display names of the other agents.
        let others: [String]

        var id: String { root + "\n" + path }
        var absolutePath: String { (root as NSString).appendingPathComponent(path) }
    }

    /// Each pane's conflicts, by the pane's id. Only panes that have any are in it.
    @Published private(set) var byPane: [UUID: [Conflict]] = [:]

    private struct Pane {
        weak var surface: Ghostty.SurfaceView?
        /// Bumped when the pane's session changes, so results on their way for the old one are dropped.
        var generation = 0
    }

    private enum Source {
        case transcript(String)
        case codexJournal(String)
    }

    private var panes: [UUID: Pane] = [:]
    private var ledger = ConflictLedger()
    private var hits: [UUID: [ConflictLedger.Hit]] = [:]
    private var announcements = ConflictAnnouncements()
    private var timer: Timer?
    private var checking = false
    private var checkAgain = false
    private var lastCheck = Date.distantPast
    private var lastChecked: Set<ConflictLedger.File> = []
    private var observer: NSObjectProtocol?

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.conflicts", qos: .utility)
    /// Used on `queue` only.
    private var roots = ConflictRoots()
    /// How far each pane's session records have been read. Used on `queue` only.
    private var tails: [UUID: [String: UInt64]] = [:]

    /// How far back a session's record is read the first time.
    private static let backlog: UInt64 = 1_048_576
    /// The most read from a record in one go.
    private static let maxRead = 4 * 1_048_576
    /// How often shared files are checked against the last commit while any are shared.
    private static let upkeep: TimeInterval = 60
    /// The most files of one working copy checked against the last commit at a time.
    private static let checkLimit = 200

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: TellurionSettings.featuresDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.object as? TellurionFeature == .conflicts, !TellurionSettings.isOn(.conflicts) else { return }
            self?.reset()
        }
    }

    // MARK: Asking

    /// The files `surface`'s agent changed that other agents changed too.
    func conflicts(for surface: Ghostty.SurfaceView) -> [Conflict] {
        guard TellurionSettings.isOn(.conflicts) else { return [] }
        return byPane[surface.id] ?? []
    }

    /// The other panes in `surface`'s conflicts (all of them, or only those on `conflict`).
    func others(for surface: Ghostty.SurfaceView, in conflict: Conflict? = nil) -> [Ghostty.SurfaceView] {
        var found: [Ghostty.SurfaceView] = []
        for hit in hits[surface.id] ?? [] where conflict == nil || (hit.file.root == conflict?.root && hit.file.path == conflict?.path) {
            for other in hit.others {
                guard let view = panes[other]?.surface, !found.contains(where: { $0 === view }) else { continue }
                found.append(view)
            }
        }
        return found
    }

    /// The name a pane's agent goes by: its tile's or tab's name, or else the agent's.
    static func name(of surface: Ghostty.SurfaceView) -> String? {
        guard let info = VerticalTabsAgents.shared.info(for: surface) else { return nil }
        return TerminalWindows.title(of: surface, in: TerminalWindows.controller(for: surface)) ?? info.name
    }

    // MARK: Following agents

    /// Called for every agent status event, on the main thread, after the pane's state was
    /// updated. Only finished tools that change files, and sessions starting or ending, matter.
    func note(event: String, detail: String?, session: String?, on surface: Ghostty.SurfaceView) {
        guard TellurionSettings.isOn(.conflicts) else { return }
        let id = surface.id
        switch event {
        case "session_start", "session_end":
            guard panes[id] != nil else { return }
            forget(id)
            refresh()
        case "tool_complete":
            let found = ConflictSources.edit(inEvent: event, detail: detail)
            guard found != .none, let info = VerticalTabsAgents.shared.info(for: surface) else { return }
            // Another Codex session's event in this pane isn't this agent's change.
            if info.kind == .codex, let session, let current = info.codexSessionID, current != session { return }
            var pane = panes[id] ?? Pane(surface: surface)
            pane.surface = surface
            panes[id] = pane
            let generation = pane.generation
            let folder = surface.pwd
            let source = Self.source(for: info)
            let now = Date()
            queue.async { [self] in
                var edits: [ConflictSources.Edit] = []
                if case .file(let raw) = found, let path = ConflictPaths.resolve(raw, folder: folder),
                   FileManager.default.fileExists(atPath: path) {
                    edits = [ConflictSources.Edit(path: path, folder: nil, date: now)]
                } else if let source {
                    // The event didn't say where (or named something that isn't there): the
                    // session's own record does.
                    edits = scan(source, pane: id)
                }
                let files = edits.compactMap { place($0, paneFolder: folder, now: now) }
                guard !files.isEmpty else { return }
                DispatchQueue.main.async { self.add(files, to: id, generation: generation) }
            }
        default:
            break
        }
    }

    private static func source(for info: VerticalTabAgentInfo) -> Source? {
        if info.kind == .codex {
            return info.codexSessionID.flatMap(CodexTracking.hookPath).map { Source.codexJournal($0) }
        }
        return info.transcriptPath.map { Source.transcript($0) }
    }

    private func add(_ files: [(file: ConflictLedger.File, date: Date)], to id: UUID, generation: Int) {
        guard TellurionSettings.isOn(.conflicts), let pane = panes[id], pane.generation == generation, pane.surface != nil else { return }
        for entry in files { ledger.record(entry.file, by: id, at: entry.date) }
        refresh()
    }

    /// A pane's session ended or a new one started: what it changed before is forgotten.
    private func forget(_ id: UUID) {
        ledger.forget(id)
        panes[id]?.generation += 1
        queue.async { self.tails[id] = nil }
    }

    /// The feature was turned off.
    private func reset() {
        for id in panes.keys { panes[id]?.generation += 1 }
        panes.removeAll()
        ledger = ConflictLedger()
        announcements = ConflictAnnouncements()
        lastChecked = []
        queue.async { self.tails.removeAll() }
        publish()
    }

    // MARK: Reading session records (on `queue`)

    private func scan(_ source: Source, pane: UUID) -> [ConflictSources.Edit] {
        switch source {
        case .codexJournal(let path):
            return read(path, pane: pane).flatMap(ConflictSources.codexEdits)
        case .transcript(let path):
            var edits = read(path, pane: pane).flatMap(ConflictSources.claudeEdits)
            // Claude Code's sub-agents keep their own transcripts beside the session's.
            let folder = (path as NSString).deletingPathExtension + "/subagents"
            let files = FileManager.default
            for name in (try? files.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                let file = folder + "/" + name
                if tails[pane]?[file] == nil {
                    // One that's been quiet for hours has nothing the radar still counts.
                    let modified = (try? files.attributesOfItem(atPath: file))?[.modificationDate] as? Date
                    guard let modified, Date().timeIntervalSince(modified) < ConflictLedger.maxAge else { continue }
                }
                edits += read(file, pane: pane).flatMap(ConflictSources.claudeEdits)
            }
            return edits
        }
    }

    /// The records added to `path` since it was last read for this pane; the first time, the
    /// ones in its last megabyte.
    private func read(_ path: String, pane: UUID) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var offset: UInt64
        var midLine = false
        if let known = tails[pane]?[path], known <= size {
            offset = known
        } else {
            offset = size > Self.backlog ? size - Self.backlog : 0
            midLine = offset > 0
        }
        guard size > offset else {
            tails[pane, default: [:]][path] = offset
            return []
        }
        try? handle.seek(toOffset: offset)
        var data = (try? handle.read(upToCount: Self.maxRead)) ?? Data()
        if midLine, let newline = data.firstIndex(of: 0x0A) {
            // Started in the middle of a line: from the next one.
            offset += UInt64(newline - data.startIndex + 1)
            data = data[(newline + 1)...]
        }
        let parsed = ConflictSources.records(in: data)
        // A line longer than one read is skipped rather than read again every time.
        let consumed = parsed.consumed == 0 && data.count >= Self.maxRead ? data.count : parsed.consumed
        tails[pane, default: [:]][path] = offset + UInt64(consumed)
        return parsed.records
    }

    /// Where a reported change is: the working copy it's in and its path there.
    private func place(_ edit: ConflictSources.Edit, paneFolder: String?, now: Date) -> (file: ConflictLedger.File, date: Date)? {
        guard let path = ConflictPaths.resolve(edit.path, folder: edit.folder ?? paneFolder) else { return nil }
        var root = roots.root(of: (path as NSString).deletingLastPathComponent, now: now)
        // Not in a repository: the pane's own folder is the tree.
        if root == nil, let paneFolder { root = ConflictPaths.real(paneFolder) }
        guard let root, let relative = ConflictPaths.relative(path, to: root) else { return nil }
        return (ConflictLedger.File(root: root, path: relative), min(edit.date ?? now, now))
    }

    // MARK: Working out conflicts

    /// Recomputes every pane's conflicts. Files more than one pane changed are first checked
    /// against the last commit (off the main thread), so one that was committed in between
    /// isn't reported.
    private func refresh() {
        let shared = Set(ledger.shared().keys)
        let now = Date()
        guard !shared.isEmpty, shared != lastChecked || now.timeIntervalSince(lastCheck) > 30 else {
            publish()
            return
        }
        if checking {
            checkAgain = true
            return
        }
        checking = true
        lastCheck = now
        lastChecked = shared
        var byRoot: [String: [String]] = [:]
        for file in shared where (byRoot[file.root]?.count ?? 0) < Self.checkLimit { byRoot[file.root, default: []].append(file.path) }
        queue.async {
            var clean: [String: Set<String>] = [:]
            for (root, paths) in byRoot {
                guard let changed = Self.changed(paths, in: root) else { continue }
                clean[root] = Set(paths).subtracting(changed)
            }
            DispatchQueue.main.async {
                for (root, paths) in clean { self.ledger.settle(root: root, clean: paths, before: now) }
                self.checking = false
                self.publish()
                if self.checkAgain {
                    self.checkAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// Which of `paths` differ from the last commit in `root` (or are untracked or ignored).
    /// Nil when git can't say: the folder isn't a repository.
    static func changed(_ paths: [String], in root: String) -> Set<String>? {
        let result = AgentTools.git(["--literal-pathspecs", "status", "--porcelain=v1", "-z", "--ignored",
                                     "--untracked-files=all", "--"] + paths, in: root)
        return result.ok ? ConflictPaths.changedPaths(porcelain: result.output) : nil
    }

    private func publish() {
        let now = Date()
        // Panes that closed, or whose agent is gone, take their changes with them.
        var names: [UUID: String] = [:]
        for (id, pane) in panes {
            if let surface = pane.surface, TerminalWindows.controller(for: surface) != nil, let name = Self.name(of: surface) {
                names[id] = name
            } else {
                panes[id] = nil
                announcements.forget(id)
                queue.async { self.tails[id] = nil }
            }
        }
        ledger.keep(only: Set(names.keys))
        ledger.expire(now: now)
        hits = ledger.conflicts(now: now)
        var result: [UUID: [Conflict]] = [:]
        for (pane, list) in hits {
            result[pane] = list.map { hit in
                Conflict(path: hit.file.path, root: hit.file.root, others: hit.others.compactMap { names[$0] })
            }
        }
        if result != byPane {
            byPane = result
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        announce(announcements.fresh(in: hits), names: names)
        updateTimer()
    }

    /// Runs only while more than one pane has changed the same file: conflicts go stale
    /// (thirty minutes without a change, a commit) with no event to say so.
    private func updateTimer() {
        let needed = !ledger.shared().isEmpty
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.upkeep, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Telling the user

    /// One notification per pair of agents, the first time they share a file.
    private func announce(_ fresh: [ConflictAnnouncements.Fresh], names: [UUID: String]) {
        for pair in fresh {
            guard let first = names[pair.first], let second = names[pair.second],
                  let surface = panes[pair.first]?.surface ?? panes[pair.second]?.surface else { continue }
            let title = first == second ? "Two agents are editing the same file" : "\(first) and \(second) are editing the same file"
            let body = pair.files.count == 1
                ? "\(pair.files[0].path) in \((pair.files[0].root as NSString).lastPathComponent)"
                : "\(ConflictText.files(pair.files.map(\.path))) in \((pair.files[0].root as NSString).lastPathComponent)"
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) { [surface] _, _ in
                center.getNotificationSettings { [surface] settings in
                    guard settings.authorizationStatus == .authorized else { return }
                    DispatchQueue.main.async { [weak surface] in
                        surface?.showUserNotification(title: title, body: body)
                    }
                }
            }
        }
    }

    /// Queues a one-line heads-up for `surface`'s agent and each agent it shares files with,
    /// naming the files and the others. Only ever on the user's click.
    func tellAgents(about surface: Ghostty.SurfaceView) {
        var involved = [surface] + others(for: surface)
        involved = involved.filter(Self.takesMessages)
        for pane in involved {
            let own = conflicts(for: pane)
            guard !own.isEmpty else { continue }
            let text = ConflictText.headsUp(paths: own.map(\.path), others: own.flatMap(\.others))
            AgentInbox.shared.deliver(text, to: pane, label: "Heads-up: \(ConflictText.files(own.map(\.path)))")
        }
    }

    /// Whether a pane's agent can be sent a message (Claude Code and Codex).
    static func takesMessages(_ surface: Ghostty.SurfaceView) -> Bool {
        let kind = VerticalTabsAgents.shared.info(for: surface)?.kind
        return kind == .claude || kind == .codex
    }

    /// Opens a conflict's file: in the tab's code editor when it has one, else in the app
    /// the file opens with.
    static func open(_ conflict: Conflict, from surface: Ghostty.SurfaceView) {
        let path = conflict.absolutePath
        if TellurionSettings.isOn(.editor), let controller = TerminalWindows.controller(for: surface) as? TerminalController,
           !HermesSessions.shared.isHermes(controller) {
            EditorPanel.shared.show(from: controller, folder: conflict.root)
            EditorPanel.shared.session(for: controller).webView.openFile(path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}

/// The top of the working copy a folder is in, remembered for a while: asking git each time
/// would cost two processes per changed file.
struct ConflictRoots {
    private var known: [String: (root: String?, at: Date)] = [:]
    /// Asks git. Real paths, so one tree reached through a symlink is still one tree.
    var find: (String) -> String? = { folder in
        AgentTools.repoRoot(of: folder).map { ConflictPaths.real($0) ?? $0 }
    }

    init() {}

    init(find: @escaping (String) -> String?) {
        self.find = find
    }

    /// The working tree `folder` is in, or nil if it isn't in a repository. A folder that's
    /// gone is looked up from the nearest one that's still there.
    mutating func root(of folder: String, now: Date = Date()) -> String? {
        var folder = folder
        while folder != "/" && !folder.isEmpty && !FileManager.default.fileExists(atPath: folder) {
            folder = (folder as NSString).deletingLastPathComponent
        }
        // "Not a repository" is asked again sooner: `git init` changes the answer.
        if let entry = known[folder], now.timeIntervalSince(entry.at) < (entry.root == nil ? 300 : 3600) { return entry.root }
        if known.count > 512 { known.removeAll() }
        let root = find(folder)
        known[folder] = (root, now)
        return root
    }
}
#endif
