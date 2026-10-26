import Foundation
import Testing
@testable import Ghostty

/// What the orchestrator makes of a headless Claude Code or Codex run: the answer's JSON,
/// the session to resume, or what went wrong.
struct HeadlessAgentParseTests {
    private func result(_ output: String, status: Int32 = 0, error: String = "") -> AgentTools.Result {
        AgentTools.Result(status: status, output: output, error: error)
    }

    private func reply(_ parsed: HeadlessAgent.Parsed) throws -> OrchestratorReply {
        try JSONDecoder().decode(OrchestratorReply.self, from: try #require(parsed.json))
    }

    // MARK: Codex

    @Test func codexAnswerComesFromItsAgentMessage() throws {
        let stream = """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Here you go: {\\"say\\":\\"Started two reviewers.\\",\\"actions\\":[{\\"type\\":\\"wait\\"}],\\"done\\":false} (end)"}}
        {"type":"turn.completed","usage":{"input_tokens":1}}
        """
        let parsed = HeadlessAgent.parseCodex(result(stream))
        #expect(parsed.session == "thread-1")
        #expect(parsed.error == nil)
        let answer = try reply(parsed)
        #expect(answer.say == "Started two reviewers.")
        #expect(answer.actions == [OrchestratorAction(type: "wait")])
        #expect(answer.done == false)
    }

    @Test func codexErrorsAreReported() {
        let failed = HeadlessAgent.parseCodex(result("""
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.failed","error":{"message":"rate limited"}}
        """, status: 1))
        #expect(failed.json == nil)
        #expect(failed.error == "rate limited")
        #expect(failed.session == "t")

        let error = HeadlessAgent.parseCodex(result("{\"type\":\"error\",\"message\":\"Reconnecting... 1/5\"}", status: 1))
        #expect(error.error == "Reconnecting... 1/5")
    }

    @Test func codexWithoutAnAnswerSaysWhy() {
        let nothing = HeadlessAgent.parseCodex(result("", status: 1, error: "first line\n  codex: not logged in  \n"))
        #expect(nothing.json == nil)
        #expect(nothing.error == "Codex didn't answer: codex: not logged in")

        let prose = HeadlessAgent.parseCodex(result("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"I can't do that.\"}}"))
        #expect(prose.json == nil)
        #expect(prose.error == "I can't do that.")

        let silent = HeadlessAgent.parseCodex(result("not json at all", status: 2))
        #expect(silent.error == "Codex didn't answer (exit 2).")

        let stopped = HeadlessAgent.parseCodex(result("", status: 15))
        #expect(stopped.error == "Stopped.")
    }

    // MARK: Claude Code

    @Test func claudesWholeAnswerOrItsResultText() throws {
        let structured = HeadlessAgent.parseClaude(result(#"{"type":"result","structured_output":{"say":"Hi","actions":[],"done":true},"session_id":"s1"}"#))
        #expect(structured.session == "s1")
        #expect(try reply(structured).done == true)

        // No structured output: the JSON inside the result text.
        let text = HeadlessAgent.parseClaude(result(#"{"type":"result","result":"Sure. {\"say\":\"From text\",\"actions\":[]}","session_id":"s2"}"#))
        #expect(text.error == nil)
        #expect(try reply(text).say == "From text")
        #expect(try reply(text).done == nil)
    }

    @Test func claudeErrorsAreReported() {
        let refused = HeadlessAgent.parseClaude(result(#"{"type":"result","is_error":true,"result":"Not logged in","session_id":"s"}"#, status: 1))
        #expect(refused.json == nil)
        #expect(refused.error == "Not logged in")

        let empty = HeadlessAgent.parseClaude(result(#"{"type":"result","result":"no json here"}"#, status: 0))
        #expect(empty.error == "Claude Code didn't answer (exit 0).")

        let crashed = HeadlessAgent.parseClaude(result("", status: 1, error: "boom"))
        #expect(crashed.error == "Claude Code didn't answer: boom")

        let stopped = HeadlessAgent.parseClaude(result("", status: 15))
        #expect(stopped.error == "Stopped.")
    }

    @Test func parseGoesByEngine() {
        let codex = "{\"type\":\"thread.started\",\"thread_id\":\"c\"}"
        #expect(HeadlessAgent.parse(result(codex), engine: .codex).session == "c")
        #expect(HeadlessAgent.parse(result("{\"type\":\"result\",\"session_id\":\"k\"}"), engine: .claude).session == "k")
    }

    // MARK: The object in a text

    @Test func theObjectInATextIsBetweenItsOuterBraces() {
        func text(_ data: Data?) -> String? { data.flatMap { String(bytes: $0, encoding: .utf8) } }
        #expect(text(HeadlessAgent.object(in: "Sure: {\"a\":{\"b\":1}} done")) == "{\"a\":{\"b\":1}}")
        #expect(text(HeadlessAgent.object(in: "{}")) == "{}")
        #expect(HeadlessAgent.object(in: "no braces") == nil)
        #expect(HeadlessAgent.object(in: "} {") == nil)
        #expect(HeadlessAgent.object(in: "") == nil)
    }
}
