import Foundation
import Testing
@testable import Ghostty

/// The project a folder belongs to (LocalhostProject): its repository's top folder, found
/// by looking on disk, with recent answers reused for a short while.
@Suite(.serialized) struct LocalhostProjectTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("localhost-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    @Test func aFolderInsideARepositoryBelongsToItsTop() throws {
        let top = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: top) }
        try FileManager.default.createDirectory(at: top.appendingPathComponent(".git"), withIntermediateDirectories: true)
        LocalhostProject.forgetKnown()
        #expect(LocalhostProject(folder: top.appendingPathComponent("a/b").path).root == top.path)
        #expect(LocalhostProject(folder: top.path).root == top.path)
    }

    @Test func aFolderOutsideAnyRepositoryIsItsOwnProject() throws {
        let top = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: top) }
        LocalhostProject.forgetKnown()
        let inside = top.appendingPathComponent("a/b").path
        #expect(LocalhostProject(folder: inside).root == inside)
    }

    @Test func anAnswerStandsForAWhileThenIsLookedUpAgain() throws {
        let top = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: top) }
        LocalhostProject.forgetKnown()
        let inside = top.appendingPathComponent("a/b").path
        let start = Date()
        #expect(LocalhostProject(folder: inside, now: start).root == inside)
        // It becomes a repository: the answer from a moment ago still stands…
        try FileManager.default.createDirectory(at: top.appendingPathComponent(".git"), withIntermediateDirectories: true)
        #expect(LocalhostProject(folder: inside, now: start.addingTimeInterval(5)).root == inside)
        // …and after a while the disk is asked again.
        #expect(LocalhostProject(folder: inside, now: start.addingTimeInterval(LocalhostProject.knownFor + 1)).root == top.path)
    }
}
