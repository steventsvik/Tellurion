#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// One changed file in an agent's work, parsed from a unified diff.
struct ReviewFile: Identifiable, Equatable {
    enum Status: String {
        case added = "A", modified = "M", deleted = "D", renamed = "R"
    }

    let path: String
    let oldPath: String?
    let status: Status
    let hunks: [ReviewHunk]
    let isBinary: Bool

    var id: String { path }
    var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

struct ReviewHunk: Identifiable, Equatable {
    let id: Int
    let header: String
    let lines: [ReviewLine]
}

struct ReviewLine: Identifiable, Equatable {
    enum Kind { case context, added, removed }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String

    /// Comments attach to the new line when there is one, otherwise the old line.
    var anchor: ReviewComment.Anchor {
        if let newNumber { return .init(side: .new, line: newNumber) }
        return .init(side: .old, line: oldNumber ?? 0)
    }
}

struct ReviewComment: Identifiable, Equatable {
    struct Anchor: Hashable {
        enum Side { case old, new }
        let side: Side
        let line: Int
    }

    let id = UUID()
    let path: String
    let anchor: Anchor
    let lineText: String
    var text: String
}

/// What the user decided about a file.
enum ReviewDecision: Equatable {
    case pending, accepted
}

/// An agent's changes waiting for review: everything it changed in the repository since
/// the review started (its first prompt, or the last time its work was accepted).
struct ReviewItem: Identifiable, Equatable {
    enum Stage: Equatable {
        /// The agent finished; the changes are ready to review.
        case ready
        /// Feedback was sent and the agent is working on it.
        case feedbackSent
        /// The agent is working again.
        case working
    }

    let id: UUID
    let repoRoot: String
    /// For a folder that isn't a git repository: the private repository its snapshots are
    /// kept in (see `ReviewInbox.shadowRepo`). nil for a real repository.
    var gitDir: String?
    let agent: VerticalTabAgentKind
    var task: String?
    var baseline: String
    var files: [ReviewFile] = []
    var decisions: [String: ReviewDecision] = [:]
    var comments: [ReviewComment] = []
    var updated = Date()
    var unseen = true
    var stage: Stage = .ready

    var repoName: String { (repoRoot as NSString).lastPathComponent }
    /// Commit and pull requests need a real repository.
    var isRepository: Bool { gitDir == nil }
    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
    func decision(_ file: ReviewFile) -> ReviewDecision { decisions[file.path] ?? .pending }
    func comments(on file: ReviewFile) -> [ReviewComment] { comments.filter { $0.path == file.path } }
}

/// Collects agents' finished work for review, and applies the user's decisions: undo a
/// file, send line comments back to the agent, commit, open a pull request.
///
/// A review starts when an agent begins working: the working tree is snapshotted (a tree
/// object written through a temporary index, so the user's own index is never touched).
/// When the agent stops, everything that differs from the snapshot is the agent's work.
/// Folders that aren't git repositories are snapshotted into a private repository kept
/// outside them, so their changes can be reviewed too.
final class ReviewInbox: ObservableObject {
    static let shared = ReviewInbox()
    static let windowID = "review-inbox"

    @Published private(set) var items: [ReviewItem] = []

    /// A review in progress for a pane, whether or not it has shown up in the inbox yet.
    private struct Tracker {
        let id: UUID
        let repoRoot: String
        var gitDir: String?
        var baseline: String
        weak var surface: Ghostty.SurfaceView?
    }

    private var trackers: [ObjectIdentifier: Tracker] = [:]
    /// Panes whose start-of-work snapshot is still being taken.
    private var starting: Set<ObjectIdentifier> = []
    /// Panes whose agent finished before that snapshot was ready.
    private var finishedWhileStarting: [ObjectIdentifier: (VerticalTabAgentKind, String?)] = [:]
    private var lastActivity: [ObjectIdentifier: VerticalTabAgentActivity] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.review", qos: .userInitiated)

    private init() {
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let surface = note.object as? Ghostty.SurfaceView else { return }
                self?.agentChanged(surface)
            }
            .store(in: &cancellables)
    }

    /// Starts listening for agent activity. Called once at launch.
    static func start() { _ = shared }

    var unseenCount: Int { items.filter { $0.unseen && $0.stage == .ready }.count }

