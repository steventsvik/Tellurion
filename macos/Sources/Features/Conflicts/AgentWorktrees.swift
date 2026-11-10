#if os(macOS)
import AppKit

/// A worktree per agent: when a group starts on a board, each of its agents can get its own
/// copy of the repository on its own new branch, so they can't overwrite each other.
///
/// The worktrees live under ~/.ghostty-extreme/worktrees, outside the repository. Each
/// starts from the current commit; uncommitted changes aren't copied. What was created is
/// written to worktrees.json there, for the Worktrees list.
enum AgentWorktrees {
    /// Where the worktrees and their list are kept.
    static var directory: URL { AgentTools.root.appendingPathComponent("worktrees", isDirectory: true) }

    static let log = StoredFile.logger("Worktrees")

    /// Runs git in a folder. The app's own (`house`) has the guards and never prompts; tests
    /// pass a stand-in.
    typealias Git = (_ arguments: [String], _ directory: String) -> AgentTools.Result

    static let house: Git = { arguments, directory in AgentTools.git(arguments, in: directory) }

    struct Failure: Error, Equatable {
        let message: String
    }

    /// One worktree Tellurion made.
    struct Record: Codable, Identifiable, Equatable {
        var id = UUID()
        /// The repository it's a worktree of.
        let root: String
        /// The worktree's own folder.
        let path: String
        let branch: String
        /// The commit it started from.
        let base: String
        /// The branch that was checked out in the repository then, if one was.
        var baseBranch: String?
        /// The folder inside the worktree its agent starts in (the worktree itself if nil).
        var start: String?
        /// The group it was made for, and the agent in it.
        let group: String
        let agent: String
        var board: UUID?
        var groupID: UUID?
        var tile: UUID?
        var created = Date()

        var startFolder: String { start ?? path }
        var repoName: String { (root as NSString).lastPathComponent }
    }

    // MARK: Names

    /// `text` as one part of a branch name: lowercase letters, digits, `.`, `_` and `-`,
    /// with everything else a dash. Never empty, never starting with a dash or a dot, never
    /// with two dots in a row, never ending in a dot or `.lock`.
    static func slug(_ text: String, fallback: String = "agent") -> String {
        var slug = ""
        for scalar in text.lowercased().unicodeScalars {
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-")
            let next: Character = allowed ? Character(scalar) : "-"
            // No runs of dashes, and no "..".
            let separator = next == "-" || next == "."
            if separator, let last = slug.last, last == "-" || last == "." { continue }
            slug.append(next)
        }
        slug = String(slug.prefix(40))
        while let first = slug.first, first == "-" || first == "." { slug.removeFirst() }
        var trimming = true
        while trimming {
            trimming = false
            if slug.hasSuffix(".lock") {
                slug.removeLast(5)
                trimming = true
            }
            if let last = slug.last, last == "-" || last == "." {
                slug.removeLast()
                trimming = true
            }
        }
        return slug.isEmpty ? fallback : slug
    }

