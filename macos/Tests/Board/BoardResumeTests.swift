import Foundation
import Testing
@testable import Ghostty

/// What a restored board tile types: only lines the app builds, never the board file's own.
struct BoardResumeTests {
    private func tile(agent: String? = nil, session: String? = nil, command: String? = nil) -> BoardTile {
        BoardTile(id: UUID(), frame: CGRect(x: 0, y: 0, width: 400, height: 300), cwd: nil,
                  agent: agent, session: session, command: command, title: nil, accounts: nil)
    }

    @Test func aStoredCommandIsNeverTypedBack() {
        let planted = "touch /tmp/planted-by-board-file\n"
        #expect(BoardAgent.resumeCommand(for: tile(command: planted)) == nil)
        #expect(BoardAgent.resumeCommand(for: tile(agent: "claude", command: planted)) == " claude\n")
        #expect(BoardAgent.resumeCommand(for: tile(agent: "claude", session: "not-a-uuid", command: planted)) == " claude\n")
        #expect(BoardAgent.resumeCommand(for: tile(agent: "gemini", command: planted)) == " gemini\n")
        #expect(BoardAgent.resumeCommand(for: tile(agent: "nobody", command: planted)) == nil)
    }

    @Test func aSavedSessionIsResumed() {
        let session = UUID().uuidString
        #expect(BoardAgent.resumeCommand(for: tile(agent: "claude", session: session, command: "x\n"))
                == " claude --resume \(session)\n")
        #expect(BoardAgent.resumeCommand(for: tile(agent: "codex", session: session, command: "x\n"))
                == " codex resume \(session)\n")
        // Only Claude Code and Codex can resume; others start afresh.
        #expect(BoardAgent.resumeCommand(for: tile(agent: "gemini", session: session, command: "x\n")) == " gemini\n")
    }

    @Test func aTileWithoutAnAgentIsAPlainShell() {
        #expect(BoardAgent.resumeCommand(for: tile()) == nil)
        #expect(BoardAgent.resumeCommand(for: tile(session: UUID().uuidString)) == nil)
    }
}