    func item(for surface: Ghostty.SurfaceView) -> ReviewItem? {
        guard let tracker = trackers[ObjectIdentifier(surface)] else { return nil }
        return items.first { $0.id == tracker.id }
    }

    /// The snapshot the pane's current review started from (usually its agent's first prompt),
    /// when it's in the pane's own git repository.
    func baseline(for surface: Ghostty.SurfaceView) -> String? {
        guard let tracker = trackers[ObjectIdentifier(surface)], tracker.gitDir == nil else { return nil }
        return tracker.baseline
    }

    func surface(for item: ReviewItem) -> Ghostty.SurfaceView? {
        trackers.values.first { $0.id == item.id }?.surface
    }

    // MARK: Following agents

    private func agentChanged(_ surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        let info = VerticalTabsAgents.shared.info(for: surface)
        let previous = lastActivity[key]
        lastActivity[key] = info?.activity
        guard let info, info.kind != .hermes, ExtremeSettings.isOn(.review) else { return }

        switch info.activity {
        case .working, .needsPermission:
            guard previous != .working, previous != .needsPermission else { return }
            if let tracker = trackers[key] {
                // Back at work on an existing review.
                update(tracker.id) { if $0.stage != .feedbackSent { $0.stage = .working } }
            } else if let folder = surface.pwd {
                beginReview(for: surface, folder: folder)
            }
        case .done, .failed, .needsInput:
            guard previous != info.activity else { return }
            if let tracker = trackers[key] {
                refresh(tracker, agent: info.kind, task: info.task, announce: true)
            } else if starting.contains(key) {
                // Finished before the snapshot was taken; review once it is.
                finishedWhileStarting[key] = (info.kind, info.task)
            }
        default:
            break
        }
    }

    private func beginReview(for surface: Ghostty.SurfaceView, folder: String) {
        let key = ObjectIdentifier(surface)
        guard !starting.contains(key) else { return }
        starting.insert(key)
        queue.async {
            var root = AgentTools.repoRoot(of: folder)
            var gitDir: String?
            if root == nil, let shadow = Self.shadowRepo(for: folder) {
                root = folder
                gitDir = shadow
            }
            let tree = root.flatMap { Self.snapshot($0, gitDir: gitDir) }
            DispatchQueue.main.async {
                self.starting.remove(key)
                let finished = self.finishedWhileStarting.removeValue(forKey: key)
                guard let root, let tree, self.trackers[key] == nil else { return }
                let tracker = Tracker(id: UUID(), repoRoot: root, gitDir: gitDir, baseline: tree, surface: surface)
                self.trackers[key] = tracker
                if let finished { self.refresh(tracker, agent: finished.0, task: finished.1, announce: true) }
            }
        }
    }

