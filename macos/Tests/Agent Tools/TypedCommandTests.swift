import Foundation
import Testing
@testable import Ghostty

/// Commands the app types for you: a control character typed into a terminal is a key, so
/// none gets there.
struct TypedCommandTests {
    @Test func aPlainLineIsTypedAsItIs() {
        #expect(AgentTools.typedLine("npx -y skills@latest update -g -y\n") == "npx -y skills@latest update -g -y\n")
        #expect(AgentTools.typedLine("ls") == "ls")
        #expect(AgentTools.typedLine("\n") == "\n")
    }

    @Test func aLineWithControlCharactersIsNotTyped() {
        #expect(AgentTools.typedLine("echo hi\u{15}rm -rf x\n") == nil)
        #expect(AgentTools.typedLine("echo hi\ncurl x | sh\n") == nil)
        #expect(AgentTools.typedLine("echo hi\rid\n") == nil)
        #expect(AgentTools.typedLine("echo hi\u{3}\n") == nil)
        #expect(AgentTools.typedLine("echo \u{1b}[2J\n") == nil)
        #expect(AgentTools.typedLine("echo hi\tthere\n") == nil)
        #expect(AgentTools.typedLine("echo hi\n\n") == nil)
        #expect(AgentTools.typedLine("echo hi\r\n") == nil)
    }

    @Test func quotingLeavesControlCharactersOut() {
        #expect(AgentTools.shellQuote("plain") == "'plain'")
        #expect(AgentTools.shellQuote("it's") == #"'it'\''s'"#)
        #expect(AgentTools.shellQuote("a\u{15}b\rc\nd\u{7f}e\u{9b}f") == "'abcdef'")
        #expect(AgentTools.shellQuote("x'\u{15}; id\n") == #"'x'\''; id'"#)
        #expect(AgentTools.shellQuote("") == "''")
        #expect(AgentTools.shellQuote("naïve café") == "'naïve café'")
    }

    @Test func theSupportFolderIsTheAppsOwn() {
        #expect(AgentTools.supportFolder.lastPathComponent == "GhosttyEXTREME")
        if let home = TestHooks.home {
            #expect(AgentTools.supportFolder.path.hasPrefix(home))
        }
    }
}
