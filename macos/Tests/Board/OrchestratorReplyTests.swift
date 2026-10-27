import Foundation
import Testing
@testable import Ghostty

/// The orchestrator's reply as the brain reads it, and the schema Claude Code is asked for.
struct OrchestratorReplyTests {
    private func decode(_ json: String) throws -> OrchestratorReply {
        try JSONDecoder().decode(OrchestratorReply.self, from: Data(json.utf8))
    }

    @Test func aReplyNeedsOnlyWordsAndActions() throws {
        let reply = try decode(#"{"say":"Nothing to do.","actions":[]}"#)
        #expect(reply.say == "Nothing to do.")
        #expect(reply.actions.isEmpty)
        #expect(reply.done == nil)
    }

    @Test func everyActionKindDecodesWithItsFields() throws {
        let reply = try decode("""
        {"say":"On it.","done":false,"actions":[
          {"type":"send","agent":"A1","text":"Run the tests"},
          {"type":"broadcast","text":"Stop and report"},
          {"type":"spawn","agent":"claude","role":"reviewer","task":"Review src","folder":"~/code"},
          {"type":"wait"}
        ]}
        """)
        #expect(reply.done == false)
        #expect(reply.actions.map(\.type) == ["send", "broadcast", "spawn", "wait"])
        #expect(reply.actions[0] == OrchestratorAction(type: "send", agent: "A1", text: "Run the tests"))
        #expect(reply.actions[1].text == "Stop and report")
        #expect(reply.actions[1].agent == nil)
        #expect(reply.actions[2] == OrchestratorAction(type: "spawn", agent: "claude", role: "reviewer", task: "Review src", folder: "~/code"))
        #expect(reply.actions[3] == OrchestratorAction(type: "wait"))
    }

    @Test func extraKeysAreIgnoredAndMissingOnesFail() {
        #expect((try? decode(#"{"say":"x","actions":[{"type":"wait","confidence":0.9}],"mood":"fine"}"#)) != nil)
        #expect((try? decode(#"{"actions":[]}"#)) == nil)
        #expect((try? decode(#"{"say":"x"}"#)) == nil)
        #expect((try? decode(#"{"say":"x","actions":[{"agent":"A1"}]}"#)) == nil)
        #expect((try? decode(#"{"say":"x","actions":[],"done":"yes"}"#)) == nil)
    }

    @Test func aReplySurvivesARoundTrip() throws {
        let original = OrchestratorReply(say: "Done.", actions: [OrchestratorAction(type: "send", agent: "A2", text: "Thanks")], done: true)
        let back = try JSONDecoder().decode(OrchestratorReply.self, from: try JSONEncoder().encode(original))
        #expect(back.say == original.say)
        #expect(back.actions == original.actions)
        #expect(back.done == true)
    }

    @Test func theSchemaAsksForExactlyTheseFields() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: Data(OrchestratorPrompt.schema.utf8)) as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(Set(schema["required"] as? [String] ?? []) == ["say", "actions", "done"])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["say", "actions", "done"])
        let actions = try #require(properties["actions"] as? [String: Any])
        let action = try #require(actions["items"] as? [String: Any])
        #expect(action["required"] as? [String] == ["type"])
        let fields = try #require(action["properties"] as? [String: Any])
        #expect(Set(fields.keys) == ["type", "agent", "text", "role", "task", "folder"])
        #expect((fields["type"] as? [String: Any])?["enum"] as? [String] == ["send", "broadcast", "spawn", "wait"])
        // Every action the schema allows decodes into OrchestratorAction.
        for kind in ["send", "broadcast", "spawn", "wait"] {
            #expect((try? JSONDecoder().decode(OrchestratorAction.self, from: Data("{\"type\":\"\(kind)\"}".utf8)))?.type == kind)
        }
    }
}