    /// Recomputes the agent's changes; adds or updates its inbox entry.
    private func refresh(_ tracker: Tracker, agent: VerticalTabAgentKind? = nil, task: String? = nil, announce: Bool = false) {
        let baseline = tracker.baseline
        queue.async {
            guard let current = Self.snapshot(tracker.repoRoot, gitDir: tracker.gitDir) else { return }
            let files = Self.diff(from: baseline, to: current, in: tracker.repoRoot, gitDir: tracker.gitDir)
            DispatchQueue.main.async {
                if let index = self.items.firstIndex(where: { $0.id == tracker.id }) {
                    var item = self.items[index]
                    item.files = files
                    item.decisions = item.decisions.filter { path, _ in files.contains { $0.path == path } }
                    item.comments = item.comments.filter { comment in files.contains { $0.path == comment.path } }
                    if let task { item.task = task }
                    if announce {
                        item.updated = Date()
                        item.unseen = true
                        item.stage = .ready
                    }
                    if files.isEmpty { self.items.remove(at: index) } else { self.items[index] = item }
                } else if !files.isEmpty, let agent {
                    self.items.insert(ReviewItem(id: tracker.id, repoRoot: tracker.repoRoot, gitDir: tracker.gitDir,
                                                 agent: agent, task: task, baseline: baseline, files: files), at: 0)
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout ReviewItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Decisions

    func markSeen(_ item: ReviewItem) {
        update(item.id) { $0.unseen = false }
    }

    func setDecision(_ decision: ReviewDecision, for file: ReviewFile, in item: ReviewItem) {
        update(item.id) { $0.decisions[file.path] = decision }
    }

    func addComment(_ text: String, on line: ReviewLine, file: ReviewFile, in item: ReviewItem) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(item.id) {
            $0.comments.append(ReviewComment(path: file.path, anchor: line.anchor, lineText: line.text, text: trimmed))
        }
    }

    func removeComment(_ comment: ReviewComment, in item: ReviewItem) {
        update(item.id) { $0.comments.removeAll { $0.id == comment.id } }
    }

    /// Puts a file back the way it was before the agent touched it.
    func undo(_ file: ReviewFile, in item: ReviewItem) {
        let root = item.repoRoot
        let baseline = item.baseline
        let gitDir = item.gitDir
        queue.async {
            let fm = FileManager.default
            let target = (root as NSString).appendingPathComponent(file.path)
            switch file.status {
            case .added:
                try? fm.removeItem(atPath: target)
            case .renamed:
                try? fm.removeItem(atPath: target)
                if let old = file.oldPath {
                    Self.git(["restore", "--source=\(baseline)", "--worktree", "--", old], in: root, gitDir: gitDir)
                }
            case .modified, .deleted:
                Self.git(["restore", "--source=\(baseline)", "--worktree", "--", file.path], in: root, gitDir: gitDir)
            }
            DispatchQueue.main.async { self.refreshItem(item) }
        }
    }

    /// Recomputes every review of a project after its files changed outside the inbox,
    /// such as an agent's turn being undone.
    func refresh(root: String) {
        for item in items where item.repoRoot == root { refreshItem(item) }
    }

    private func refreshItem(_ item: ReviewItem) {
        if let tracker = trackers.values.first(where: { $0.id == item.id }) {
            refresh(tracker)
        } else {
            // The pane is gone; still recompute against the item's own baseline.
            refresh(Tracker(id: item.id, repoRoot: item.repoRoot, gitDir: item.gitDir, baseline: item.baseline, surface: nil))
        }
    }

    /// Everything looks good: the next review starts from here.
    func acceptAll(_ item: ReviewItem) {
        items.removeAll { $0.id == item.id }
        let key = trackers.first { $0.value.id == item.id }?.key
        queue.async {
            guard let tree = Self.snapshot(item.repoRoot, gitDir: item.gitDir) else { return }
            DispatchQueue.main.async {
                guard let key, var tracker = self.trackers[key] else { return }
                tracker = Tracker(id: UUID(), repoRoot: tracker.repoRoot, gitDir: tracker.gitDir, baseline: tree,
                                  surface: tracker.surface)
                self.trackers[key] = tracker
            }
        }
    }

    /// The prompt that carries the user's line comments back to the agent.
    func feedbackPrompt(for item: ReviewItem) -> String {
        var lines = ["I reviewed your changes. Please address these comments:"]
        for file in item.files {
            let comments = item.comments(on: file)
            guard !comments.isEmpty else { continue }
            lines.append("")
            lines.append(file.path)
            for comment in comments.sorted(by: { $0.anchor.line < $1.anchor.line }) {
                let side = comment.anchor.side == .old ? " (removed line)" : ""
                let code = comment.lineText.trimmingCharacters(in: .whitespaces)
                lines.append("- line \(comment.anchor.line)\(side) `\(AgentTools.clip(code, 120))`: \(comment.text)")
            }
        }
        let approved = item.files.filter { item.decision($0) == .accepted }.map(\.path)
        if !approved.isEmpty {
            lines.append("")
            lines.append("These files look good, leave them as they are: " + approved.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// Types the feedback into the agent's prompt and submits it.
    @MainActor
    func sendFeedback(_ item: ReviewItem) -> Bool {
        guard let surface = surface(for: item), let model = surface.surfaceModel, !item.comments.isEmpty else { return false }
        let prompt = feedbackPrompt(for: item)
        model.sendText(prompt)
        // Submit after the paste has landed in the agent's input.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
            model.sendKeyEvent(.init(key: .enter, action: .release))
        }
        update(item.id) {
            $0.comments = []
            $0.stage = .feedbackSent
            $0.unseen = false
        }
        return true
    }

    /// Commits the reviewed files (all of the agent's changes that are still there).
    func commit(_ item: ReviewItem, message: String, completion: @escaping (String?) -> Void) {
        let paths = item.files.flatMap { file in [file.path] + (file.oldPath.map { [$0] } ?? []) }
        queue.async {
            let add = AgentTools.git(["add", "-A", "--"] + paths, in: item.repoRoot)
            guard add.ok else {
                DispatchQueue.main.async { completion(add.error) }
                return
            }
            let commit = AgentTools.git(["commit", "-q", "-m", message, "--"] + paths, in: item.repoRoot)
            DispatchQueue.main.async {
                if commit.ok {
                    self.acceptAll(item)
                    completion(nil)
                } else {
                    completion((commit.error + commit.output).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    /// Pushes the branch and opens GitHub's pull request page, in a tab where it can be seen.
    func openPullRequest(_ item: ReviewItem) {
        let owner = surface(for: item).flatMap { TerminalWindows.controller(of: $0.window) }
            ?? TerminalWindows.front
        guard let owner else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = item.repoRoot
        config.initialInput = "git push -u origin HEAD && gh pr create --fill --web\n"
        TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config, title: "Pull request · \(item.repoName)")
    }

    func focusAgent(_ item: ReviewItem) {
        guard let surface = surface(for: item) else { return }
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
    }

    // MARK: Git

    /// A tree object with the working tree's current contents (tracked and untracked files,
    /// respecting .gitignore), written through a copy of the index so the real one is untouched.
    /// With `gitDir` (a private repository for a folder that isn't one), its own index is used.
    static func snapshot(_ root: String, gitDir: String? = nil) -> String? {
        let env: [String: String]
        var temp: String?
        if let gitDir {
            env = ["GIT_INDEX_FILE": gitDir + "/index"]
        } else {
            let indexPath = AgentTools.git(["rev-parse", "--git-path", "index"], in: root).output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let realIndex = indexPath.hasPrefix("/") ? indexPath : (root as NSString).appendingPathComponent(indexPath)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("ghostty-extreme-review-\(UUID().uuidString).index").path
            // Starting from the real index keeps git's stat cache, so only changed files are hashed.
            if FileManager.default.fileExists(atPath: realIndex) {
                try? FileManager.default.copyItem(atPath: realIndex, toPath: path)
            }
            temp = path
            env = ["GIT_INDEX_FILE": path]
        }
        defer { if let temp { try? FileManager.default.removeItem(atPath: temp) } }
        let prefix = gitArgs(root, gitDir)
        guard gitEnv(prefix + ["add", "-A"], in: root, env: env).ok else { return nil }
        let tree = gitEnv(prefix + ["write-tree"], in: root, env: env)
        let sha = tree.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return tree.ok && !sha.isEmpty ? sha : nil
    }

    private static func gitEnv(_ args: [String], in directory: String, env: [String: String]) -> AgentTools.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        for (key, value) in env { environment[key] = value }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return AgentTools.Result(status: -1, output: "", error: "\(error)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AgentTools.Result(status: process.terminationStatus,
                                 output: String(decoding: outData, as: UTF8.self),
                                 error: String(decoding: errData, as: UTF8.self))
    }

    static func diff(from base: String, to current: String, in root: String, gitDir: String? = nil) -> [ReviewFile] {
        guard base != current else { return [] }
        let text = git(["diff", "--no-color", "--no-ext-diff", "-M", "-U3", base, current], in: root, gitDir: gitDir).output
        return parse(text)
    }

    /// Git, against a private repository when there is one.
    @discardableResult
    static func git(_ args: [String], in root: String, gitDir: String?) -> AgentTools.Result {
        AgentTools.git(gitArgs(root, gitDir) + args, in: root)
    }

    private static func gitArgs(_ root: String, _ gitDir: String?) -> [String] {
        gitDir.map { ["--git-dir=\($0)", "--work-tree=\(root)"] } ?? []
    }

    // MARK: Folders that aren't repositories

    /// Build output and dependencies, never part of an agent's reviewable work.
    private static let shadowExcludes = [
        ".git/", "node_modules/", ".next/", ".nuxt/", ".svelte-kit/", "dist/", "build/", ".build/", "out/",
        "target/", ".venv/", "venv/", "__pycache__/", ".pytest_cache/", ".mypy_cache/", ".turbo/", ".cache/",
        ".parcel-cache/", "coverage/", "DerivedData/", "Pods/", ".gradle/", ".DS_Store", "*.log",
    ]

    /// A private repository that snapshots `folder` without touching it, kept under
    /// ~/.ghostty-extreme/review-shadows. nil for folders too broad or too big to snapshot.
    static func shadowRepo(for folder: String) -> String? {
        let folder = (folder as NSString).standardizingPath
        let home = NSHomeDirectory()
        let broad = ["/", home, home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Projects",
                     home + "/Developer", home + "/Library"]
        guard !broad.contains(folder), !home.hasPrefix(folder + "/"), isSmallProject(folder) else { return nil }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in folder.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let name = (folder as NSString).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let dir = home + "/.ghostty-extreme/review-shadows/\(name)-\(String(hash, radix: 16)).git"
        if !FileManager.default.fileExists(atPath: dir + "/HEAD") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard AgentTools.git(["init", "--bare", "-q", dir], in: home).ok else { return nil }
            try? FileManager.default.createDirectory(atPath: dir + "/info", withIntermediateDirectories: true)
            try? (shadowExcludes.joined(separator: "\n") + "\n").write(toFile: dir + "/info/exclude", atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Few enough files (outside dependency and build folders) to snapshot quickly.
    private static func isSmallProject(_ folder: String) -> Bool {
        let skipped: Set<String> = ["node_modules", ".next", ".git", "dist", "build", ".build", "target", ".venv",
                                    "venv", "__pycache__", "Pods", "DerivedData", ".cache", "coverage", "out"]
        let enumerator = FileManager.default.enumerator(atPath: folder)
        var count = 0
        while let item = enumerator?.nextObject() as? String {
            if skipped.contains((item as NSString).lastPathComponent) { enumerator?.skipDescendants(); continue }
            count += 1
            if count > 20_000 { return false }
        }
        return true
    }

    /// Parses `git diff` output into files, hunks and numbered lines.
    static func parse(_ text: String) -> [ReviewFile] {
        var files: [ReviewFile] = []
        var path = "", oldPath: String?, status = ReviewFile.Status.modified, binary = false
        var hunks: [ReviewHunk] = []
        var lines: [ReviewLine] = []
        var header = ""
        var oldLine = 0, newLine = 0, lineID = 0
        var inFile = false

        func finishHunk() {
            if !header.isEmpty { hunks.append(ReviewHunk(id: hunks.count, header: header, lines: lines)) }
            header = ""
            lines = []
        }
        func finishFile() {
            finishHunk()
            if inFile { files.append(ReviewFile(path: path, oldPath: oldPath, status: status, hunks: hunks, isBinary: binary)) }
            hunks = []
            oldPath = nil
            status = .modified
            binary = false
            inFile = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finishFile()
                inFile = true
                // "diff --git a/x b/x": the new path is the part after " b/".
                if let range = line.range(of: " b/", options: .backwards) { path = String(line[range.upperBound...]) }
                continue
            }
            guard inFile else { continue }
            if header.isEmpty {
                if line.hasPrefix("new file") { status = .added; continue }
                if line.hasPrefix("deleted file") { status = .deleted; continue }
                if line.hasPrefix("rename from ") { oldPath = String(line.dropFirst("rename from ".count)); status = .renamed; continue }
                if line.hasPrefix("rename to ") { path = String(line.dropFirst("rename to ".count)); continue }
                if line.hasPrefix("Binary files") { binary = true; continue }
                if line.hasPrefix("+++ b/") { path = String(line.dropFirst(6)); continue }
                if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("index ") || line.hasPrefix("similarity") || line.hasPrefix("old mode") || line.hasPrefix("new mode") { continue }
            }
            if line.hasPrefix("@@") {
                finishHunk()
                header = line
                // @@ -a,b +c,d @@
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Int(parts[1].dropFirst().split(separator: ",").first ?? "0") ?? 0
                    newLine = Int(parts[2].dropFirst().split(separator: ",").first ?? "0") ?? 0
                }
                continue
            }
            guard !header.isEmpty else { continue }
            lineID += 1
            if line.hasPrefix("+") {
                lines.append(ReviewLine(id: lineID, kind: .added, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(ReviewLine(id: lineID, kind: .removed, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                lines.append(ReviewLine(id: lineID, kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
        }
        finishFile()
        return files
    }
}
#endif
