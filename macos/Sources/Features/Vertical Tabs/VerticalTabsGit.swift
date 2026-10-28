#if os(macOS)
import AppKit
import Combine
import Foundation

/// Git branch and uncommitted diff size for a working directory.
struct VerticalTabsGitInfo: Equatable {
    let branch: String
    let added: Int
    let removed: Int
    /// Commits not yet pushed to / pulled from the upstream branch; nil without one.
    var ahead: Int?
    var behind: Int?
    /// Set in a jj repository: `branch` is then its nearest bookmark or the change's ID.
    var jj: JJ.Status?
}

/// Git info for the folders shown in the sidebar.
///
/// Cost is kept off the terminal's path: all filesystem and `git` work happens on a
/// background utility queue, each repository is polled at most once per interval no
/// matter how many tabs are in it, and polling only runs while the app is active.
final class VerticalTabsGit: ObservableObject {
    static let shared = VerticalTabsGit()

    /// Keyed by repository root.
    @Published private(set) var info: [String: VerticalTabsGitInfo] = [:]

    /// Main-thread cache of pwd → repo root ("" means not in a repo).
    private var rootForPwd: [String: String] = [:]

    /// Git dir for each known repo root.
    private var gitDirs: [String: String] = [:]

    /// How many sidebar rows currently display each pwd. Only repos with at least one
    /// displaying row are polled, so closed tabs stop costing anything.
    private var interest: [String: Int] = [:]
    private var inFlight: Set<String> = []

    private let pollInterval: TimeInterval = 10
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.git", qos: .utility)
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let gitPath: String = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshAll()
                self?.startTimer()
            }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.stopTimer() }
            .store(in: &cancellables)
        if NSApp.isActive { startTimer() }
    }

    /// Cached info for the repo containing `pwd`. Never touches the filesystem.
    func info(for pwd: String?) -> VerticalTabsGitInfo? {
        guard let pwd, let root = rootForPwd[pwd], !root.isEmpty else { return nil }
        return info[root]
    }

    /// The repository root containing `pwd`, once known. Never touches the filesystem.
    func root(for pwd: String?) -> String? {
        guard let pwd, let root = rootForPwd[pwd], !root.isEmpty else { return nil }
        return root
    }

    /// Re-reads one repository now (after a branch switch, a commit, an agent's turn).
    func refreshNow(root: String) {
        guard let gitDir = gitDirs[root] else { return }
        refresh(root: root, gitDir: gitDir)
    }

    /// A row started displaying `pwd`. Resolves its repository in the background.
    func track(_ pwd: String?) {
        guard let pwd else { return }
        interest[pwd, default: 0] += 1
        guard rootForPwd[pwd] == nil else { return }
        queue.async { [weak self] in
            let root = Self.repoRoot(containing: pwd)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rootForPwd[pwd] = root?.path ?? ""
                guard let root else { return }
                let isNew = self.gitDirs[root.path] == nil
                self.gitDirs[root.path] = root.gitDir
                if isNew { self.refresh(root: root.path, gitDir: root.gitDir) }
            }
        }
    }

    /// A row stopped displaying `pwd`.
    func untrack(_ pwd: String?) {
        guard let pwd, let count = interest[pwd] else { return }
        interest[pwd] = count > 1 ? count - 1 : nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        timer.tolerance = pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshAll() {
        let roots = Set(interest.keys.compactMap { rootForPwd[$0] }.filter { !$0.isEmpty })
        for root in roots {
            guard let gitDir = gitDirs[root] else { continue }
            refresh(root: root, gitDir: gitDir)
        }
    }

    private func refresh(root: String, gitDir: String) {
        guard !inFlight.contains(root) else { return }
        inFlight.insert(root)
        let gitPath = self.gitPath

        queue.async { [weak self] in
            let result: VerticalTabsGitInfo
            if JJ.isRepo(root), JJ.binary != nil, let status = JJ.status(root) {
                // Beside git, git's numbers are live; a jj-only repository has only jj's.
                let colocated = FileManager.default.fileExists(atPath: root + "/.git")
                let (added, removed) = colocated ? Self.diffStats(repo: root, gitPath: gitPath) : JJ.diffStats(root)
                result = VerticalTabsGitInfo(branch: status.label, added: added, removed: removed, jj: status)
            } else {
                var branch = Self.readBranch(gitDir: gitDir) ?? "HEAD"
                // GitButler's workspace: name the branches it has applied instead.
                if branch == GitButler.workspaceBranch {
                    let applied = GitButler.appliedBranches(root)
                    branch = applied.isEmpty ? "GitButler" : applied.count == 1 ? applied[0] : "\(applied[0]) +\(applied.count - 1)"
                }
                let (added, removed) = Self.diffStats(repo: root, gitPath: gitPath)
                // Ahead/behind is for the Git panel's badge; skipped when that's turned off.
                let counts = ExtremeSettings.isOn(.git) ? Self.aheadBehind(repo: root, gitPath: gitPath) : nil
                result = VerticalTabsGitInfo(branch: branch, added: added, removed: removed,
                                             ahead: counts?.ahead, behind: counts?.behind)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(root)
                if self.info[root] != result { self.info[root] = result }
            }
        }
    }

    struct RepoRoot {
        let path: String
        let gitDir: String
    }

    /// Walks up from `path` to find the repository. Handles worktrees and submodules,
    /// where `.git` is a file pointing at the real git directory, and jj repositories
    /// without a git repository beside them.
    static func repoRoot(containing path: String) -> RepoRoot? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if JJ.isRepo(dir.path), !fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return RepoRoot(path: dir.path, gitDir: dir.appendingPathComponent(".jj/repo/store/git").path)
            }
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return RepoRoot(path: dir.path, gitDir: dotGit.path)
                }
                if let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = contents.split(separator: "\n").first,
                   line.hasPrefix("gitdir: ") {
                    let target = String(line.dropFirst("gitdir: ".count))
                    let resolved = URL(fileURLWithPath: target, relativeTo: dir).standardizedFileURL
                    return RepoRoot(path: dir.path, gitDir: resolved.path)
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    private static func readBranch(gitDir: String) -> String? {
        let head = URL(fileURLWithPath: gitDir).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        // Detached HEAD: show the short hash.
        return String(trimmed.prefix(7))
    }

    /// Lines added/removed across staged and unstaged changes, via `git diff --shortstat HEAD`.
    /// `--no-optional-locks` keeps us from contending with the user's own git commands.
    private static func diffStats(repo: String, gitPath: String) -> (Int, Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repo, "--no-optional-locks"] + AgentTools.gitGuards + ["diff"] + AgentTools.diffGuards + ["--shortstat", "HEAD"]
        process.environment = AgentTools.gitEnvironment(in: repo)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (0, 0)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return (0, 0) }
        return (number(before: "insertion", in: output), number(before: "deletion", in: output))
    }

    /// Commits ahead of and behind the upstream branch (`git rev-list --left-right --count`).
    private static func aheadBehind(repo: String, gitPath: String) -> (ahead: Int, behind: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repo, "--no-optional-locks"] + AgentTools.gitGuards + ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"]
        process.environment = AgentTools.gitEnvironment(in: repo)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parts = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard process.terminationStatus == 0, parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    /// Parses e.g. "3 files changed, 10 insertions(+), 2 deletions(-)".
    private static func number(before word: String, in text: String) -> Int {
        for part in text.split(separator: ",") where part.contains(word) {
            let digits = part.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return 0
    }
}
#endif
