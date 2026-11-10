import Foundation
import Testing
@testable import Ghostty

/// What the conflict radar reads out of the agents' status events and session records. The
/// payloads are the ones the hooks in agent-hooks/ send and write.
struct ConflictSourcesTests {
    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: Events

    @Test func aFinishedEditNamesItsFile() {
        // agent-hook.sh: "\(tool_name): \(tool_input.file_path)".
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "Edit: src/app.ts") == .file("src/app.ts"))
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "Write: /srv/shop/notes.md") == .file("/srv/shop/notes.md"))
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "MultiEdit: lib/cart.py") == .file("lib/cart.py"))
    }

    @Test func onlyFinishedToolsThatChangeFilesCount() {
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "Bash: npm test") == .none)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "Read: src/app.ts") == .none)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "TodoWrite") == .none)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "write_stdin: y") == .none)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: nil) == .none)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "") == .none)
        // Asking isn't changing, and Codex's tool_start comes before the change.
        #expect(ConflictSources.edit(inEvent: "permission_request", detail: "Edit: src/app.ts") == .none)
        #expect(ConflictSources.edit(inEvent: "tool_start", detail: "Edit: src/app.ts") == .none)
        #expect(ConflictSources.edit(inEvent: "stop", detail: "Edit: src/app.ts") == .none)
    }

    @Test func aPathTheHookCutShortIsNotTrusted() {
        let path = "/srv/projects/shop/services/checkout/src/cart/totals.py"
        // agent-hook.sh: 47 characters and an ellipsis.
        let claude = String("Edit: \(path)".prefix(47)) + "…"
        #expect(claude.count == ConflictSources.detailLimit)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: claude) == .unknown)
        // agent-event.py and codex-hook.py: the first 48 characters, nothing to show for it.
        let others = String("Edit: \(path)".prefix(48))
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: others) == .unknown)
    }

    @Test func aPatchOrAToolWithNoPathSaysOnlyThatSomethingChanged() {
        // codex-hook.py: the tool and the start of its "command", which is the patch.
        let codex = String("apply_patch: *** Begin Patch *** Update File: src/app.ts".prefix(48))
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: codex) == .unknown)
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "apply_patch") == .unknown)
        // NotebookEdit's path is `notebook_path`, which the hook doesn't send.
        #expect(ConflictSources.edit(inEvent: "tool_complete", detail: "NotebookEdit") == .unknown)
    }

    @Test func editToolsAreKnownByTheirNames() {
        for name in ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "functions.apply_patch", "str_replace_editor",
                     "write_file", "edit_file", "replace", "create_file", "mcp__files__write_file", "fsWrite"] {
            #expect(ConflictSources.isEditTool(name), "\(name)")
        }
        for name in ["Bash", "Read", "Grep", "TodoWrite", "update_plan", "write_stdin", "exec_command", "WebFetch", "Task", ""] {
            #expect(!ConflictSources.isEditTool(name), "\(name)")
        }
    }

    // MARK: Claude Code's transcript

    @Test func aTranscriptRecordGivesFullPathsItsFolderAndWhen() throws {
        let record = try object("""
        {"type":"assistant","cwd":"/srv/shop","timestamp":"2026-03-01T10:15:30.250Z","sessionId":"s1",
         "message":{"role":"assistant","content":[
           {"type":"text","text":"Updating the totals."},
           {"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/srv/shop/src/cart/totals.py","old_string":"a","new_string":"b"}},
           {"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/srv/shop/README.md"}},
           {"type":"tool_use","id":"toolu_3","name":"NotebookEdit","input":{"notebook_path":"/srv/shop/analysis.ipynb","new_source":"x"}},
           {"type":"tool_use","id":"toolu_4","name":"Bash","input":{"command":"npm test"}}]}}
        """)
        let edits = ConflictSources.claudeEdits(in: record)
        #expect(edits.map(\.path) == ["/srv/shop/src/cart/totals.py", "/srv/shop/analysis.ipynb"])
        #expect(edits.allSatisfy { $0.folder == "/srv/shop" })
        let date = try #require(edits.first?.date)
        #expect(abs(date.timeIntervalSince1970 - 1_772_360_130.25) < 0.01)
    }

    @Test func theOtherAgentsFeedsReadTheSameWay() throws {
        // agent-event.py writes these: Claude Code's names, no folder, whole seconds.
        let record = try object("""
        {"type":"assistant","timestamp":"2026-03-01T10:15:30Z",
         "message":{"role":"assistant","content":[{"type":"tool_use","id":"tool_ab12","name":"Edit","input":{"file_path":"src/app.ts"}}]}}
        """)
        let edits = ConflictSources.claudeEdits(in: record)
        #expect(edits == [ConflictSources.Edit(path: "src/app.ts", folder: nil, date: Date(timeIntervalSince1970: 1_772_360_130))])
    }

    @Test func promptsAndResultsAreNotChanges() throws {
        let user = try object(#"{"type":"user","message":{"role":"user","content":"Edit: src/app.ts please"}}"#)
        #expect(ConflictSources.claudeEdits(in: user).isEmpty)
        let result = try object("""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}
        """)
        #expect(ConflictSources.claudeEdits(in: result).isEmpty)
    }

    // MARK: Codex's hook journal

    private let patch = """
    *** Begin Patch
    *** Update File: src/cart/totals.py
    @@
    -old
    +new
    *** Add File: docs/totals.md
    +Totals
    *** Delete File: src/cart/legacy.py
    *** Update File: src/a.py
    *** Move to: src/b.py
    *** End Patch
    """

    @Test func aPatchNamesEveryFileItTouches() {
        #expect(ConflictSources.patchPaths(patch) == ["src/cart/totals.py", "docs/totals.md", "src/cart/legacy.py", "src/a.py", "src/b.py"])
        #expect(ConflictSources.patchPaths("echo hello").isEmpty)
    }

    @Test func aJournalRecordOfAFinishedPatchGivesItsFiles() throws {
        // codex-hook.py: {"event", "timestamp", "session", "parent", "child", "payload"}.
        let payload: [String: Any] = ["session_id": "0199-abc", "cwd": "/srv/shop", "tool_name": "apply_patch",
                                      "tool_use_id": "call_1", "tool_input": ["command": patch]]
        let record: [String: Any] = ["event": "tool_complete", "timestamp": 1_772_360_130.5, "session": "0199-abc", "payload": payload]
        let edits = ConflictSources.codexEdits(in: record)
        #expect(edits.map(\.path) == ["src/cart/totals.py", "docs/totals.md", "src/cart/legacy.py", "src/a.py", "src/b.py"])
        #expect(edits.allSatisfy { $0.folder == "/srv/shop" && $0.date == Date(timeIntervalSince1970: 1_772_360_130.5) })
    }

    @Test func aPatchThatHasOnlyBeenAskedForIsNotAChange() {
        let payload: [String: Any] = ["cwd": "/srv/shop", "tool_name": "apply_patch", "tool_input": ["command": patch]]
        #expect(ConflictSources.codexEdits(in: ["event": "pre_tool_use", "timestamp": 1.0, "payload": payload]).isEmpty)
        #expect(ConflictSources.codexEdits(in: ["event": "permission_request", "timestamp": 1.0, "payload": payload]).isEmpty)
    }

    @Test func theFolderACommandRanInWinsOverTheSessions() {
        // Codex also sends patches through its shell, with a working directory of their own.
        let input: [String: Any] = ["command": "apply_patch <<'EOF'\n\(patch)\nEOF", "workdir": "/srv/shop/services/api"]
        let payload: [String: Any] = ["cwd": "/srv/shop", "tool_name": "exec_command", "tool_input": input]
        let edits = ConflictSources.codexEdits(in: ["event": "tool_complete", "timestamp": 2.0, "payload": payload])
        #expect(edits.count == 5)
        #expect(edits.allSatisfy { $0.folder == "/srv/shop/services/api" })
    }

    @Test func aPlainCommandInTheJournalIsNotAChange() {
        let payload: [String: Any] = ["cwd": "/srv/shop", "tool_name": "Bash", "tool_input": ["command": "cat src/app.ts"]]
        #expect(ConflictSources.codexEdits(in: ["event": "tool_complete", "timestamp": 2.0, "payload": payload]).isEmpty)
        #expect(ConflictSources.codexEdits(in: ["event": "tool_complete"]).isEmpty)
    }

    // MARK: Reading records

    @Test func onlyWholeLinesAreRead() {
        let text = "{\"a\":1}\nnot json\n{\"b\":2}\n{\"c\":"
        let parsed = ConflictSources.records(in: Data(text.utf8))
        #expect(parsed.records.count == 2)
        #expect(parsed.consumed == text.utf8.count - "{\"c\":".utf8.count)
        #expect(ConflictSources.records(in: Data("{\"c\":".utf8)).consumed == 0)
    }

    @Test func aSliceOfDataReadsTheSame() {
        let data = Data("skip me\n{\"a\":1}\n".utf8)
        let slice = data[8...]
        let parsed = ConflictSources.records(in: slice)
        #expect(parsed.records.count == 1)
        #expect(parsed.consumed == slice.count)
    }
}
