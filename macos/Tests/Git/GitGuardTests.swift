import Foundation
import Testing
@testable import Ghostty

/// Git commands the app runs by itself ignore the programs a repository's own config names.
struct GitGuardTests {
    /// A repository whose config points a file monitor, an external diff, a hook and a text
    /// converter at a script that leaves a marker file for each one it is asked to run.
    private struct PlantedRepo {
        let folder: URL
        let markers: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitguard-" + UUID().uuidString)
            markers = folder.appendingPathComponent("markers")
            try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
            let program = folder.appendingPathComponent("program.sh")
            try "#!/bin/sh\ntouch \"\(markers.path)/$1\"\nexit 0\n".write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            let hooks = folder.appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try "#!/bin/sh\ntouch \"\(markers.path)/hook\"\n".write(to: hooks.appendingPathComponent("pre-commit"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appendingPathComponent("pre-commit").path)

            try raw(["init", "-q"])
            try "one\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "*.txt diff=planted\n".write(to: folder.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            try raw(["add", "."])
            try raw(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"])
            try "two\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            for (key, value) in [("core.fsmonitor", "\(program.path) fsmonitor"), ("diff.external", "\(program.path) extdiff"),
                                 ("diff.planted.textconv", "\(program.path) textconv"), ("core.hooksPath", hooks.path)] {
                try raw(["config", key, value])
            }
        }

        /// Plain git, as a terminal would run it: no guards.
        func raw(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        func ran() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: markers.path))
        }

        func reset() throws {
            for name in try ran() { try FileManager.default.removeItem(at: markers.appendingPathComponent(name)) }
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private let commit = ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "x"]

    @Test func plainGitRunsWhatTheRepositoryNames() throws {
        let repo = try PlantedRepo()
        defer { repo.remove() }
        try repo.raw(["status", "--porcelain"])
        try repo.raw(["diff", "HEAD"])
        try repo.raw(["-c", "commit.gpgsign=false"] + commit)
        // The fixture is live: without guards every program runs.
        #expect(try repo.ran() == ["fsmonitor", "extdiff", "hook"])
    }

    @Test func theAppsGitRunsNoneOfThem() throws {
        let repo = try PlantedRepo()
        defer { repo.remove() }
        #expect(AgentTools.git(["status", "--porcelain"], in: repo.folder.path).ok)
        #expect(AgentTools.git(["diff"] + AgentTools.diffGuards + ["HEAD"], in: repo.folder.path).ok)
        #expect(AgentTools.git(["diff"] + AgentTools.diffGuards + ["--stat", "HEAD"], in: repo.folder.path).ok)
        #expect(AgentTools.git(["ls-files", "--others", "--exclude-standard"], in: repo.folder.path).ok)
        #expect(AgentTools.git(commit, in: repo.folder.path).ok)
        #expect(try repo.ran().isEmpty)
    }

    @Test func reviewDiffsRunNoneOfThem() throws {
        let repo = try PlantedRepo()
        defer { repo.remove() }
        let head = AgentTools.git(["rev-parse", "HEAD"], in: repo.folder.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let tree = AgentTools.git(["write-tree"], in: repo.folder.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.reset()
        _ = ReviewInbox.diff(from: head, to: tree, in: repo.folder.path)
        #expect(try repo.ran().isEmpty)
    }

    @Test func aCallersOwnSettingStillWins() {
        // A caller's -c comes after the guards, as the race's identity and the skills'
        // ssh command rely on.
        let folder = FileManager.default.temporaryDirectory.path
        let value = AgentTools.git(["-c", "core.fsmonitor=true", "config", "core.fsmonitor"], in: folder).output
        #expect(value.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
    }

    @Test func onlyNetworkRemotesAreCheckedForUpdates() {
        #expect(SkillInventory.isNetworkRemote("https://github.com/someone/skill.git"))
        #expect(SkillInventory.isNetworkRemote("git@github.com:someone/skill.git"))
        #expect(SkillInventory.isNetworkRemote("ssh://git@example.com/skill"))
        #expect(!SkillInventory.isNetworkRemote("/Users/someone/skill"))
        #expect(!SkillInventory.isNetworkRemote("../elsewhere"))
        #expect(!SkillInventory.isNetworkRemote("file:///tmp/skill"))
        #expect(!SkillInventory.isNetworkRemote("git://example.com/skill"))
        #expect(!SkillInventory.isNetworkRemote("ext::sh -c touch%20x"))
    }
}
