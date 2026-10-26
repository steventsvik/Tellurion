import Foundation
import Testing
@testable import Ghostty

/// HookConfig merges Tellurion's hook entries into an agent's config and takes them out
/// again. Pure data in, data out: what isn't ours stays byte for byte, merging twice
/// changes nothing the second time, and removing after merging gives the file back.
struct HookConfigTests {
    private let home = "/Users/someone"
    private var installed: String { home + "/.ghostty-extreme/agent-hooks/agent-hook.sh" }
    private var legacy: String { home + "/.ghostty-custom/agent-hooks/agent-hook.sh" }

    /// A settings file with someone else's hooks and settings in it.
    private var theirs: [String: Any] {
        [
            "permissions": ["allow": ["Bash(ls:*)"]],
            "model": "opus",
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"]]]],
                "PreToolUse": [["matcher": "Write", "hooks": [["type": "command", "command": "/usr/local/bin/lint"]]]],
            ],
        ]
    }

    private func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func commands(_ config: [String: Any], _ event: String) -> [String] {
        ((config["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    @Test func mergeAddsEveryEventAndLeavesTheirsAlone() throws {
        let merged = HookConfig.merge(theirs, agent: .claude, home: home)
        #expect(merged.changes.count == HookConfig.claudeEvents.count)
        #expect(merged.changes.allSatisfy { $0.hasPrefix("Added ") })

        // Everything outside "hooks", byte for byte.
        var rest = merged.config
        rest.removeValue(forKey: "hooks")
        var original = theirs
        original.removeValue(forKey: "hooks")
        #expect(try canonical(rest) == canonical(original))

        // Their handlers stay first in their own groups; ours come after, in a group of their own.
        let hooks = try #require(merged.config["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
        #expect(commands(merged.config, "Stop") == ["say done", installed + " claude stop"])
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)
        #expect(pre[0]["matcher"] as? String == "Write")
        #expect(pre[1]["matcher"] as? String == "Bash")
        #expect((pre[1]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int == 5)

        #expect(HookConfig.report(merged.config, agent: .claude, home: home).isComplete)
    }

    @Test func mergingAgainChangesNothing() throws {
        let once = HookConfig.merge(theirs, agent: .codex, home: home)
        let twice = HookConfig.merge(once.config, agent: .codex, home: home)
        #expect(twice.changes.isEmpty)
        #expect(try canonical(twice.config) == canonical(once.config))
    }

    @Test func removeGivesTheFileBack() throws {
        for agent in [HookConfig.Agent.claude, .codex] {
            let merged = HookConfig.merge(theirs, agent: agent, home: home)
            let removed = HookConfig.remove(merged.config, agent: agent)
            #expect(removed.changes.count == HookConfig.events(for: agent).count)
            #expect(removed.changes.allSatisfy { $0.hasPrefix("Removed ") })
            #expect(try canonical(removed.config) == canonical(theirs))
            #expect(HookConfig.report(removed.config, agent: agent, home: home).isEmpty)
        }
    }

    @Test func removeLeavesAFileWithoutOursAlone() throws {
        let removed = HookConfig.remove(theirs, agent: .claude)
        #expect(removed.changes.isEmpty)
        #expect(try canonical(removed.config) == canonical(theirs))
        #expect(HookConfig.remove([:], agent: .codex).config.isEmpty)
    }

    @Test func removeDropsTheHooksKeyWhenOnlyOursWereThere() throws {
        let merged = HookConfig.merge(["model": "opus"], agent: .claude, home: home)
        let removed = HookConfig.remove(merged.config, agent: .claude)
        #expect(removed.config["hooks"] == nil)
        #expect(try canonical(removed.config) == canonical(["model": "opus"]))
    }

    @Test func mergeRepointsOurEntriesThatRunFromElsewhere() throws {
        let repo = "/Users/someone/Desktop/repo/agent-hooks/agent-hook.sh"
        var config = HookConfig.merge([:], agent: .claude, home: home).config
        // The same entries, but running the script from the repository.
        var hooks = try #require(config["hooks"] as? [String: Any])
        for (event, groups) in hooks {
            hooks[event] = (groups as? [[String: Any]])?.map { group in
                var group = group
                group["hooks"] = (group["hooks"] as? [[String: Any]])?.map { handler in
                    var handler = handler
                    handler["command"] = (handler["command"] as? String)?.replacingOccurrences(of: installed, with: repo)
                    return handler
                }
                return group
            }
        }
        config["hooks"] = hooks
        let report = HookConfig.report(config, agent: .claude, home: home)
        #expect(!report.isComplete)
        #expect(report.elsewhere.count == HookConfig.claudeEvents.count)
        #expect(report.entries["Stop"] == .elsewhere(repo))

        let merged = HookConfig.merge(config, agent: .claude, home: home)
        #expect(merged.changes.count == HookConfig.claudeEvents.count)
        #expect(merged.changes.allSatisfy { $0.hasPrefix("Repointed ") })
        #expect(HookConfig.report(merged.config, agent: .claude, home: home).isComplete)
        // Repointing changes the command in place: no second group, no second handler.
        #expect(commands(merged.config, "Stop") == [installed + " claude stop"])
    }

    @Test func aTildeCountsAsInstalled() {
        let config: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "~/.ghostty-extreme/agent-hooks/agent-hook.sh claude stop"]]]]]]
        let report = HookConfig.report(config, agent: .claude, home: home)
        #expect(report.entries["Stop"] == .ok)
        #expect(report.missing.count == HookConfig.claudeEvents.count - 1)
        let merged = HookConfig.merge(config, agent: .claude, home: home)
        #expect(!merged.changes.contains("Repointed Stop"))
    }

    @Test func codexKeepsTheLegacyScriptItAlreadyApproved() throws {
        // One entry still runs from the old folder: Codex ties its approvals to the exact
        // command, so new entries use that folder too and the old one isn't repointed.
        let config: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": legacy + " codex stop"]]]]]]
        let merged = HookConfig.merge(config, agent: .codex, home: home)
        #expect(!merged.changes.contains("Repointed Stop"))
        #expect(merged.changes.count == HookConfig.codexEvents.count - 1)
        #expect(commands(merged.config, "SessionStart") == [legacy + " codex session_start"])
        #expect((try #require(((merged.config["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first))["matcher"] as? String == "*")
        #expect(HookConfig.report(merged.config, agent: .codex, home: home).isComplete)
    }

    @Test func agentsDoNotSeeEachOthersEntries() throws {
        let both = HookConfig.merge(HookConfig.merge([:], agent: .claude, home: home).config, agent: .codex, home: home).config
        #expect(HookConfig.report(both, agent: .claude, home: home).isComplete)
        #expect(HookConfig.report(both, agent: .codex, home: home).isComplete)
        let withoutCodex = HookConfig.remove(both, agent: .codex).config
        #expect(HookConfig.report(withoutCodex, agent: .claude, home: home).isComplete)
        #expect(HookConfig.report(withoutCodex, agent: .codex, home: home).isEmpty)
        #expect(try canonical(withoutCodex) == canonical(HookConfig.merge([:], agent: .claude, home: home).config))
    }

    @Test func aGroupWithoutHandlersIsKeptAsItIs() throws {
        // A group with no "hooks" list isn't ours to touch; ours is added beside it.
        let odd: [String: Any] = ["hooks": ["Stop": [["matcher": "x"], ["hooks": "not a list"]]]]
        let merged = HookConfig.merge(odd, agent: .claude, home: home)
        #expect(commands(merged.config, "Stop") == [installed + " claude stop"])
        let removed = HookConfig.remove(merged.config, agent: .claude)
        #expect(try canonical(removed.config) == canonical(odd))
    }

    // MARK: ~/.zshrc

    @Test func theZshrcLineIsFoundAndTakenOutAgain() {
        let before = "export PATH=\"$HOME/bin:$PATH\"\nalias ll='ls -l'\n"
        let after = before + HookConfig.zshrcBlock
        #expect(!HookConfig.zshrcHasIntegration(before))
        #expect(HookConfig.zshrcHasIntegration(after))
        #expect(HookConfig.zshrcHasIntegration("source ~/.ghostty-custom/agent-hooks/ghostty-custom.zsh"))
        #expect(HookConfig.zshrcRemovingIntegration(after) == before + "\n")
        #expect(!HookConfig.zshrcHasIntegration(HookConfig.zshrcRemovingIntegration(after)))
        #expect(HookConfig.zshrcRemovingIntegration(before) == before)
    }
}
