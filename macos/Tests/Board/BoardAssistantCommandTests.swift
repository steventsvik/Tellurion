import Foundation
import Testing
@testable import Ghostty

/// A command the board's agent proposes: what the confirmation shows is what's typed.
struct BoardAssistantCommandTests {
    @Test func aPlainCommandIsTypedTrimmed() {
        #expect(BoardController.typedCommand("npm test") == "npm test")
        #expect(BoardController.typedCommand("  npm test\n") == "npm test")
        #expect(BoardController.typedCommand("npm test\r\n") == "npm test")
        #expect(BoardController.typedCommand("") == "")
    }

    @Test func aCommandWithControlCharactersIsRefused() {
        #expect(BoardController.typedCommand("echo hi\ncurl x | sh") == nil)
        #expect(BoardController.typedCommand("echo hi\rcurl x | sh") == nil)
        #expect(BoardController.typedCommand("echo hi\u{15}curl x | sh") == nil)
        #expect(BoardController.typedCommand("echo hi\u{3}") == nil)
        #expect(BoardController.typedCommand("echo \u{1b}[2J") == nil)
        #expect(BoardController.typedCommand("echo a\tb") == nil)
        #expect(BoardController.typedCommand("echo hi\u{7f}") == nil)
        #expect(BoardController.typedCommand("echo hi\u{9b}") == nil)
    }

    @Test func theRefusalSaysWhy() {
        let lines = "A terminal runs one command; put the rest in a script"
        #expect(BoardController.refusal("a\nb", lines: lines) == lines)
        #expect(BoardController.refusal("a\rb", lines: lines) == lines)
        #expect(BoardController.refusal("a\u{15}b", lines: lines) == BoardController.hiddenRefusal)
        #expect(BoardController.refusal("a\u{15}b\n", lines: lines) == BoardController.hiddenRefusal)
    }

    @Test func whatIsShownHidesNothing() {
        #expect(BoardController.visible("npm test") == "npm test")
        #expect(BoardController.visible("a\nb\n") == "a ⏎ b")
        #expect(BoardController.visible("a\r\nb") == "a ⏎ b")
        #expect(BoardController.visible("a\rb") == "a ⏎ b")
        #expect(BoardController.visible("echo hi\u{15}rm -rf x") == "echo hi␕rm -rf x")
        #expect(BoardController.visible("a\u{1b}[2Jb") == "a␛[2Jb")
        #expect(BoardController.visible("a\u{0}b\u{7f}c") == "a␀b␡c")
        #expect(BoardController.visible("a\tb") == "a␉b")
        #expect(BoardController.visible("a\u{9b}b") == #"a\u{9b}b"#)
        for text in ["a\u{15}b", "a\rb\nc", "\u{1b}x\u{7f}\u{85}y", "a\u{b}b\u{c}c"] {
            #expect(!Ghostty.Shell.containsControlCharacters(BoardController.visible(text)))
        }
    }

    @Test func aMessageForAnAgentKeepsItsLinesAndNothingHidden() {
        #expect(BoardController.isMessage("Fix the test.\n\nThen run:\n\tnpm test"))
        #expect(BoardController.isMessage("a\r\nb"))
        #expect(!BoardController.isMessage("hello\u{1b}[201~"))
        #expect(!BoardController.isMessage("hello\u{3}"))
        #expect(!BoardController.isMessage("hello\u{15}"))
    }
}
