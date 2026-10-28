import Foundation
import Testing
@testable import Ghostty

/// Filter programs a repository's own config names don't run when the app runs git, and
/// neither do `ext::` remotes it rewrites a URL to.
struct GitFilterTests {
    /// A repository whose config defines filters (one of them with "=" in its name) that leave
    /// a marker file each time git runs them, applied to every file by `.git/info/attributes`.
    private struct PlantedRepo {
        let folder: URL
        let markers: URL
        let program: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitfilter-" + UUID().uuidString)
            markers = folder.appendingPathComponent("markers")
            program = folder.appendingPathComponent("program.sh")
            try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
            try "#!/bin/sh\ntouch \"\(markers.path)/$1\"\ncat\n".write(to: program, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            let work = folder.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try raw(["init", "-q"])
            try "one\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "one\n".write(to: work.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
            try raw(["add", "."])
            try raw(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"])
            for (key, value) in [("filter.planted.clean", "\(program.path) clean"), ("filter.planted.smudge", "\(program.path) smudge"),
                                 ("filter.odd=name.process", "\(program.path) process")] {
                try raw(["config", key, value])
            }
            try "*.txt filter=planted\n*.md filter=odd=name\n"
                .write(to: work.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
            try "two\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "two\n".write(to: work.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        }

        var work: String { folder.appendingPathComponent("work").path }

        /// Plain git, as a terminal would run it.
        func raw(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.appendingPathComponent("work").path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }

        func ran() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: markers.path))
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func plainGitRunsTheFilters() throws {
        let repo = try PlantedRepo()
        defer { repo.remove() }
        try repo.raw(["diff", "--shortstat", "HEAD"])
        try repo.raw(["restore", "--source=HEAD", "--worktree", "--", "a.txt"])
        // The fixture is live: without the overrides each filter runs.
        #expect(try repo.ran() == ["clean", "smudge", "process"])
    }

    @Test func theAppsGitRunsNoFilter() throws {
        let repo = try PlantedRepo()
        defer { repo.remove() }
        #expect(AgentTools.git(["diff"] + AgentTools.diffGuards + ["--shortstat", "HEAD"], in: repo.work).ok)
        #expect(AgentTools.git(["status", "--porcelain"], in: repo.work).ok)
        let tree = ReviewInbox.snapshot(repo.work)
        #expect(tree != nil)
        if let tree {
            _ = ReviewInbox.diff(from: "HEAD", to: tree, in: repo.work)
            #expect(AgentTools.git(["restore", "--source=\(tree)", "--worktree", "--", "a.txt", "b.md"], in: repo.work).ok)
        }
        #expect(AgentTools.git(["stash", "push", "-q"], in: repo.work).ok)
        #expect(AgentTools.git(["stash", "pop", "-q"], in: repo.work).ok)
        #expect(try repo.ran().isEmpty)
    }

    @Test func anExtRemoteDoesntRun() throws {
        let repo = try PlantedRepo()
        defer { repo.remove() }
        try repo.raw(["remote", "add", "origin", "https://example.invalid/skill.git"])
        // Its own program: the filters' one waits for input, which a transport never closes.
        let transport = repo.folder.appendingPathComponent("transport.sh")
        try "#!/bin/sh\ntouch \"\(repo.markers.path)/ext\"\nexit 1\n".write(to: transport, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: transport.path)
        try repo.raw(["config", "url.ext::\(transport.path) %S .insteadOf", "https://example.invalid/"])
        try repo.raw(["config", "protocol.ext.allow", "always"])
        try repo.raw(["ls-remote", "origin", "HEAD"])
        #expect(try repo.ran().contains("ext"))
        try FileManager.default.removeItem(at: repo.markers.appendingPathComponent("ext"))
        _ = AgentTools.git(["ls-remote", "--upload-pack=git-upload-pack", "origin", "HEAD"], in: repo.work)
        #expect(try !repo.ran().contains("ext"))
    }

    @Test func onlyTheRepositorysOwnFiltersAreSwitchedOff() {
        let listing = [
            "local", "filter.planted.clean\n/tmp/x clean",
            "worktree", "filter.odd=name.process\n/tmp/x",
            "global", "filter.lfs.clean\ngit-lfs clean -- %f",
            "local", "filter.lfs.smudge\ngit-lfs smudge -- %f",
            "local", "filter.planted.smudge\n/tmp/x smudge",
            "",
        ].joined(separator: "\0")
        let overrides = AgentTools.filterOverrides(listing)
        #expect(overrides.map(\.key) == [
            "filter.planted.clean", "filter.planted.smudge", "filter.planted.process", "filter.planted.required",
            "filter.odd=name.clean", "filter.odd=name.smudge", "filter.odd=name.process", "filter.odd=name.required",
        ])
        #expect(overrides.map(\.value) == ["", "", "", "false", "", "", "", "false"])
        #expect(AgentTools.filterOverrides("").isEmpty)
    }

    @Test func settingsComeAfterOnesAlreadyInTheEnvironment() {
        let environment = AgentTools.withSettings([(key: "filter.a.clean", value: "")],
                                                  ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Someone"])
        #expect(environment["GIT_CONFIG_COUNT"] == "2")
        #expect(environment["GIT_CONFIG_KEY_0"] == "user.name")
        #expect(environment["GIT_CONFIG_KEY_1"] == "filter.a.clean")
        #expect(environment["GIT_CONFIG_VALUE_1"] == "")
        #expect(AgentTools.withSettings([], ["A": "b"]) == ["A": "b"])
    }
}
