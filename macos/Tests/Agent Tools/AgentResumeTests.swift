import Foundation
import Testing
@testable import Ghostty

/// The line that brings a session back: built in one place, and only for a real session id.
struct AgentResumeTests {
    private let session = "0198c5f2-7a3b-7c41-9d2e-5f6a7b8c9d0e"

    @Test func eachAgentResumesItsOwnWay() {
        #expect(AgentResume.line(.claude, session: session) == " claude --resume \(session)\n")
        #expect(AgentResume.line(.codex, session: session) == " codex resume \(session)\n")
        #expect(AgentResume.line(.gemini, session: session) == nil)
        #expect(AgentResume.command(.claude, session: session) == "claude --resume \(session)")
        #expect(AgentResume.command(.codex, session: session) == "codex resume \(session)")
    }

    @Test func onlyASessionIDIsTyped() {
        for planted in ["", "abc", "x; touch /tmp/planted", "\(session); id", "\(session)\nid", "$(id)", "\u{15}id\r", "'\(session)'"] {
            #expect(AgentResume.line(.claude, session: planted) == nil)
            #expect(AgentResume.line(.codex, session: planted) == nil)
            #expect(AgentResume.line(.codex, session: planted, on: .venice(model: "m")) == nil)
            #expect(AgentResume.line(.codex, session: planted, on: .local(provider: "ollama", model: "m")) == nil)
            #expect(AgentResume.command(.codex, session: planted) == nil)
        }
    }

    @Test func aSessionOnVeniceStaysThere() throws {
        let line = try #require(AgentResume.line(.codex, session: session, on: .venice(model: nil)))
        #expect(line == VeniceCodex.resumeLine(session))
        let named = try #require(AgentResume.line(.codex, session: session, on: .venice(model: "qwen3-coder")))
        #expect(named.hasPrefix(" TELLURION_VENICE_MODEL='qwen3-coder' "))
        #expect(named.hasSuffix(" venice codex resume \(session)\n"))
        // A model name that isn't one is left out, never typed.
        let planted = try #require(AgentResume.line(.codex, session: session, on: .venice(model: "x; rm -rf ~")))
        #expect(planted == line)
        #expect(AgentResume.line(.codex, session: session, on: .venice(model: "")) == line)
    }

    @Test func aSessionOnAModelHereStaysThere() throws {
        let line = try #require(AgentResume.line(.codex, session: session, on: .local(provider: "lmstudio", model: "qwen3:4b")))
        #expect(line == LocalCodex.resumeLine(session, provider: "lmstudio", model: "qwen3:4b"))
        #expect(line.hasPrefix(" TELLURION_LOCAL_PROVIDER=lmstudio TELLURION_LOCAL_MODEL="))
        #expect(line.hasSuffix(" local codex resume \(session)\n"))
        let planted = try #require(AgentResume.line(.codex, session: session, on: .local(provider: "openai", model: "x; rm -rf ~")))
        #expect(!planted.contains("rm -rf"))
        #expect(!planted.contains("openai"))
    }

    @Test func claudeCodeHasOneBackend() {
        #expect(AgentResume.line(.claude, session: session, on: .venice(model: "m")) == " claude --resume \(session)\n")
    }
}
