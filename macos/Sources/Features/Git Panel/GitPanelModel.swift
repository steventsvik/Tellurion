#if os(macOS)
import Foundation

/// What the Git panel shows for one repository, and its actions. Every git command runs
/// off the main thread; results and errors come back as published state.
final class GitPanelModel: ObservableObject {
    struct Branch: Identifiable, Equatable {
        let name: String
        let isCurrent: Bool
        let age: String
        let upstream: String
        var id: String { name }
    }

    struct Stash: Identifiable, Equatable {
        let ref: String
        let message: String
        let age: String
        var id: String { ref }
    }

    struct Commit: Identifiable, Equatable {
        let hash: String
        let subject: String
        let age: String
        let author: String
        var id: String { hash }
    }

    let root: String
    @Published private(set) var branches: [Branch] = []
    @Published private(set) var stashes: [Stash] = []
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error: String?
    /// The last thing done, for a short confirmation line.
    @Published var notice: String?
    /// Set while GitButler manages the repository (git is on its workspace branch).
    @Published private(set) var butler: GitButler.Status?
    @Published private(set) var isButler = false
    /// The Graphite stack the current branch is in, top first; empty without Graphite.
    @Published private(set) var stack: [Graphite.Branch] = []

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.gitpanel", qos: .userInitiated)

    init(root: String) {
        self.root = root
    }

    var currentBranch: String? { branches.first { $0.isCurrent }?.name }

    func load() {
        let root = self.root
        queue.async { [weak self] in
            let branches = AgentTools.git(["for-each-ref", "--sort=-committerdate",
                                           "--format=%(refname:short)%09%(HEAD)%09%(committerdate:relative)%09%(upstream:short)",
                                           "refs/heads"], in: root).output
                .split(separator: "\n").compactMap { line -> Branch? in
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 4 else { return nil }
                    return Branch(name: f[0], isCurrent: f[1] == "*", age: f[2], upstream: f[3])
                }
            let stashes = AgentTools.git(["stash", "list", "--format=%gd%x09%s%x09%cr"], in: root).output
                .split(separator: "\n").compactMap { line -> Stash? in
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 3 else { return nil }
                    return Stash(ref: f[0], message: f[1], age: f[2])
                }
            let current = branches.first { $0.isCurrent }?.name
            let isButler = current == GitButler.workspaceBranch
            let butler = isButler ? GitButler.status(root) : nil
            let stack = !isButler && Graphite.isTracked(root)
                ? Graphite.state(root).map { Graphite.stack(containing: current ?? "", in: $0) } ?? [] : []
            let commits = AgentTools.git(["log", "-8", "--format=%h%x09%s%x09%cr%x09%an"], in: root).output
                .split(separator: "\n").compactMap { line -> Commit? in
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 4 else { return nil }
                    return Commit(hash: f[0], subject: f[1], age: f[2], author: f[3])
                }
            DispatchQueue.main.async {
                guard let self else { return }
                self.branches = branches
                self.stashes = stashes
                self.commits = commits
                self.isButler = isButler
                self.butler = butler
                self.stack = stack
                self.loaded = true
                for branch in stack where !branch.isTrunk { GitHubPulls.shared.fetch(root: root, branch: branch.name) }
                // A new branch has no cached answer yet, so this asks GitHub right away.
                if let branch = self.currentBranch { GitHubPulls.shared.fetch(root: root, branch: branch) }
            }
        }
    }

    // MARK: Actions

    func switchTo(_ branch: String) {
        run(["switch", branch], done: "On \(branch)")
    }

    /// Creates a branch from the current commit and switches to it.
    func createBranch(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let check = AgentTools.git(["check-ref-format", "--branch", name], in: root)
        guard check.ok else {
            error = "“\(name)” isn't a valid branch name."
            return
        }
        run(["switch", "-c", name], done: "Created \(name)")
    }

    /// Stashes uncommitted changes, including new files.
    func stashChanges() {
        run(["stash", "push", "--include-untracked", "-m", "Tellurion \(AgentTools.timestamp())"], done: "Changes stashed")
    }

    func apply(_ stash: Stash) { run(["stash", "apply", stash.ref], done: "Applied \(stash.ref)") }
    func pop(_ stash: Stash) { run(["stash", "pop", stash.ref], done: "Popped \(stash.ref)") }
    func drop(_ stash: Stash) { run(["stash", "drop", stash.ref], done: "Dropped \(stash.ref)") }

    // MARK: GitButler

    func butlerCommit(_ message: String, to branch: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let but = GitButler.binary else { return }
        run(but, ["commit", "-b", branch, "-m", message], done: "Committed to \(branch)")
    }

    func butlerNewBranch(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let but = GitButler.binary else { return }
        run(but, ["branch", "new", name], done: "Created \(name)")
    }

    func butlerPush(_ branch: String) {
        guard let but = GitButler.binary else { return }
        run(but, ["push", branch], done: "Pushed \(branch)")
    }

    func butlerUndo() {
        guard let but = GitButler.binary else { return }
        run(but, ["undo"], done: "Undid GitButler's last operation")
    }

    func openGitButler() {
        guard let but = GitButler.binary else { return }
        // Its window stays open for as long as you use it: started on its own and not waited
        // for, rather than as a command with a time limit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: but)
        process.arguments = ["gui"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = EventToken.scrubbed(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            self.error = "Couldn't open GitButler: \(error.localizedDescription)"
        }
    }

    /// Runs a Graphite command in a new tab: they can ask questions, and pushing needs your login.
    func graphiteInTab(_ args: String) {
        SetupChecks.openTab(running: "cd \(AgentTools.shellQuote(root)) && \(Graphite.binary.map(AgentTools.shellQuote) ?? "gt") \(args)")
    }

    private func run(_ args: [String], done: String) {
        run(nil, args, done: done)
    }

    /// Runs git, or `tool` when given, then reloads.
    private func run(_ tool: String?, _ args: [String], done: String) {
        busy = true
        error = nil
        notice = nil
        let root = self.root
        queue.async { [weak self] in
            let result = tool.map { ToolPath.run($0, args, in: root) } ?? AgentTools.git(args, in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if result.ok {
                    self.notice = done
                } else {
                    let message = (result.error.isEmpty ? result.output : result.error)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = tool.map { ($0 as NSString).lastPathComponent } ?? "git"
                    self.error = message.isEmpty ? "\(name) \(args.first ?? "") failed" : String(message.prefix(400))
                }
                VerticalTabsGit.shared.refreshNow(root: root)
                self.load()
            }
        }
    }
}
#endif
