import Foundation
import Testing
@testable import Ghostty

/// Finding a folder's repository (VerticalTabsGit.repoRoot): the walk up through the parent
/// folders always ends, whatever the folder.
struct RepoRootTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.resolvingSymlinksInPath()
    }

    @Test func theTopOfTheDiskHasNoParent() {
        #expect(VerticalTabsGit.parent(of: URL(fileURLWithPath: "/")) == nil)
        // What some macOS versions answer for the folder above `/`.
        #expect(VerticalTabsGit.parent(of: URL(fileURLWithPath: "/..")).map(\.path) == "/")
        #expect(VerticalTabsGit.parent(of: URL(fileURLWithPath: "/Users")).map(\.path) == "/")
        #expect(VerticalTabsGit.parent(of: URL(fileURLWithPath: "/Users/someone/code/")).map(\.path) == "/Users/someone")
    }

    @Test func everyWalkEnds() {
        for start in ["/", "/..", "/../../..", "/Users/someone/a/b/c", "/Volumes/Missing/x"] {
            var dir: URL? = URL(fileURLWithPath: start)
            var steps = 0
            while let here = dir, steps < 100 {
                dir = VerticalTabsGit.parent(of: here)
                steps += 1
            }
            #expect(dir == nil, "the walk from \(start) didn't end")
        }
    }

    @Test func aFolderOutsideAnyRepositoryHasNoRoot() {
        #expect(VerticalTabsGit.repoRoot(containing: "/") == nil)
        #expect(VerticalTabsGit.repoRoot(containing: "/Volumes/Missing-\(UUID().uuidString)/x") == nil)
    }

    @Test func aRepositoryIsFoundFromAFolderInsideIt() throws {
        let repo = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: repo) }
        let inside = repo.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let found = VerticalTabsGit.repoRoot(containing: inside.path)
        #expect(found?.path == repo.path)
        #expect(found?.gitDir == repo.path + "/.git")
    }
}
