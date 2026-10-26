import Foundation
import Testing
@testable import Ghostty

/// Agents the user said they don't use (the ExtremeSkippedAgents preference), the marker
/// files that tell `tellurion doctor` about them, and the doctor's reading of those files.
struct SetupSkipTests {
    @Test func readsTheSavedChoiceAndIgnoresUnknownNames() {
        #expect(SetupChecks.skipped(from: nil).isEmpty)
        #expect(SetupChecks.skipped(from: []).isEmpty)
        #expect(SetupChecks.skipped(from: ["codex"]) == [.codex])
        #expect(SetupChecks.skipped(from: ["claude", "codex", "somethingNewer"]) == [.claude, .codex])
    }

    @Test func skipButtonsSayWhichAgent() {
        #expect(SetupFix.skip(.codex).title == "I don't use Codex")
        #expect(SetupFix.skip(.claude).title == "I don't use Claude Code")
    }

    @Test func markerFilesFollowTheChoice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claudeOff = folder.appendingPathComponent("claude-off").path
        let codexOff = folder.appendingPathComponent("codex-off").path

        // The folder doesn't exist yet: skipping creates it, with the one marker.
        SetupChecks.writeSkipFlags([.codex], in: folder)
        #expect(FileManager.default.fileExists(atPath: codexOff))
        #expect(!FileManager.default.fileExists(atPath: claudeOff))

        SetupChecks.writeSkipFlags([.claude, .codex], in: folder)
        #expect(FileManager.default.fileExists(atPath: codexOff))
        #expect(FileManager.default.fileExists(atPath: claudeOff))

        // Connecting again (or unchecking the skip) removes the marker.
        SetupChecks.writeSkipFlags([.claude], in: folder)
        #expect(!FileManager.default.fileExists(atPath: codexOff))
        #expect(FileManager.default.fileExists(atPath: claudeOff))

        SetupChecks.writeSkipFlags([], in: folder)
        #expect(!FileManager.default.fileExists(atPath: codexOff))
        #expect(!FileManager.default.fileExists(atPath: claudeOff))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: tellurion doctor

    /// A leftover `~/.codex` folder without the marker is a problem; with the marker it's a note.
    @Test func doctorLeavesOutASkippedAgent() throws {
        guard let script = HookInstaller.bundled?.appendingPathComponent("tellurion"), let jq = Self.jq else { return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("jq"), withDestinationURL: jq)

        let before = try Self.doctor(script, home: home, bin: bin)
        #expect(before.contains("Codex: ~/.codex/hooks.json doesn't exist"))
        #expect(before.contains("Claude Code: ~/.claude/settings.json doesn't exist"))
        #expect(!before.contains("is skipped"))

        SetupChecks.writeSkipFlags([.codex], in: home.appendingPathComponent(".ghostty-extreme/features", isDirectory: true))
        let after = try Self.doctor(script, home: home, bin: bin)
        #expect(after.contains("Codex is skipped"))
        #expect(!after.contains("Codex: ~/.codex/hooks.json doesn't exist"))
        #expect(after.contains("Claude Code: ~/.claude/settings.json doesn't exist"))

        SetupChecks.writeSkipFlags([], in: home.appendingPathComponent(".ghostty-extreme/features", isDirectory: true))
        let back = try Self.doctor(script, home: home, bin: bin)
        #expect(back.contains("Codex: ~/.codex/hooks.json doesn't exist"))
        #expect(!back.contains("is skipped"))
    }

    private static var jq: URL? {
        ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `tellurion doctor` with `home` as the home folder and only `bin` (jq) besides the
    /// system paths, so no agent command on this Mac takes part.
    private static func doctor(_ script: URL, home: URL, bin: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "doctor"]
        process.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "SHELL": "/bin/zsh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
