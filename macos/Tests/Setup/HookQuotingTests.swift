import Foundation
import Testing
@testable import Ghostty

/// Hook commands with a home folder a shell would split (a space in its name), and telling
/// our entries from someone else's that only look like them.
struct HookQuotingTests {
    private let home = "/Users/some one"
    private var installed: String { home + "/.ghostty-extreme/agent-hooks/agent-hook.sh" }
    private let stop = HookConfig.Event(name: "Stop", argument: "stop", matcher: nil)

    private func config(stop command: String) -> [String: Any] {
        ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
    }

    private func commands(_ config: [String: Any], _ event: String) -> [String] {
        ((config["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    @Test func aPlainPathIsLeftAsItIs() {
        let plain = "/Users/someone/.ghostty-extreme/agent-hooks/agent-hook.sh"
        #expect(HookConfig.shellWord(plain) == plain)
        #expect(HookConfig.command(script: plain, agent: .claude, event: stop) == plain + " claude stop")
        #expect(HookConfig.shellWord("~/.ghostty-extreme/agent-hooks/agent-hook.sh") == "~/.ghostty-extreme/agent-hooks/agent-hook.sh")
    }

    @Test func aPathWithASpaceIsQuoted() {
        #expect(HookConfig.command(script: installed, agent: .claude, event: stop) == "'\(installed)' claude stop")
        #expect(HookConfig.shellWord("/Users/o'brien/x y") == "'/Users/o'\\''brien/x y'")
        #expect(HookConfig.unquoted(HookConfig.shellWord("/Users/o'brien/x y")) == "/Users/o'brien/x y")
        #expect(HookConfig.shellWord("/a/$(rm)/b") == "'/a/$(rm)/b'")
    }

    @Test func theQuotedCommandRunsTheScriptInAShell() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hook quoting \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("agent-hook.sh")
        try Data("#!/bin/sh\nprintf '%s-%s' \"$1\" \"$2\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HookConfig.command(script: script.path, agent: .codex, event: stop)]
        let result = ProcessRunner.run(process, timeout: 10)
        #expect(result.text == "codex-stop")
    }

    @Test func mergingInAHomeWithASpaceWritesQuotedCommandsThatAreRecognised() throws {
        let merged = HookConfig.merge([:], agent: .claude, home: home)
        #expect(commands(merged.config, "Stop") == ["'\(installed)' claude stop"])
        #expect(HookConfig.report(merged.config, agent: .claude, home: home).isComplete)
        #expect(HookConfig.merge(merged.config, agent: .claude, home: home).changes.isEmpty)
        let removed = HookConfig.remove(merged.config, agent: .claude)
        #expect(removed.config["hooks"] == nil)
    }

    @Test func anOldUnquotedCommandIsRecognisedAndRewritten() throws {
        let old = config(stop: installed + " claude stop")
        #expect(HookConfig.isOurs(installed + " claude stop", agent: .claude, event: stop))
        // It's ours, but as written it runs nothing.
        #expect(HookConfig.report(old, agent: .claude, home: home).entries["Stop"] != .ok)
        let merged = HookConfig.merge(old, agent: .claude, home: home)
        #expect(merged.changes.contains("Repointed Stop"))
        #expect(commands(merged.config, "Stop") == ["'\(installed)' claude stop"])
        // And it can still be taken out as it was.
        #expect(HookConfig.remove(old, agent: .claude).changes == ["Removed Stop"])
    }

    @Test func someoneElsesScriptWithASimilarNameIsNotOurs() throws {
        let theirs = "/Users/someone/bin/my-agent-hook.sh claude stop"
        #expect(!HookConfig.isOurs(theirs, agent: .claude, event: stop))
        #expect(!HookConfig.isOurs("echo agent-hook.sh claude stop", agent: .claude, event: stop))
        #expect(HookConfig.isOurs("agent-hook.sh claude stop", agent: .claude, event: stop))
        #expect(HookConfig.isOurs("\"/repo/agent-hooks/agent-hook.sh\" claude stop", agent: .claude, event: stop))
        #expect(!HookConfig.isOurs("/repo/agent-hooks/agent-hook.sh codex stop", agent: .claude, event: stop))

        let config = config(stop: theirs)
        #expect(HookConfig.report(config, agent: .claude, home: "/Users/someone").entries["Stop"] == .missing)
        // Ours is added beside it; theirs isn't repointed or removed.
        let merged = HookConfig.merge(config, agent: .claude, home: "/Users/someone")
        #expect(commands(merged.config, "Stop") == [theirs, "/Users/someone/.ghostty-extreme/agent-hooks/agent-hook.sh claude stop"])
        #expect(commands(HookConfig.remove(merged.config, agent: .claude).config, "Stop") == [theirs])
    }

    @Test func theOtherAgentsCommandsAreQuotedAndStillFound() {
        let script = home + "/.ghostty-extreme/agent-hooks/agent-event.py"
        let command = MoreAgent.copilot.command(script: script, event: "sessionStart")
        #expect(command == "'\(script)' copilot sessionStart")
        #expect(MoreAgent.copilot.mentioned(in: command))
        #expect(MoreAgent.copilot.mentioned(in: command, event: "sessionStart"))
        #expect(!MoreAgent.copilot.mentioned(in: command, event: "sessionEnd"))
        #expect(MoreAgent.copilot.mentioned(in: "/plain/agent-event.py copilot sessionStart", event: "sessionStart"))
        #expect(!MoreAgent.droid.mentioned(in: command))
    }

    @Test func onlyTheNewestBackupsAreKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("settings.json")
        let other = folder.appendingPathComponent("settings.json.other")
        try Data("other".utf8).write(to: other)
        for n in 0..<(HookInstaller.backupsKept + 4) {
            try Data("version \(n)".utf8).write(to: file)
            try HookInstaller.backUp(file, stamp: "20260101-1200\(String(format: "%02d", n))")
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("settings.json.ghostty-extreme-backup-") }.sorted()
        #expect(backups.count == HookInstaller.backupsKept)
        #expect(backups.last == "settings.json.ghostty-extreme-backup-20260101-120008")
        #expect(backups.first == "settings.json.ghostty-extreme-backup-20260101-120004")
        // Other files beside it are not touched.
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
