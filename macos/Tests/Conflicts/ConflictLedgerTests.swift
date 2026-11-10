import Foundation
import Testing
@testable import Ghostty

/// The conflict radar's memory and rules: which paths are the same file, when two panes
/// conflict, when that expires, and that a pair hears about a file once.
struct ConflictLedgerTests {
    private typealias File = ConflictLedger.File

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conflicts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Real paths, as git reports them.
        return URL(fileURLWithPath: try #require(ConflictPaths.real(url.path)))
    }

    private func commitAll(_ root: String, _ message: String) -> Bool {
        AgentTools.git(["add", "-A"], in: root).ok
            && AgentTools.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", message], in: root).ok
    }

    // MARK: Paths

    @Test func relativePathsAreTakenFromThePanesFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("src/app.ts"))
        let expected = root.appendingPathComponent("src/app.ts").path
        #expect(ConflictPaths.resolve("src/app.ts", folder: root.path) == expected)
        #expect(ConflictPaths.resolve("./src/../src/app.ts", folder: root.path) == expected)
        #expect(ConflictPaths.resolve(expected, folder: "/somewhere/else") == expected)
        #expect(ConflictPaths.resolve("  src/app.ts\n", folder: root.path) == expected)
        // A relative path with nowhere to start from can't be placed.
        #expect(ConflictPaths.resolve("src/app.ts", folder: nil) == nil)
        #expect(ConflictPaths.resolve("", folder: root.path) == nil)
    }

    @Test func aFileReachedThroughASymlinkIsTheSameFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("a.txt"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ConflictPaths.resolve(link.appendingPathComponent("a.txt").path, folder: nil) == real.appendingPathComponent("a.txt").path)
        #expect(ConflictPaths.resolve("a.txt", folder: link.path) == real.appendingPathComponent("a.txt").path)
    }

    @Test func aFileThatIsGoneKeepsItsFoldersRealPath() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("project"))
        #expect(ConflictPaths.resolve("gone/deleted.txt", folder: link.path) == root.appendingPathComponent("project/gone/deleted.txt").path)
    }

    @Test func aPathIsRelativeOnlyInsideItsTree() {
        #expect(ConflictPaths.relative("/srv/shop/src/app.ts", to: "/srv/shop") == "src/app.ts")
        #expect(ConflictPaths.relative("/srv/shop/src/app.ts", to: "/srv/shop/") == "src/app.ts")
        #expect(ConflictPaths.relative("/srv/shop-two/src/app.ts", to: "/srv/shop") == nil)
        #expect(ConflictPaths.relative("/srv/shop", to: "/srv/shop") == nil)
        #expect(ConflictPaths.relative("/srv/other/app.ts", to: "/srv/shop") == nil)
        // Git's own files aren't anyone's work.
        #expect(ConflictPaths.relative("/srv/shop/.git/index", to: "/srv/shop") == nil)
        #expect(ConflictPaths.relative("/srv/shop/.github/ci.yml", to: "/srv/shop") == ".github/ci.yml")
    }

    @Test func gitStatusListsWhatDiffersFromTheLastCommit() {
        let porcelain = " M src/app.ts\0?? notes with spaces.md\0R  src/new.py\0src/old.py\0!! .env\0A  added.txt\0"
        #expect(ConflictPaths.changedPaths(porcelain: porcelain)
                == ["src/app.ts", "notes with spaces.md", "src/new.py", "src/old.py", ".env", "added.txt"])
        #expect(ConflictPaths.changedPaths(porcelain: "").isEmpty)
    }

    // MARK: The same tree, or not

    @Test func twoPanesOnOneFileInOneTreeConflict() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), now = Date()
        ledger.record(File(root: "/srv/shop", path: "src/cart.py"), by: ada, at: now.addingTimeInterval(-60))
        ledger.record(File(root: "/srv/shop", path: "src/cart.py"), by: otto, at: now.addingTimeInterval(-10))
        ledger.record(File(root: "/srv/shop", path: "src/only-ada.py"), by: ada, at: now)
        let conflicts = ledger.conflicts(now: now)
        #expect(conflicts[ada] == [ConflictLedger.Hit(file: File(root: "/srv/shop", path: "src/cart.py"), others: [otto])])
        #expect(conflicts[otto] == [ConflictLedger.Hit(file: File(root: "/srv/shop", path: "src/cart.py"), others: [ada])])
    }

    @Test func theSamePathInTwoWorktreesIsTwoFiles() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), now = Date()
        ledger.record(File(root: "/srv/shop", path: "src/cart.py"), by: ada, at: now)
        ledger.record(File(root: "/srv/worktrees/otto/shop", path: "src/cart.py"), by: otto, at: now)
        #expect(ledger.conflicts(now: now).isEmpty)
        #expect(ledger.shared().isEmpty)
    }

    @Test func onePaneAloneNeverConflicts() {
        var ledger = ConflictLedger()
        let ada = UUID(), now = Date()
        ledger.record(File(root: "/srv/shop", path: "a"), by: ada, at: now.addingTimeInterval(-5))
        ledger.record(File(root: "/srv/shop", path: "a"), by: ada, at: now)
        #expect(ledger.conflicts(now: now).isEmpty)
    }

    @Test func aRepositoryAndItsWorktreeAreDifferentTreesToGit() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repo.appendingPathComponent("src/app.ts"))
        #expect(AgentTools.git(["init", "-q"], in: repo.path).ok)
        #expect(commitAll(repo.path, "first"))
        let copy = root.appendingPathComponent("copy")
        #expect(AgentTools.git(["worktree", "add", "-q", "-b", "other", copy.path, "HEAD"], in: repo.path).ok)

        var roots = ConflictRoots()
        #expect(roots.root(of: repo.appendingPathComponent("src").path) == repo.path)
        #expect(roots.root(of: repo.path) == repo.path)
        #expect(roots.root(of: copy.appendingPathComponent("src").path) == copy.path)
        // A folder that's gone is looked up from the nearest one that's there.
        #expect(roots.root(of: repo.appendingPathComponent("src/deleted/deeper").path) == repo.path)
        // Outside any repository.
        #expect(roots.root(of: root.path) == nil)
    }

    @Test func rootsAreRememberedAndNotARepositoryIsAskedAgainSooner() {
        var asked: [String] = []
        var roots = ConflictRoots { folder in
            asked.append(folder)
            return folder.hasPrefix("/tmp") ? nil : "/"
        }
        let start = Date()
        #expect(roots.root(of: "/", now: start) == "/")
        #expect(roots.root(of: "/", now: start.addingTimeInterval(600)) == "/")
        #expect(asked == ["/"])
        #expect(roots.root(of: "/tmp", now: start) == nil)
        #expect(roots.root(of: "/tmp", now: start.addingTimeInterval(60)) == nil)
        #expect(asked == ["/", "/tmp"])
        #expect(roots.root(of: "/tmp", now: start.addingTimeInterval(600)) == nil)
        #expect(asked == ["/", "/tmp", "/tmp"])
    }

    // MARK: Expiry

    @Test func aConflictNeedsOneChangeInTheLastHalfHour() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), now = Date()
        let file = File(root: "/srv/shop", path: "src/cart.py")
        ledger.record(file, by: ada, at: now.addingTimeInterval(-3 * 3600))
        ledger.record(file, by: otto, at: now.addingTimeInterval(-31 * 60))
        #expect(ledger.conflicts(now: now).isEmpty)
        // Still remembered: one more change brings it back.
        #expect(ledger.shared()[file]?.count == 2)
        ledger.record(file, by: otto, at: now.addingTimeInterval(-29 * 60))
        #expect(ledger.conflicts(now: now)[ada]?.first?.others == [otto])
    }

    @Test func changesAreForgottenAfterHours() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), now = Date()
        let file = File(root: "/srv/shop", path: "src/cart.py")
        ledger.record(file, by: ada, at: now.addingTimeInterval(-ConflictLedger.maxAge - 60))
        ledger.record(file, by: otto, at: now)
        // Too old to count even before it's dropped.
        #expect(ledger.conflicts(now: now).isEmpty)
        ledger.expire(now: now)
        #expect(ledger.edits[ada] == nil)
        #expect(ledger.edits[otto]?.count == 1)
    }

    @Test func anEarlierTimeNeverReplacesALaterOne() {
        var ledger = ConflictLedger()
        let ada = UUID(), now = Date()
        let file = File(root: "/srv/shop", path: "a")
        ledger.record(file, by: ada, at: now)
        ledger.record(file, by: ada, at: now.addingTimeInterval(-500))
        #expect(ledger.edits[ada]?[file] == now)
    }

    @Test func aCommittedFileIsSettledForEveryone() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), now = Date()
        let cart = File(root: "/srv/shop", path: "src/cart.py")
        let api = File(root: "/srv/shop", path: "src/api.py")
        let elsewhere = File(root: "/srv/other", path: "src/cart.py")
        for pane in [ada, otto] {
            ledger.record(cart, by: pane, at: now.addingTimeInterval(-120))
            ledger.record(api, by: pane, at: now.addingTimeInterval(-120))
            ledger.record(elsewhere, by: pane, at: now.addingTimeInterval(-120))
        }
        ledger.settle(root: "/srv/shop", clean: ["src/cart.py"], before: now.addingTimeInterval(-60))
        let left = ledger.conflicts(now: now)[ada]?.map(\.file)
        #expect(left == [api, elsewhere])
    }

    @Test func aChangeMadeAfterTheCheckStartedStays() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), now = Date()
        let cart = File(root: "/srv/shop", path: "src/cart.py")
        ledger.record(cart, by: ada, at: now.addingTimeInterval(-120))
        ledger.record(cart, by: otto, at: now)
        ledger.settle(root: "/srv/shop", clean: ["src/cart.py"], before: now.addingTimeInterval(-60))
        #expect(ledger.edits[ada] == nil)
        #expect(ledger.edits[otto]?[cart] == now)
    }

    @Test func gitSaysWhichSharedFilesAreCommitted() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        // A name git would otherwise read as a pattern.
        let paths = ["app/[id].tsx", "app/page.tsx", "notes.md"]
        try Data("one".utf8).write(to: root.appendingPathComponent("app/[id].tsx"))
        try Data("one".utf8).write(to: root.appendingPathComponent("app/page.tsx"))
        #expect(AgentTools.git(["init", "-q"], in: root.path).ok)
        #expect(commitAll(root.path, "first"))
        #expect(AgentConflicts.changed(paths, in: root.path) == [])

        try Data("two".utf8).write(to: root.appendingPathComponent("app/[id].tsx"))
        try Data("new".utf8).write(to: root.appendingPathComponent("notes.md"))
        #expect(AgentConflicts.changed(paths, in: root.path) == ["app/[id].tsx", "notes.md"])

        #expect(commitAll(root.path, "second"))
        #expect(AgentConflicts.changed(paths, in: root.path) == [])
    }

    @Test func aFolderThatIsNotARepositoryHasNothingToSettle() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentConflicts.changed(["a.txt"], in: root.path) == nil)
    }

    // MARK: Bounds

    @Test func aPanesFilesAreCappedOldestFirst() {
        var ledger = ConflictLedger()
        let ada = UUID(), now = Date()
        for index in 0..<(ConflictLedger.filesPerPane + 25) {
            ledger.record(File(root: "/srv/shop", path: "f\(index)"), by: ada, at: now.addingTimeInterval(Double(index)))
        }
        #expect(ledger.edits[ada]?.count == ConflictLedger.filesPerPane)
        #expect(ledger.edits[ada]?[File(root: "/srv/shop", path: "f0")] == nil)
        #expect(ledger.edits[ada]?[File(root: "/srv/shop", path: "f\(ConflictLedger.filesPerPane + 24)")] != nil)
    }

    @Test func aClosedPaneOrANewSessionForgetsItsFiles() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), cy = UUID(), now = Date()
        let file = File(root: "/srv/shop", path: "a")
        for pane in [ada, otto, cy] { ledger.record(file, by: pane, at: now) }
        #expect(ledger.conflicts(now: now)[ada]?.first?.others.count == 2)
        ledger.forget(cy)
        #expect(Set(ledger.conflicts(now: now)[ada]?.first?.others ?? []) == [otto])
        ledger.keep(only: [ada])
        #expect(ledger.conflicts(now: now).isEmpty)
        #expect(ledger.edits.keys.map { $0 } == [ada])
    }

    @Test func othersAreListedMostRecentFirst() {
        var ledger = ConflictLedger()
        let ada = UUID(), otto = UUID(), cy = UUID(), now = Date()
        let file = File(root: "/srv/shop", path: "a")
        ledger.record(file, by: ada, at: now.addingTimeInterval(-300))
        ledger.record(file, by: otto, at: now.addingTimeInterval(-200))
        ledger.record(file, by: cy, at: now.addingTimeInterval(-100))
        #expect(ledger.conflicts(now: now)[ada]?.first?.others == [cy, otto])
    }

    // MARK: Telling once

    @Test func aPairHearsAboutAFileOnce() {
        var ledger = ConflictLedger()
        var announcements = ConflictAnnouncements()
        let ada = UUID(), otto = UUID(), now = Date()
        let cart = File(root: "/srv/shop", path: "src/cart.py")
        ledger.record(cart, by: ada, at: now)
        ledger.record(cart, by: otto, at: now)

        let first = announcements.fresh(in: ledger.conflicts(now: now))
        // One entry for the pair, not one from each side.
        #expect(first.count == 1)
        #expect(Set([first[0].first, first[0].second]) == [ada, otto])
        #expect(first[0].files == [cart])
        #expect(announcements.fresh(in: ledger.conflicts(now: now)).isEmpty)

        // Another change to the same file by the same two: still nothing.
        ledger.record(cart, by: ada, at: now.addingTimeInterval(30))
        #expect(announcements.fresh(in: ledger.conflicts(now: now.addingTimeInterval(30))).isEmpty)

        // A second file is news; so is a third agent on the first.
        let api = File(root: "/srv/shop", path: "src/api.py")
        ledger.record(api, by: ada, at: now)
        ledger.record(api, by: otto, at: now)
        let second = announcements.fresh(in: ledger.conflicts(now: now))
        #expect(second.count == 1)
        #expect(second[0].files == [api])
        let cy = UUID()
        ledger.record(cart, by: cy, at: now)
        let third = announcements.fresh(in: ledger.conflicts(now: now.addingTimeInterval(30)))
        #expect(third.count == 2)
        #expect(third.allSatisfy { $0.files == [cart] && ($0.first == cy || $0.second == cy) })
    }

    @Test func filesThatTurnUpTogetherAreOneAnnouncement() {
        var ledger = ConflictLedger()
        var announcements = ConflictAnnouncements()
        let ada = UUID(), otto = UUID(), now = Date()
        for name in ["a", "b", "c"] {
            ledger.record(File(root: "/srv/shop", path: name), by: ada, at: now)
            ledger.record(File(root: "/srv/shop", path: name), by: otto, at: now)
        }
        let fresh = announcements.fresh(in: ledger.conflicts(now: now))
        #expect(fresh.count == 1)
        #expect(Set(fresh[0].files.map(\.path)) == ["a", "b", "c"])
    }

    @Test func theSameFileInAnotherTreeIsAnotherAnnouncement() {
        var announcements = ConflictAnnouncements()
        let ada = UUID(), otto = UUID()
        let here = ConflictLedger.Hit(file: File(root: "/srv/shop", path: "a"), others: [otto])
        let there = ConflictLedger.Hit(file: File(root: "/srv/other", path: "a"), others: [otto])
        #expect(announcements.fresh(in: [ada: [here]]).count == 1)
        #expect(announcements.fresh(in: [ada: [here]]).isEmpty)
        #expect(announcements.fresh(in: [ada: [there]]).count == 1)
    }

    @Test func aClosedPanesAnnouncementsAreDropped() {
        var announcements = ConflictAnnouncements()
        let ada = UUID(), otto = UUID(), cy = UUID()
        let file = File(root: "/srv/shop", path: "a")
        #expect(announcements.fresh(in: [ada: [.init(file: file, others: [otto, cy])]]).count == 2)
        announcements.forget(cy)
        let again = announcements.fresh(in: [ada: [.init(file: file, others: [otto, cy])]])
        #expect(again.count == 1)
        #expect(again.first.map { Set([$0.first, $0.second]) } == [ada, cy])
    }

    // MARK: Wording

    @Test func theWordingNamesTheOthersAndStaysNeutral() {
        #expect(ConflictText.summary(files: 1, others: ["Otto"]) == "1 file also edited by Otto")
        #expect(ConflictText.summary(files: 2, others: ["Otto", "Otto"]) == "2 files also edited by Otto")
        #expect(ConflictText.summary(files: 3, others: ["Otto", "Ada"]) == "3 files also edited by Otto and Ada")
        #expect(ConflictText.summary(files: 3, others: ["Otto", "Ada", "Cy"]) == "3 files also edited by Otto and 2 others")
        #expect(ConflictText.summary(files: 1, others: []) == "1 file also edited by another agent")
        #expect(ConflictText.files(["src/cart.py"]) == "cart.py")
        #expect(ConflictText.files(["src/cart.py", "src/api.py"]) == "cart.py and api.py")
        #expect(ConflictText.files(["a/x.py", "b/y.py", "c/z.py"]) == "x.py and 2 more files")
    }

    @Test func theHeadsUpIsOneLineNamingTheFilesAndTheOtherAgent() {
        let one = ConflictText.headsUp(paths: ["src/cart.py"], others: ["Otto"])
        #expect(one.hasPrefix("Heads-up: Otto is also editing src/cart.py in this same folder."))
        #expect(!one.contains("\n"))
        let many = ConflictText.headsUp(paths: ["a", "b", "c", "d", "e"], others: ["Otto", "Ada"])
        #expect(many.hasPrefix("Heads-up: Otto and Ada are also editing a, b, c and 2 more in this same folder."))
        #expect(!many.contains("\n"))
    }
}