    /// Whether `name` is a branch name this feature may hand to git: only letters, digits,
    /// `.`, `_`, `/` and `-`; no leading dash; no `..`; no empty, dotted or `.lock` parts.
    static func isValidBranch(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("-"), !name.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard name.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        for part in name.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part.hasPrefix(".") || part.hasPrefix("-") || part.hasSuffix(".") || part.hasSuffix(".lock") { return false }
        }
        return true
    }

    /// Whether git could hold both branches: not the same name (in any letter case, as
    /// branches are files on a disk that ignores it), and neither a folder of the other.
    static func collide(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    // MARK: Planning

    /// A worktree to make.
    struct Planned: Equatable {
        let agent: String
        let branch: String
        let path: String
    }

    /// The branches and folders for a group's agents: `tellurion/<group>/<agent>` and
    /// `<directory>/<repository>-<group>-<stamp>/<agent>/<repository>` (the folder is named
    /// after the repository, so a tile still says which project it's in). Names that are
    /// taken, by a branch that exists or by an earlier agent in the same group, get a number.
    static func plan(group: String, agents: [String], root: String, takenBranches: Set<String>,
                     stamp: String, directory: URL) -> [Planned] {
        let taken = Array(takenBranches)
        // "tellurion" itself can be a branch, which leaves no room for branches under it.
        let prefix = ["tellurion", "tellurion-agents", "tellurion-worktrees"].first { candidate in
            !taken.contains { $0.lowercased() == candidate || candidate.hasPrefix($0.lowercased() + "/") }
        } ?? "tellurion-\(stamp)"
        let groupSlug = slug(group, fallback: "group")
        // The group's part has to be free as a folder of branches too.
        var groupPart = groupSlug
        var number = 2
        while taken.contains(where: { $0.lowercased() == "\(prefix)/\(groupPart)" }) {
            groupPart = "\(groupSlug)-\(number)"
            number += 1
        }
        let repo = slug((root as NSString).lastPathComponent, fallback: "project")
        let home = directory.appendingPathComponent("\(repo)-\(groupSlug)-\(stamp)", isDirectory: true)
        var planned: [Planned] = []
        var branches = taken
        var folders: Set<String> = []
        for agent in agents {
            let agentSlug = slug(agent)
            var name = agentSlug
            var n = 2
            while branches.contains(where: { collide($0, "\(prefix)/\(groupPart)/\(name)") }) || folders.contains(name) {
                name = "\(agentSlug)-\(n)"
                n += 1
            }
            let branch = "\(prefix)/\(groupPart)/\(name)"
            branches.append(branch)
            folders.insert(name)
            planned.append(Planned(agent: agent, branch: branch,
                                   path: home.appendingPathComponent(name).appendingPathComponent(repo).path))
        }
        return planned
    }

    // MARK: Checking a folder

    /// Whether a folder can give each agent a worktree: the repository it's in, or why not.
    static func repository(of folder: String?, git: Git = house) -> Result<String, Failure> {
        guard let folder, !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else {
            return .failure(Failure(message: "Choose a folder in a git repository first."))
        }
        let top = git(["rev-parse", "--show-toplevel"], folder)
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.ok, !root.isEmpty else {
            return .failure(Failure(message: "This folder isn't in a git repository."))
        }
        guard git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], root).ok else {
            return .failure(Failure(message: "The repository has no commits yet."))
        }
        return .success(root)
    }

    // MARK: Creating

    /// Makes a worktree on a new branch for each of `agents`, all from the commit `folder`'s
    /// repository is on now. If any can't be made, the ones just made are removed again and
    /// nothing is left behind. Blocks: call off the main thread.
    static func create(group: String, agents: [String], folder: String, stamp: String = AgentTools.timestamp(),
                       directory: URL = AgentWorktrees.directory, git: Git = house) -> Result<[Record], Failure> {
        guard !agents.isEmpty else { return .failure(Failure(message: "There are no agents to make worktrees for.")) }
        let root: String
        switch repository(of: folder, git: git) {
        case .success(let found): root = found
        case .failure(let failure): return .failure(failure)
        }
        let head = git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], root)
        let base = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.ok, !base.isEmpty else { return .failure(Failure(message: "The repository has no commits yet.")) }
        let current = git(["symbolic-ref", "--quiet", "--short", "HEAD"], root)
        let baseBranch = current.ok ? current.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let listing = git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], root)
        guard listing.ok else { return .failure(Failure(message: "Couldn't list the repository's branches: \(clean(listing.error))")) }
        let branches = Set(listing.output.split(whereSeparator: \.isNewline).map(String.init))

        let planned = plan(group: group, agents: agents, root: root, takenBranches: branches, stamp: stamp, directory: directory)
        guard planned.allSatisfy({ isValidBranch($0.branch) }) else {
            return .failure(Failure(message: "Couldn't make branch names from this group's name."))
        }
        // Where in the repository the agents were going to start: the same place in each copy.
        let inside = subfolder(of: folder, in: root)
        var made: [Planned] = []
        for item in planned {
            let parent = (item.path as NSString).deletingLastPathComponent
            // Something already there isn't ours to replace (or, if this fails, to clean up).
            guard !FileManager.default.fileExists(atPath: item.path) else {
                undo(made, failed: nil, base: base, root: root, directory: directory, git: git)
                return .failure(Failure(message: "There's already something at \(item.path)."))
            }
            do {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                undo(made, failed: nil, base: base, root: root, directory: directory, git: git)
                return .failure(Failure(message: "Couldn't make \(parent): \(error.localizedDescription)"))
            }
            let add = git(["worktree", "add", "-q", "-b", item.branch, item.path, base], root)
            guard add.ok else {
                undo(made, failed: item, base: base, root: root, directory: directory, git: git)
                return .failure(Failure(message: "Couldn't make a worktree for \(item.agent): \(clean(add.error))"))
            }
            made.append(item)
        }
        return .success(made.map { item in
            var record = Record(root: root, path: item.path, branch: item.branch, base: base, group: group, agent: item.agent)
            record.baseBranch = baseBranch.isEmpty ? nil : baseBranch
            if let inside {
                let start = (item.path as NSString).appendingPathComponent(inside)
                var isFolder: ObjCBool = false
                // A folder with nothing committed in it isn't in the copy.
                if FileManager.default.fileExists(atPath: start, isDirectory: &isFolder), isFolder.boolValue { record.start = start }
            }
            return record
        })
    }

    /// `folder` relative to the repository's top, when it's below it.
    static func subfolder(of folder: String, in root: String) -> String? {
        let real = ConflictPaths.real(folder) ?? folder
        let top = ConflictPaths.real(root) ?? root
        guard real.hasPrefix(top + "/") else { return nil }
        return String(real.dropFirst(top.count + 1))
    }

    /// Takes back what a failed `create` made. The worktrees are minutes old and nothing has
    /// run in them, so they and their branches go without asking. The one that failed may be
    /// half made: its folder goes, and its branch only if git agrees it holds nothing new.
    private static func undo(_ made: [Planned], failed: Planned?, base: String, root: String, directory: URL, git: Git) {
        for item in made {
            _ = git(["worktree", "remove", "--force", item.path], root)
            _ = git(["branch", "-D", item.branch], root)
        }
        if let failed {
            _ = git(["worktree", "remove", "--force", failed.path], root)
            let tip = git(["rev-parse", "--verify", "--quiet", "refs/heads/\(failed.branch)"], root)
            if tip.ok, tip.output.trimmingCharacters(in: .whitespacesAndNewlines) == base {
                _ = git(["branch", "-D", failed.branch], root)
            }
        }
        _ = git(["worktree", "prune"], root)
        // The folders made for them, as long as nothing else is in them.
        for item in made + (failed.map { [$0] } ?? []) { removeEmptyFolders(above: item.path, within: directory) }
    }

    /// Removes the folders `create` made around a worktree once they're empty: the agent's,
    /// then the group's. Never anything outside the worktrees folder, never one with files.
    static func removeEmptyFolders(above path: String, within directory: URL = AgentWorktrees.directory) {
        let files = FileManager.default
        var folder = (path as NSString).deletingLastPathComponent
        for _ in 0..<2 {
            let limit = directory.path
            guard folder.hasPrefix(limit + "/"), folder != limit,
                  let contents = try? files.contentsOfDirectory(atPath: folder),
                  contents.filter({ $0 != ".DS_Store" }).isEmpty else { return }
            try? files.removeItem(atPath: folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
    }

    /// One line of what git said, for an error shown in the app.
    static func clean(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        let plain = line.hasPrefix("fatal: ") ? String(line.dropFirst(7)) : line
        return plain.isEmpty ? "git didn't say why." : String(plain.prefix(240))
    }

    // MARK: Looking at one

    /// What removing a worktree would lose.
    struct Standing: Equatable {
        /// Its folder is gone already (removed by hand).
        var missing = false
        /// Changes that aren't committed, including new files.
        var uncommitted = false
        /// Commits on its branch that aren't in the branch it started from or the one the
        /// repository is on now.
        var unmerged = 0
        /// Its branch is gone already.
        var branchMissing = false

        var hasWork: Bool { uncommitted || unmerged > 0 }

        /// "3 commits not merged, uncommitted changes".
        var summary: String {
            var parts: [String] = []
            if missing { parts.append("folder is gone") }
            if unmerged > 0 { parts.append("\(unmerged) \(unmerged == 1 ? "commit" : "commits") not merged") }
            if uncommitted { parts.append("uncommitted changes") }
            return parts.isEmpty ? "Nothing to lose: everything is merged" : parts.joined(separator: ", ")
        }
    }

    /// Looks at a worktree's folder and branch. Blocks: call off the main thread.
    static func standing(of record: Record, git: Git = house) -> Standing {
        var standing = Standing()
        standing.missing = !FileManager.default.fileExists(atPath: record.path)
        if !standing.missing {
            let status = git(["status", "--porcelain", "--untracked-files=normal"], record.path)
            // If git can't say, assume there's something: better to ask than to lose it.
            standing.uncommitted = !status.ok || !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard isValidBranch(record.branch),
              git(["rev-parse", "--verify", "--quiet", "refs/heads/\(record.branch)"], record.root).ok else {
            standing.branchMissing = true
            return standing
        }
        var into = ["HEAD"]
        if let base = record.baseBranch, isValidBranch(base),
           git(["rev-parse", "--verify", "--quiet", "refs/heads/\(base)"], record.root).ok {
            into.append("refs/heads/\(base)")
        }
        let count = git(["rev-list", "--count", "refs/heads/\(record.branch)", "--not"] + into, record.root)
        // Again: if git can't say, it counts as unmerged.
        standing.unmerged = count.ok ? Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1 : 1
        return standing
    }

    /// How a worktree is removed.
    enum Removal: Equatable {
        /// The folder and the branch, when nothing would be lost. Refused if anything would.
        case ifNothingIsLost
        /// The folder only; the branch and its commits stay. Refused with uncommitted changes.
        case keepingBranch
        /// The folder and the branch with whatever is in them: only ever the user's own choice.
        case discardingWork
    }

    /// Removes a worktree: `git worktree remove`, then its branch when that loses nothing
    /// (or when `how` says to discard it). Blocks: call off the main thread.
    static func remove(_ record: Record, how: Removal, git: Git = house) -> Result<Void, Failure> {
        let state = standing(of: record, git: git)
        switch how {
        case .ifNothingIsLost:
            if state.hasWork { return .failure(Failure(message: "It has work that isn't merged: \(state.summary).")) }
        case .keepingBranch:
            if state.uncommitted { return .failure(Failure(message: "It has uncommitted changes, which a branch can't keep.")) }
        case .discardingWork:
            break
        }
        if !state.missing {
            let arguments = how == .discardingWork ? ["worktree", "remove", "--force", record.path] : ["worktree", "remove", record.path]
            let removed = git(arguments, record.root)
            guard removed.ok else { return .failure(Failure(message: "Couldn't remove the worktree: \(clean(removed.error))")) }
        }
        _ = git(["worktree", "prune"], record.root)
        if !state.branchMissing, how != .keepingBranch, how == .discardingWork || state.unmerged == 0 {
            // Checked above: either nothing on it is unmerged, or the user chose to discard it.
            let deleted = git(["branch", "-D", record.branch], record.root)
            guard deleted.ok else { return .failure(Failure(message: "The folder is removed, but its branch isn't: \(clean(deleted.error))")) }
        }
        removeEmptyFolders(above: record.path)
        return .success(())
    }

    /// Everything the worktree's agent changed since it started, as a diff: commits and
    /// uncommitted changes, with new files named below. Blocks: call off the main thread.
    static func diff(of record: Record, git: Git = house) -> (text: String, error: String?) {
        guard FileManager.default.fileExists(atPath: record.path) else { return ("", "The worktree's folder is gone.") }
        let diff = git(["diff", "--no-color"] + AgentTools.diffGuards + ["-M", record.base], record.path)
        guard diff.ok else { return ("", "Couldn't compare with where it started: \(clean(diff.error))") }
        let untracked = git(["ls-files", "--others", "--exclude-standard"], record.path).output
            .split(whereSeparator: \.isNewline).map(String.init)
        var text = diff.output
        if !untracked.isEmpty {
            text += (text.isEmpty ? "" : "\n") + "New files not added yet:\n" + untracked.prefix(200).map { "  \($0)" }.joined(separator: "\n")
        }
        return (text, nil)
    }
}

/// The worktrees Tellurion made, kept in ~/.ghostty-extreme/worktrees/worktrees.json.
final class AgentWorktreeList: ObservableObject {
    static let shared = AgentWorktreeList()

    @Published private(set) var records: [AgentWorktrees.Record]

    private let file: URL

    init(file: URL = AgentWorktrees.directory.appendingPathComponent("worktrees.json")) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = StoredFile.loadList(AgentWorktrees.Record.self, from: file, what: "the worktrees list",
                                      log: AgentWorktrees.log, decoder: decoder).value ?? []
    }

    func add(_ new: [AgentWorktrees.Record]) {
        records.append(contentsOf: new)
        save()
    }

    /// Notes which board, group and tiles a group's worktrees went to, once they've started.
    func attach(_ ids: [UUID], board: UUID, group: UUID?, tiles: [UUID]) {
        for (offset, id) in ids.enumerated() {
            guard let index = records.firstIndex(where: { $0.id == id }) else { continue }
            records[index].board = board
            records[index].groupID = group
            if offset < tiles.count { records[index].tile = tiles[offset] }
        }
        save()
    }

    func forget(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = StoredFile.encoder
        encoder.dateEncodingStrategy = .iso8601
        StoredFile.write(json: records, to: file, what: "the worktrees list", log: AgentWorktrees.log, encoder: encoder)
    }
}
#endif
