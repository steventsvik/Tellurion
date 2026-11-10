import Foundation
import Testing
@testable import Ghostty

/// What a model's answer has to look like before a small job uses it, and what's cleaned off it first.
struct SmallJobTextTests {
    @Test func aGoodCommitMessagePasses() {
        #expect(SmallJobText.check(.commitMessage, "Fix the login redirect loop") == .ok("Fix the login redirect loop"))
        let withBody = "Fix the login redirect loop\n\nThe session cookie was read before it was set."
        #expect(SmallJobText.check(.commitMessage, withBody + "\n") == .ok(withBody))
        // Git wants an empty line after the subject.
        #expect(SmallJobText.check(.commitMessage, "Add a retry\nThree tries, then give up.") == .ok("Add a retry\n\nThree tries, then give up."))
        #expect(SmallJobText.check(.commitMessage, "fix: handle an empty list") == .ok("fix: handle an empty list"))
    }

    @Test func anIntroductionIsStripped() {
        #expect(SmallJobText.check(.commitMessage, "Here is the commit message:\n\nFix the login redirect loop") == .ok("Fix the login redirect loop"))
        #expect(SmallJobText.check(.commitMessage, "Sure! Here's a commit message for these changes:\nAdd a retry") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "Here is the commit message: Add a retry") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "Commit message: Add a retry") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "**Commit message:**\nAdd a retry") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "Add a retry\n\nLet me know if you'd like it shorter.") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "\"Add a retry\"") == .ok("Add a retry"))
        // A subject that only looks like one stays.
        #expect(SmallJobText.check(.commitMessage, "Okay button submits the form") == .ok("Okay button submits the form"))
    }

    @Test func thinkingIsStripped() {
        #expect(SmallJobText.check(.commitMessage, "<think>\nThe diff adds a retry.\n</think>\n\nAdd a retry") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "The diff adds a retry.</think>Add a retry") == .ok("Add a retry"))
        #expect(SmallJobText.check(.title, "<THINKING>hm</THINKING>Retry on failure") == .ok("Retry on failure"))
        // It never got past thinking.
        #expect(SmallJobText.check(.commitMessage, "<think>The diff adds a retry and") == .rejected("an empty answer"))
    }

    @Test func aRefusalIsRejected() {
        #expect(SmallJobText.check(.commitMessage, "I'm sorry, but I can't help with that.") == .rejected("it wouldn't answer"))
        #expect(SmallJobText.check(.commitMessage, "I cannot write a commit message without the diff.") == .rejected("it wouldn't answer"))
        #expect(SmallJobText.check(.summary, "I\u{2019}m unable to summarize this.") == .rejected("it wouldn't answer"))
        #expect(SmallJobText.check(.commitMessage, "") == .rejected("an empty answer"))
        #expect(SmallJobText.check(.commitMessage, " \n\t") == .rejected("an empty answer"))
    }

    @Test func aLongSubjectOrMessageIsRejected() {
        let subject = String(repeating: "a", count: 73)
        #expect(SmallJobText.check(.commitMessage, subject) == .rejected("a subject line over 72 characters"))
        #expect(SmallJobText.check(.commitMessage, String(subject.dropLast())) == .ok(String(subject.dropLast())))
        let long = "Add a retry\n\n" + String(repeating: "word ", count: 400)
        #expect(SmallJobText.check(.commitMessage, long) == .rejected("an answer that's too long"))
        #expect(SmallJobText.check(.commitMessage, "# Commit\n\nAdd a retry") == .rejected("markdown where the subject line goes"))
    }

    @Test func aFenceAroundTheAnswerIsRemovedAndOneInsideIsRejected() {
        #expect(SmallJobText.check(.commitMessage, "```\nAdd a retry\n```") == .ok("Add a retry"))
        #expect(SmallJobText.check(.commitMessage, "Here is the commit message:\n\n```text\nAdd a retry\n\nThree tries.\n```") == .ok("Add a retry\n\nThree tries."))
        #expect(SmallJobText.check(.commitMessage, "Add a retry\n\n```swift\nretry(3)\n```\nand more") == .rejected("a code fence in the answer"))
        #expect(SmallJobText.check(.summary, "It retries:\n```\nretry(3)\n```\nthree times") == .rejected("a code fence in the answer"))
    }

    @Test func thePromptHandedBackIsRejected() {
        let instructions = "Write a git commit message for the changes below. The first line is a summary in the imperative mood."
        let prompt = "Files changed:\nM Sources/Login.swift (+3 -1)\n\nDiff:\n--- Sources/Login.swift\n@@ -1,3 +1,5 @@\n+let retries = 3\n"
        #expect(SmallJobText.check(.commitMessage, instructions, parts: [instructions, prompt]) == .rejected("it repeated the prompt"))
        #expect(SmallJobText.check(.summary, prompt, parts: [instructions, prompt]) == .rejected("it repeated the prompt"))
        #expect(SmallJobText.check(.commitMessage, "Add three login retries", parts: [instructions, prompt]) == .ok("Add three login retries"))
    }

    @Test func controlCharactersAndEscapesAreRemoved() {
        #expect(SmallJobText.plain("Add\u{1B}[31m a retry\u{1B}[0m\u{07}") == "Add a retry")
        #expect(SmallJobText.plain("a\u{1B}]0;title\u{07}b\u{0}c\u{7F}") == "abc")
        #expect(SmallJobText.plain("one\r\ntwo\rthree\tfour") == "one\ntwo\nthree\tfour")
        #expect(SmallJobText.plain("safe\u{202E}txt") == "safetxt")
        #expect(SmallJobText.check(.commitMessage, "Add a retry\u{1B}[2J\u{08}") == .ok("Add a retry"))
    }

    @Test func aTitleIsOneShortLine() {
        #expect(SmallJobText.check(.title, "Title: \"Login retries\"") == .ok("Login retries"))
        #expect(SmallJobText.check(.title, "Login retries.") == .ok("Login retries"))
        #expect(SmallJobText.check(.title, "Login retries\nAnd a second idea") == .rejected("more than one line"))
        #expect(SmallJobText.check(.title, String(repeating: "t", count: 61)) == .rejected("a title over 60 characters"))
    }

    @Test func aSummaryHasALimit() {
        #expect(SmallJobText.check(.summary, "Summary: It now retries three times.") == .ok("It now retries three times."))
        #expect(SmallJobText.check(.summary, String(repeating: "s", count: 801)) == .rejected("an answer that's too long"))
    }

    @Test func aClassificationIsOneOfTheChoices() {
        let choices = ["bug", "feature", "chore"]
        #expect(SmallJobText.check(.classify, "Bug.", choices: choices) == .ok("bug"))
        #expect(SmallJobText.check(.classify, "Category: feature", choices: choices) == .ok("feature"))
        #expect(SmallJobText.check(.classify, "This is a chore", choices: choices) == .ok("chore"))
        #expect(SmallJobText.check(.classify, "bug or feature", choices: choices) == .rejected("an answer that isn't one of the choices"))
        #expect(SmallJobText.check(.classify, "refactor", choices: choices) == .rejected("an answer that isn't one of the choices"))
    }
}
