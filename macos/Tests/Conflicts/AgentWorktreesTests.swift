import Foundation
import Testing
@testable import Ghostty

/// A worktree per agent: names, the plan, cleaning up after a failure, and the real thing
/// in a scratch repository.
struct AgentWorktreesTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("worktrees-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Real paths, as git reports them.
        return URL(fileURLWithPath: try #require(ConflictPaths.real(url.path)))
    }

    private func commitAll(_ root: String, _ message: String) -> Bool {
        AgentTools.git(["add", "-A"], in: root).ok
            && AgentTools.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", message], in: root).ok
    }

    /// A repository with one commit, and a folder beside it for the worktrees.
    private func repository() throws -> (top: URL, repo: URL, worktrees: URL) {
        let top = try scratch()
        let repo = top.appendingPathComponent("shop")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: repo.appendingPathComponent("src/app.txt"))
        #expect(AgentTools.git(["init", "-q"], in: repo.path).ok)
        #expect(commitAll(repo.path, "first"))
        return (top, repo, top.appendingPathComponent("made"))
    }

    private func branches(_ root: String) -> Set<String> {
        Set(AgentTools.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root).output
            .split(whereSeparator: \.isNewline).map(String.init))
    }

    // MARK: Names

    @Test func slugsAreSafeBranchParts() {
        #expect(AgentWorktrees.slug("Ada") == "ada")
        #expect(AgentWorktrees.slug("Ada 2") == "ada-2")
        #expect(AgentWorktrees.slug("Review squad!") == "review-squad")
        #expect(AgentWorktrees.slug("  --Front / End--  ") == "front-end")
        #expect(AgentWorktrees.slug("v1.2_rc") == "v1.2_rc")
        #expect(AgentWorktrees.slug("a..b") == "a.b")
        #expect(AgentWorktrees.slug("../../etc") == "etc")
        #expect(AgentWorktrees.slug("-rf") == "rf")
        #expect(AgentWorktrees.slug("team.lock") == "team")
        #expect(AgentWorktrees.slug("team.lock-") == "team")
        #expect(AgentWorktrees.slug("Команда") == "agent")
        #expect(AgentWorktrees.slug("", fallback: "group") == "group")
        #expect(AgentWorktrees.slug("~^:?*[\\ @{") == "agent")
        #expect(AgentWorktrees.slug(String(repeating: "x", count: 90)).count == 40)
    }

    @Test func everySlugMakesAValidBranch() {
        for text in ["Ada", "Ada 2", "..", "-", "a/b", "x.lock", "HEAD", "@{", "a b c", "ünï", "", ".hidden", "tab\there", "new\nline"] {
            let branch = "tellurion/\(AgentWorktrees.slug(text, fallback: "group"))/\(AgentWorktrees.slug(text))"
            #expect(AgentWorktrees.isValidBranch(branch), "\(branch)")
        }
    }

    @Test func branchNamesAreChecked() {
        for name in ["tellurion/team/ada", "tellurion/review-squad/otto-2", "main", "release/1.9.2", "a_b.c"] {
            #expect(AgentWorktrees.isValidBranch(name), "\(name)")
        }
        for name in ["", "-b", "--force", "a..b", "a b", "a~1", "a^", "a:b", "a?b", "a*b", "a[b", "a\\b", "a@{1}", "/a", "a/", "a//b",
                     "a/.b", ".a", "a.lock", "a.lock/b", "a/-b", "a.", "a/b.", "tellurion/tëam/ada", "a\nb", "a;rm -rf x", "$(x)"] {
            #expect(!AgentWorktrees.isValidBranch(name), "\(name)")
        }
    }

    @Test func branchesCollideByNameAnyCaseAndByFolder() {
        #expect(AgentWorktrees.collide("tellurion/team/ada", "tellurion/team/ada"))
        #expect(AgentWorktrees.collide("tellurion/team/ada", "Tellurion/Team/Ada"))
        // A branch can't also be a folder of branches.
        #expect(AgentWorktrees.collide("tellurion/team", "tellurion/team/ada"))
        #expect(AgentWorktrees.collide("tellurion/team/ada/x", "tellurion/team/ada"))
        #expect(!AgentWorktrees.collide("tellurion/team/ada", "tellurion/team/ada-2"))
        #expect(!AgentWorktrees.collide("tellurion/team/ada", "tellurion/teams/ada"))
    }

    // MARK: The plan

    private let made = URL(fileURLWithPath: "/srv/made", isDirectory: true)

    @Test func eachAgentGetsABranchAndAFolderNamedAfterTheRepository() {
        let plan = AgentWorktrees.plan(group: "Review squad", agents: ["Ada", "Otto", "Cy"], root: "/srv/My Shop",
                                       takenBranches: ["main"], stamp: "20260301-101530", directory: made)
        #expect(plan.map(\.agent) == ["Ada", "Otto", "Cy"])
        #expect(plan.map(\.branch) == ["tellurion/review-squad/ada", "tellurion/review-squad/otto", "tellurion/review-squad/cy"])
        #expect(plan.map(\.path) == [
            "/srv/made/my-shop-review-squad-20260301-101530/ada/my-shop",
            "/srv/made/my-shop-review-squad-20260301-101530/otto/my-shop",
            "/srv/made/my-shop-review-squad-20260301-101530/cy/my-shop",
        ])
        #expect(plan.allSatisfy { AgentWorktrees.isValidBranch($0.branch) })
    }

    @Test func takenNamesGetANumber() {
        // A branch from an earlier group, and two agents with the same name in this one.
        let plan = AgentWorktrees.plan(group: "Team", agents: ["Ada", "claude-1", "claude 1", "Otto"], root: "/srv/shop",
                                       takenBranches: ["main", "tellurion/team/ada", "Tellurion/Team/Otto", "tellurion/team/otto-2"],
                                       stamp: "s", directory: made)
        #expect(plan.map(\.branch) == ["tellurion/team/ada-2", "tellurion/team/claude-1", "tellurion/team/claude-1-2", "tellurion/team/otto-3"])
        #expect(Set(plan.map(\.path)).count == 4)
        #expect(Set(plan.map { $0.branch.lowercased() }).count == 4)
    }

    @Test func aBranchWhereTheGroupsFolderWouldBeMovesTheGroup() {
        let plan = AgentWorktrees.plan(group: "Team", agents: ["Ada"], root: "/srv/shop",
                                       takenBranches: ["tellurion/team", "tellurion/team-2"], stamp: "s", directory: made)
        #expect(plan.map(\.branch) == ["tellurion/team-3/ada"])
    }

    @Test func aBranchNamedLikeThePrefixMovesThePrefix() {
        let plan = AgentWorktrees.plan(group: "Team", agents: ["Ada", "Otto"], root: "/srv/shop",
                                       takenBranches: ["Tellurion"], stamp: "s", directory: made)
        #expect(plan.map(\.branch) == ["tellurion-agents/team/ada", "tellurion-agents/team/otto"])
    }

    @Test func namesWithNothingUsableStillMakeAPlan() {
        let plan = AgentWorktrees.plan(group: "…", agents: ["", "…", "!!"], root: "/", takenBranches: [], stamp: "s", directory: made)
        #expect(plan.map(\.branch) == ["tellurion/group/agent", "tellurion/group/agent-2", "tellurion/group/agent-3"])
        #expect(plan.allSatisfy { AgentWorktrees.isValidBranch($0.branch) })
        #expect(plan.first?.path == "/srv/made/project-group-s/agent/project")
    }

    // MARK: Cleaning up after a failure

    /// Git that records what it was asked and fails the second `worktree add`.
    private final class FakeGit {
        var calls: [[String]] = []
        var adds = 0
        let root: String
        init(root: String) { self.root = root }

        func run(_ arguments: [String], _ directory: String) -> AgentTools.Result {
            calls.append(arguments)
            switch Array(arguments.prefix(2)) {
            case ["rev-parse", "--show-toplevel"]: return .init(status: 0, output: root + "\n", error: "")
            case ["rev-parse", "--verify"]:
                // HEAD is there; the failed worktree's branch isn't.
                return arguments.last == "HEAD^{commit}" ? .init(status: 0, output: "abc123\n", error: "") : .init(status: 1, output: "", error: "")
            case ["symbolic-ref", "--quiet"]: return .init(status: 0, output: "main\n", error: "")
            case ["for-each-ref", "--format=%(refname:short)"]: return .init(status: 0, output: "main\n", error: "")
            case ["worktree", "add"]:
                adds += 1
                return adds == 2 ? .init(status: 128, output: "", error: "Preparing worktree\nfatal: could not create work tree dir\n")
                    : .init(status: 0, output: "", error: "")
            default: return .init(status: 0, output: "", error: "")
            }
        }
    }

    @Test func whenOneWorktreeFailsTheOnesJustMadeAreRemovedAndNothingIsReturned() throws {
        let top = try scratch()
        defer { try? FileManager.default.removeItem(at: top) }
        let directory = top.appendingPathComponent("made")
        let git = FakeGit(root: top.path)
        let result = AgentWorktrees.create(group: "Team", agents: ["Ada", "Otto", "Cy"], folder: top.path, stamp: "s",
                                           directory: directory, git: git.run)
        guard case .failure(let failure) = result else {
            Issue.record("It should have failed")
            return
        }
        #expect(failure.message == "Couldn't make a worktree for Otto: could not create work tree dir")
        let name = AgentWorktrees.slug(top.lastPathComponent, fallback: "project")
        let ada = directory.appendingPathComponent("\(name)-team-s/ada/\(name)").path
        let otto = directory.appendingPathComponent("\(name)-team-s/otto/\(name)").path
        // Two were tried, the third never.
        #expect(git.calls.filter { $0.prefix(2) == ["worktree", "add"] }.count == 2)
        #expect(git.calls.contains(["worktree", "add", "-q", "-b", "tellurion/team/ada", ada, "abc123"]))
        // The one that was made goes, with its branch.
        #expect(git.calls.contains(["worktree", "remove", "--force", ada]))
        #expect(git.calls.contains(["branch", "-D", "tellurion/team/ada"]))
        // The one that failed: whatever's left of its folder goes; its branch isn't there to delete.
        #expect(git.calls.contains(["worktree", "remove", "--force", otto]))
        #expect(!git.calls.contains(["branch", "-D", "tellurion/team/otto"]))
        #expect(!git.calls.contains { $0.contains("tellurion/team/cy") })
        #expect(git.calls.last == ["worktree", "prune"])
        // And the folders made for them are gone.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
    }

    @Test func aHalfMadeBranchIsDeletedOnlyIfItHoldsNothingNew() throws {
        let top = try scratch()
        defer { try? FileManager.default.removeItem(at: top) }
        var calls: [[String]] = []
        let git: AgentWorktrees.Git = { arguments, _ in
            calls.append(arguments)
            switch Array(arguments.prefix(2)) {
            case ["rev-parse", "--show-toplevel"]: return .init(status: 0, output: top.path, error: "")
            // Everything resolves to the commit it started from, the failed branch too.
            case ["rev-parse", "--verify"]: return .init(status: 0, output: "abc123\n", error: "")
            case ["worktree", "add"]: return .init(status: 1, output: "", error: "fatal: nope")
            default: return .init(status: 0, output: "main\n", error: "")
            }
        }
        let result = AgentWorktrees.create(group: "Team", agents: ["Ada"], folder: top.path, stamp: "s",
                                           directory: top.appendingPathComponent("made"), git: git)
        guard case .failure = result else {
            Issue.record("It should have failed")
            return
        }
        #expect(calls.contains(["branch", "-D", "tellurion/team/ada"]))
    }

    @Test func somethingAlreadyInTheWayIsNeverTouched() throws {
        let top = try scratch()
        defer { try? FileManager.default.removeItem(at: top) }
        let directory = top.appendingPathComponent("made")
        let name = AgentWorktrees.slug(top.lastPathComponent, fallback: "project")
        let existing = directory.appendingPathComponent("\(name)-team-s/ada/\(name)")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("keep.txt"))
        let git = FakeGit(root: top.path)
        let result = AgentWorktrees.create(group: "Team", agents: ["Ada"], folder: top.path, stamp: "s", directory: directory, git: git.run)
        guard case .failure = result else {
            Issue.record("It should have failed")
            return
        }
        #expect(!git.calls.contains { $0.first == "worktree" && $0.contains("remove") })
        #expect(!git.calls.contains { $0.prefix(2) == ["worktree", "add"] })
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("keep.txt").path))
    }

    @Test func gitsErrorIsOneCleanLine() {
        #expect(AgentWorktrees.clean("Preparing worktree (new branch 'x')\nfatal: 'x' already exists\n") == "'x' already exists")
        #expect(AgentWorktrees.clean("") == "git didn't say why.")
        #expect(AgentWorktrees.clean("  \n  error: boom  \n\n") == "error: boom")
    }

    // MARK: Which folders can

    @Test func aFolderNeedsToBeARepositoryWithACommit() throws {
        let top = try scratch()
        defer { try? FileManager.default.removeItem(at: top) }
        #expect(AgentWorktrees.repository(of: nil) == .failure(.init(message: "Choose a folder in a git repository first.")))
        #expect(AgentWorktrees.repository(of: "") == .failure(.init(message: "Choose a folder in a git repository first.")))
        #expect(AgentWorktrees.repository(of: top.path) == .failure(.init(message: "This folder isn't in a git repository.")))
        #expect(AgentTools.git(["init", "-q"], in: top.path).ok)
        #expect(AgentWorktrees.repository(of: top.path) == .failure(.init(message: "The repository has no commits yet.")))
        try Data("x".utf8).write(to: top.appendingPathComponent("a.txt"))
        #expect(commitAll(top.path, "first"))
        #expect(AgentWorktrees.repository(of: top.path) == .success(top.path))
        // From a folder inside it, too.
        let inner = top.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(AgentWorktrees.repository(of: inner.path) == .success(top.path))
        #expect(AgentWorktrees.subfolder(of: inner.path, in: top.path) == "inner")
        #expect(AgentWorktrees.subfolder(of: top.path, in: top.path) == nil)
    }

    // MARK: The real thing

    @Test func twoAgentsGetTwoWorktreesOnTheirOwnBranches() throws {
        let (top, repo, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: top) }
        // Work that isn't committed stays where it is.
        try Data("not committed\n".utf8).write(to: repo.appendingPathComponent("src/app.txt"))
        try Data("new\n".utf8).write(to: repo.appendingPathComponent("untracked.txt"))
        let before = AgentTools.git(["rev-parse", "HEAD"], in: repo.path).output.trimmingCharacters(in: .whitespacesAndNewlines)

        let result = AgentWorktrees.create(group: "Team", agents: ["Ada", "Otto"], folder: repo.appendingPathComponent("src").path,
                                           stamp: "s", directory: directory)
        guard case .success(let records) = result else {
            Issue.record("Couldn't make the worktrees: \(result)")
            return
        }
        #expect(records.map(\.branch) == ["tellurion/team/ada", "tellurion/team/otto"])
        #expect(records.map(\.agent) == ["Ada", "Otto"])
        #expect(records.allSatisfy { $0.root == repo.path && $0.base == before && $0.group == "Team" })
        #expect(branches(repo.path).isSuperset(of: ["tellurion/team/ada", "tellurion/team/otto"]))
        for record in records {
            #expect(record.path.hasPrefix(directory.path + "/"))
            #expect((record.path as NSString).lastPathComponent == "shop")
            // The committed file, as committed; nothing that wasn't.
            #expect(try String(contentsOfFile: record.path + "/src/app.txt", encoding: .utf8) == "first\n")
            #expect(!FileManager.default.fileExists(atPath: record.path + "/untracked.txt"))
            // It starts where the group was going to: the same folder inside its own copy.
            #expect(record.startFolder == record.path + "/src")
            let branch = AgentTools.git(["symbolic-ref", "--short", "HEAD"], in: record.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(branch == record.branch)
            // Its own tree, as the conflict radar sees it.
            #expect(AgentTools.repoRoot(of: record.startFolder) == record.path)
        }
        // The repository itself is as it was.
        #expect(try String(contentsOf: repo.appendingPathComponent("src/app.txt"), encoding: .utf8) == "not committed\n")
        #expect(AgentTools.git(["rev-parse", "HEAD"], in: repo.path).output.trimmingCharacters(in: .whitespacesAndNewlines) == before)

        // A second group of the same name takes the next names.
        let again = AgentWorktrees.create(group: "Team", agents: ["Ada"], folder: repo.path, stamp: "t", directory: directory)
        guard case .success(let more) = again else {
            Issue.record("Couldn't make another: \(again)")
            return
        }
        #expect(more.map(\.branch) == ["tellurion/team/ada-2"])
        #expect(more.first?.start == nil)
    }

    @Test func removingLosesNothingUnlessToldTo() throws {
        let (top, repo, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: top) }
        let result = AgentWorktrees.create(group: "Team", agents: ["Ada", "Otto", "Cy"], folder: repo.path, stamp: "s", directory: directory)
        guard case .success(let records) = result, records.count == 3 else {
            Issue.record("Couldn't make the worktrees: \(result)")
            return
        }
        let (ada, otto, cy) = (records[0], records[1], records[2])

        // Ada did nothing: it goes, branch and all.
        #expect(AgentWorktrees.standing(of: ada) == AgentWorktrees.Standing())
        #expect(AgentWorktrees.remove(ada, how: .ifNothingIsLost).isSuccess)
        #expect(!FileManager.default.fileExists(atPath: ada.path))
        #expect(!branches(repo.path).contains(ada.branch))

        // Otto committed something that isn't merged, and has a new file.
        try Data("otto\n".utf8).write(to: URL(fileURLWithPath: otto.path + "/src/app.txt"))
        #expect(commitAll(otto.path, "otto's work"))
        try Data("draft\n".utf8).write(to: URL(fileURLWithPath: otto.path + "/draft.txt"))
        let standing = AgentWorktrees.standing(of: otto)
        #expect(standing.unmerged == 1)
        #expect(standing.uncommitted)
        #expect(standing.summary == "1 commit not merged, uncommitted changes")
        #expect(!AgentWorktrees.remove(otto, how: .ifNothingIsLost).isSuccess)
        #expect(!AgentWorktrees.remove(otto, how: .keepingBranch).isSuccess)
        #expect(FileManager.default.fileExists(atPath: otto.path + "/draft.txt"))
        #expect(branches(repo.path).contains(otto.branch))
        // What it changed since it started, new file included.
        let diff = AgentWorktrees.diff(of: otto)
        #expect(diff.error == nil)
        #expect(diff.text.contains("+otto"))
        #expect(diff.text.contains("draft.txt"))
        // With the draft committed, the folder can go and the branch stay.
        #expect(commitAll(otto.path, "draft"))
        #expect(AgentWorktrees.remove(otto, how: .keepingBranch).isSuccess)
        #expect(!FileManager.default.fileExists(atPath: otto.path))
        #expect(branches(repo.path).contains(otto.branch))
        // Merged, its branch counts as nothing to lose.
        #expect(AgentTools.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "merge", "-q", "--no-edit", otto.branch],
                               in: repo.path).ok)
        let merged = AgentWorktrees.standing(of: otto)
        #expect(merged.missing && merged.unmerged == 0 && !merged.hasWork)
        #expect(AgentWorktrees.remove(otto, how: .ifNothingIsLost).isSuccess)
        #expect(!branches(repo.path).contains(otto.branch))

        // Cy's unmerged commit goes only when that's what was chosen.
        try Data("cy\n".utf8).write(to: URL(fileURLWithPath: cy.path + "/cy.txt"))
        #expect(commitAll(cy.path, "cy's work"))
        #expect(!AgentWorktrees.remove(cy, how: .ifNothingIsLost).isSuccess)
        #expect(branches(repo.path).contains(cy.branch))
        #expect(AgentWorktrees.remove(cy, how: .discardingWork).isSuccess)
        #expect(!FileManager.default.fileExists(atPath: cy.path))
        #expect(!branches(repo.path).contains(cy.branch))
    }

    // MARK: The list

    @Test func theListIsKeptInAFile() throws {
        let top = try scratch()
        defer { try? FileManager.default.removeItem(at: top) }
        let file = top.appendingPathComponent("worktrees.json")
        let list = AgentWorktreeList(file: file)
        #expect(list.records.isEmpty)
        let ada = AgentWorktrees.Record(root: "/srv/shop", path: "/srv/made/a/shop", branch: "tellurion/team/ada", base: "abc",
                                        group: "Team", agent: "Ada")
        var otto = AgentWorktrees.Record(root: "/srv/shop", path: "/srv/made/o/shop", branch: "tellurion/team/otto", base: "abc",
                                         group: "Team", agent: "Otto")
        otto.baseBranch = "main"
        otto.start = "/srv/made/o/shop/src"
        list.add([ada, otto])
        let board = UUID(), group = UUID(), tile = UUID()
        // One tile for two worktrees: the second just has none.
        list.attach([ada.id, otto.id], board: board, group: group, tiles: [tile])

        let loaded = AgentWorktreeList(file: file).records
        #expect(loaded.map(\.id) == [ada.id, otto.id])
        #expect(loaded.map(\.branch) == ["tellurion/team/ada", "tellurion/team/otto"])
        #expect(loaded.allSatisfy { $0.board == board && $0.groupID == group })
        #expect(loaded.map(\.tile) == [tile, nil])
        #expect(loaded[1].baseBranch == "main" && loaded[1].startFolder == "/srv/made/o/shop/src")
        #expect(loaded[0].startFolder == "/srv/made/a/shop")

        list.forget(ada.id)
        #expect(AgentWorktreeList(file: file).records.map(\.id) == [otto.id])
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
