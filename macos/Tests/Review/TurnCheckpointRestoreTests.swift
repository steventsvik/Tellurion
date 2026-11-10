import Foundation
import Testing
@testable import Ghostty

/// Restoring a checkpoint (TurnCheckpoints.apply) says what it couldn't do, so a partial
/// restore doesn't pass for a whole one.
struct TurnCheckpointRestoreTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Real paths, as git reports them.
        return URL(fileURLWithPath: AgentChangeWatcher.realPath(url.path))
    }

    private func checkpoint(_ root: URL, tree: String) -> TurnCheckpoints.Checkpoint {
        TurnCheckpoints.Checkpoint(id: UUID(), time: Date(), title: "Turn", agent: nil, repoRoot: root.path, gitDir: nil,
                                   tree: tree, isRestorePoint: false)
    }

    @Test func deletingFilesAddedSinceWorksAndAMissingOneIsNotAFailure() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = root.appendingPathComponent("sub/added.txt")
        try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: added)
        let failures = TurnCheckpoints.apply([.init(path: "sub/added.txt", kind: .delete), .init(path: "gone.txt", kind: .delete)],
                                             from: checkpoint(root, tree: "HEAD"))
        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: added.path))
        // The folder it left empty goes too.
        #expect(!FileManager.default.fileExists(atPath: added.deletingLastPathComponent().path))
    }

    @Test func aRestoreThatGitRefusesIsReported() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not a repository, and no such tree: git can't restore anything here.
        let failures = TurnCheckpoints.apply([.init(path: "file.txt", kind: .restore)],
                                             from: checkpoint(root, tree: "0000000000000000000000000000000000000000"))
        #expect(failures.count == 1)
        #expect(failures.first?.hasPrefix("Couldn't restore file.txt") == true)
    }

    @Test func restoringFromARealTreeWorks() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentTools.git(["init", "-q"], in: root.path).ok)
        let file = root.appendingPathComponent("file.txt")
        try Data("before\n".utf8).write(to: file)
        #expect(AgentTools.git(["add", "file.txt"], in: root.path).ok)
        let tree = AgentTools.git(["write-tree"], in: root.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!tree.isEmpty)
        try Data("after\n".utf8).write(to: file)
        let failures = TurnCheckpoints.apply([.init(path: "file.txt", kind: .restore)], from: checkpoint(root, tree: tree))
        #expect(failures.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before\n")
    }
}
