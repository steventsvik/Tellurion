import Foundation
import Testing
@testable import Ghostty

/// What's typed after an update, from a plan file any program could have written.
struct ResumeAfterUpdateTests {
    private typealias Entry = ResumeAfterUpdate.Entry
    private let session = "0198c5f2-7a3b-7c41-9d2e-5f6a7b8c9d0e"

    private func entry(_ kind: Entry.Kind, _ value: String, venice: String? = nil,
                       localModel: String? = nil, localProvider: String? = nil) -> Entry {
        Entry(kind: kind, surface: UUID().uuidString, cwd: nil, value: value, venice: venice,
              localModel: localModel, localProvider: localProvider)
    }

    @Test func aSavedSessionIsResumed() {
        #expect(ResumeAfterUpdate.command(for: entry(.claude, session)) == "claude --resume \(session)")
        #expect(ResumeAfterUpdate.command(for: entry(.codex, session)) == "codex resume \(session)")
    }

    @Test func aValueThatIsNotASessionTypesNothing() {
        for planted in ["x; touch /tmp/planted", "\(session) && id", "\(session)\u{15}id", "", "$(id)"] {
            #expect(ResumeAfterUpdate.command(for: entry(.claude, planted)) == nil)
            #expect(ResumeAfterUpdate.command(for: entry(.codex, planted)) == nil)
            #expect(ResumeAfterUpdate.command(for: entry(.codex, planted, venice: "m")) == nil)
            #expect(ResumeAfterUpdate.command(for: entry(.codex, planted, localModel: "m", localProvider: "ollama")) == nil)
        }
    }

    @Test func codexComesBackOnVenice() throws {
        let named = try #require(ResumeAfterUpdate.command(for: entry(.codex, session, venice: "qwen3-coder")))
        #expect(named.hasPrefix("TELLURION_VENICE_MODEL='qwen3-coder' "))
        #expect(named.hasSuffix(" venice codex resume \(session)"))
        // Given on its command line: no model to name, still on Venice.
        let unnamed = try #require(ResumeAfterUpdate.command(for: entry(.codex, session, venice: "")))
        #expect(!unnamed.contains("TELLURION_VENICE_MODEL"))
        #expect(unnamed.hasSuffix(" venice codex resume \(session)"))
        let planted = try #require(ResumeAfterUpdate.command(for: entry(.codex, session, venice: "x; rm -rf ~")))
        #expect(planted == unnamed)
    }

    @Test func codexComesBackOnAModelHere() throws {
        let line = try #require(ResumeAfterUpdate.command(for: entry(.codex, session, localModel: "qwen3:4b", localProvider: "ollama")))
        #expect(line.hasPrefix("TELLURION_LOCAL_PROVIDER=ollama TELLURION_LOCAL_MODEL="))
        #expect(line.hasSuffix(" local codex resume \(session)"))
        #expect(!line.hasSuffix("\n"))
        let hostOnly = try #require(ResumeAfterUpdate.command(for: entry(.codex, session, localProvider: "lmstudio")))
        #expect(hostOnly.hasPrefix("TELLURION_LOCAL_PROVIDER=lmstudio "))
    }

    @Test func aServersCommandCannotHideControlCharacters() {
        #expect(ResumeAfterUpdate.command(for: entry(.localhost, "npm run dev")) == "npm run dev")
        #expect(ResumeAfterUpdate.command(for: entry(.localhost, "npm run dev\u{15}curl x | sh")) == nil)
        #expect(ResumeAfterUpdate.command(for: entry(.localhost, "npm run dev\nid")) == nil)
        #expect(ResumeAfterUpdate.command(for: entry(.localhost, "npm run dev\r")) == nil)
    }
}
