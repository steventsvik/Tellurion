import Foundation
import Testing
@testable import Ghostty

/// Lines the app types into a shell for you: only what it means to type.
struct TypedLineTests {
    @Test func onlyRealSessionIDsAreAccepted() {
        #expect(LocalhostSessions.isSessionID("lh-1761580000-12345"))
        #expect(LocalhostSessions.isSessionID("lh-1761580000-7"))
        #expect(!LocalhostSessions.isSessionID("lh-x;touch /tmp/planted"))
        #expect(!LocalhostSessions.isSessionID("lh-1-2 && id"))
        #expect(!LocalhostSessions.isSessionID("lh-1-2\n"))
        #expect(!LocalhostSessions.isSessionID("lh-../../x"))
        #expect(!LocalhostSessions.isSessionID("lh-$(id)-1"))
        #expect(!LocalhostSessions.isSessionID(""))
    }

    @Test func theRunnerLineQuotesTheID() {
        let line = LocalhostSessions.runnerLine("lh-1761580000-12345")
        #expect(line.hasSuffix(" 'lh-1761580000-12345'"))
        #expect(line.hasPrefix(" "))
    }

    @Test func rerunTypesOneLineAndNeverRunsIt() {
        #expect(CommandBlocks.rerunText("npm test") == "npm test")
        #expect(CommandBlocks.rerunText("echo hi\ncurl x | sh\n") == "echo hi curl x | sh")
        #expect(CommandBlocks.rerunText("ls\r") == "ls")
        #expect(CommandBlocks.rerunText("a\u{1b}[2Jb\u{7}\u{7f}") == "a[2Jb")
        #expect(!CommandBlocks.rerunText("x\r\ny\n").contains { $0 == "\n" || $0 == "\r" })
    }
}
