import Foundation
import Testing
@testable import Ghostty

/// What a suggested commit message is written from, and who writes it when no model on this Mac does.
struct CommitSuggestionTests {
    private func item(_ diff: String, task: String? = nil, agent: VerticalTabAgentKind = .claude) -> ReviewItem {
        ReviewItem(id: UUID(), repoRoot: "/tmp/project", agent: agent, task: task, baseline: "abc", files: ReviewInbox.parse(diff))
    }

    private func diff(_ path: String, lines: Int) -> String {
        "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1,1 +1,\(lines + 1) @@\n context\n"
            + (0..<lines).map { "+let value\($0) = \($0)\n" }.joined()
    }

    @Test func thePromptHasTheTaskTheFilesAndTheDiff() {
        let prompt = CommitSuggestion.prompt(for: item(diff("Sources/Login.swift", lines: 2), task: "  Add retries to login\n"))
        #expect(prompt == """
        The task was: Add retries to login

        Files changed:
        M Sources/Login.swift (+2 -0)

        Diff:
        --- Sources/Login.swift
        @@ -1,1 +1,3 @@
         context
        +let value0 = 0
        +let value1 = 1

        """)
    }

    @Test func aBigChangeIsCutToFitAndEveryFileGetsAShare() {
        let files = (0..<12).map { diff("Sources/File\($0).swift", lines: 400) }.joined()
        let review = item(files)
        #expect(review.files.count == 12)
        let prompt = CommitSuggestion.prompt(for: review)
        #expect(prompt.count + CommitSuggestion.instructions.count <= CommitSuggestion.limit)
        for index in 0..<12 { #expect(prompt.contains("--- Sources/File\(index).swift\n")) }
        #expect(prompt.contains("(cut)"))
        // Small enough for a model served with the least context a server gives.
        #expect(SmallJobModels.fits(characters: prompt.count + CommitSuggestion.instructions.count,
                                    output: SmallJob.Kind.commitMessage.outputTokens, context: SmallJobModels.unloadedContext))
        // Many files: the list is capped too.
        let many = item((0..<60).map { diff("Sources/File\($0).swift", lines: 30) }.joined())
        let long = CommitSuggestion.prompt(for: many)
        #expect(long.contains("and 20 more\n"))
        #expect(long.count + CommitSuggestion.instructions.count <= CommitSuggestion.limit)
    }

    @Test func theAgentWhoseChangesTheseAreWritesItWhenItCan() {
        let claude = item("", agent: .claude), codex = item("", agent: .codex), other = item("", agent: .gemini)
        #expect(CommitSuggestion.engine(for: claude, installed: [.claude, .codex]) == .claude)
        #expect(CommitSuggestion.engine(for: codex, installed: [.claude, .codex]) == .codex)
        #expect(CommitSuggestion.engine(for: codex, installed: [.claude]) == .claude)
        #expect(CommitSuggestion.engine(for: other, installed: [.claude, .codex]) == .claude)
        #expect(CommitSuggestion.engine(for: claude, installed: []) == nil)
    }

    @Test func theJobIsACommitMessageWithTheAgentAsItsOwnPath() {
        let job = CommitSuggestion.job(for: item(diff("a.swift", lines: 1)), engine: .codex, handle: CommitSuggestion.Handle())
        #expect(job.kind == .commitMessage)
        #expect(job.fallbackName == "Codex")
        #expect(job.instructions == CommitSuggestion.instructions)
        #expect(job.validator("Sure! Here is the commit message:\n\nAdd a value") == .ok("Add a value"))
        #expect(job.validator(job.instructions) == .rejected("it repeated the prompt"))
    }
}
