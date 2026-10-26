import Foundation
import Testing
@testable import Ghostty

/// Undoing what Setup wrote: the ~/.zshrc lines come out even after the user re-spaced
/// them, nothing else does, and a config file is copied aside before every rewrite.
struct ConfigEditTests {
    private let block = HookConfig.zshrcBlock

    @Test func addingThenRemovingGivesTheFileBack() {
        for original in ["", "export PATH=$HOME/bin:$PATH\n", "alias ll='ls -l'", "a\n\n"] {
            let installed = original + block
            #expect(HookConfig.zshrcHasIntegration(installed))
            let removed = HookConfig.zshrcRemovingIntegration(installed)
            #expect(!HookConfig.zshrcHasIntegration(removed))
            // A file that had no final newline gets one from the block; everything else is as it was.
            #expect(removed == (original.isEmpty || original.hasSuffix("\n") ? original : original + "\n"))
        }
    }

    @Test func respacedLinesStillComeOut() {
        let respaced = """
        export A=1

          # Tellurion:   shows which coding agent each pane runs  (does nothing in other terminals)
        \t[[ -n "$GHOSTTY_EXTREME_AGENT_EVENTS" ]]   &&  source  ~/.ghostty-extreme/agent-hooks/ghostty-extreme.zsh
        export B=2

        """
        #expect(HookConfig.zshrcRemovingIntegration(respaced) == "export A=1\nexport B=2\n")
    }

    @Test func theOlderCommentComesOutToo() {
        let old = "a\n\n# GhosttyEXTREME: shows which coding agent each pane runs (does nothing in other terminals)\n"
            + "[[ -n \"$GHOSTTY_EXTREME_AGENT_EVENTS\" ]] && source ~/.ghostty-extreme/agent-hooks/ghostty-extreme.zsh\n"
        #expect(HookConfig.zshrcRemovingIntegration(old) == "a\n")
    }

    @Test func onlyOurOwnLinesGo() {
        // A line the user wrote (their own guard, a comment, extra words) isn't ours, so the
        // file is returned byte for byte and the caller can say so.
        let theirs = [
            "source ~/.ghostty-extreme/agent-hooks/ghostty-extreme.zsh\n",
            "# [[ -n \"$GHOSTTY_EXTREME_AGENT_EVENTS\" ]] && source ~/.ghostty-extreme/agent-hooks/ghostty-extreme.zsh\n",
            "[[ -n \"$GHOSTTY_EXTREME_AGENT_EVENTS\" ]] && source ~/.ghostty-extreme/agent-hooks/ghostty-extreme.zsh # mine\n",
            "# Tellurion: shows which coding agent each pane runs (does nothing in other terminals)\n",
        ]
        for text in theirs {
            #expect(HookConfig.zshrcRemovingIntegration(text) == text)
        }
        // Our block among their lines: only ours goes, their spacing stays.
        let mixed = "x\n\n\n" + block + "\n\ny\n"
        #expect(HookConfig.zshrcRemovingIntegration(mixed) == "x\n\n\n\n\ny\n")
    }

    @Test func everyWriteGetsItsOwnBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("settings.json")

        // Nothing to back up yet.
        #expect(try HookInstaller.backUp(file, stamp: "20260101-120000") == nil)

        try Data("one".utf8).write(to: file)
        let first = try #require(try HookInstaller.backUp(file, stamp: "20260101-120000"))
        #expect(first.lastPathComponent == "settings.json.ghostty-extreme-backup-20260101-120000")

        // A second write in the same second keeps the first copy and adds another.
        try Data("two".utf8).write(to: file)
        let second = try #require(try HookInstaller.backUp(file, stamp: "20260101-120000"))
        #expect(second.lastPathComponent == "settings.json.ghostty-extreme-backup-20260101-120000-2")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")

        let third = try #require(try HookInstaller.backUp(file, stamp: "20260101-120000"))
        #expect(third.lastPathComponent == "settings.json.ghostty-extreme-backup-20260101-120000-3")
    }
}
