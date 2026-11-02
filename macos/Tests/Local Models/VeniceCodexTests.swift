import Foundation
import Testing
@testable import Ghostty

/// A pane on Venice stays on Venice: what's saved for it, and what's typed into it.
struct VeniceCodexTests {
    @Test func accountsSavedBeforeVeniceStillLoad() throws {
        let saved = #"{"id":"6E1C5E3E-8F6A-4F3B-9E55-111111111111","provider":"codex","name":"Personal"}"#
        let account = try JSONDecoder().decode(BoardAccount.self, from: Data(saved.utf8))
        #expect(account.name == "Personal")
        #expect(!account.isVenice)
        #expect(account.veniceModel == nil)
    }

    @Test func aVeniceAccountSurvivesBeingSaved() throws {
        let account = BoardAccount(provider: .codex, name: "Venice · DeepSeek", veniceModel: "deepseek-x", venicePrivate: true)
        let back = try JSONDecoder().decode(BoardAccount.self, from: JSONEncoder().encode(account))
        #expect(back == account)
        #expect(back.isVenice && back.used)
    }

    @Test func startingCodexInAVenicePaneGoesThroughTellurion() {
        let adapted = VeniceCodex.adapted("codex\n")
        #expect(adapted.hasPrefix(" "))
        #expect(adapted.hasSuffix("tellurion' venice codex\n") || adapted.hasSuffix("tellurion venice codex\n"))
        #expect(VeniceCodex.adapted(" codex resume abc\n").contains("venice codex resume abc\n"))
        #expect(VeniceCodex.adapted("codex --yolo\n").contains("venice codex --yolo\n"))
    }

    @Test func otherCommandsInAVenicePaneAreLeftAlone() {
        for line in ["claude\n", "codexx\n", "ls\n", "echo codex\n"] {
            #expect(VeniceCodex.adapted(line) == line)
        }
    }

    @Test func switchingToVeniceClearsTheProfileFolder() {
        let venice = BoardAccount(provider: .codex, name: "V", veniceModel: "model-1", venicePrivate: true)
        let line = VeniceCodex.switchLine(to: venice, provider: .codex)
        #expect(line.hasPrefix("unset CODEX_HOME; export TELLURION_CODEX_BACKEND=venice TELLURION_VENICE_MODEL="))
        #expect(line.contains("model-1"))
        #expect(line.contains("venice codex"))
    }

    @Test func switchingAwayFromVeniceClearsItSoNothingStaysOnIt() {
        let usual = VeniceCodex.switchLine(to: nil, provider: .codex)
        #expect(usual == "unset TELLURION_CODEX_BACKEND TELLURION_VENICE_MODEL CODEX_HOME; codex")
        let profile = BoardAccount(provider: .codex, name: "P")
        let line = VeniceCodex.switchLine(to: profile, provider: .codex)
        #expect(line.hasPrefix("unset TELLURION_CODEX_BACKEND TELLURION_VENICE_MODEL; export CODEX_HOME="))
        #expect(line.hasSuffix("; codex"))
    }

    @Test func switchingClaudeAccountsIsUntouched() {
        #expect(VeniceCodex.switchLine(to: nil, provider: .claude) == "unset CLAUDE_CONFIG_DIR; claude")
    }

    @Test func aResumePlanFromBeforeVeniceStillLoads() throws {
        let saved = #"{"kind":"codex","surface":"s","cwd":null,"value":"v"}"#
        let entry = try JSONDecoder().decode(ResumeAfterUpdate.Entry.self, from: Data(saved.utf8))
        #expect(entry.venice == nil)
    }

    @Test func aSessionOnVeniceResumesThroughTellurion() throws {
        let cached = #"{"id":"s1","agent":"codex","prompts":0,"toolCalls":0,"commands":0,"tests":0,"files":[],"linesAdded":0,"linesRemoved":0,"tokensIn":0,"tokensOut":0}"#
        var session = try JSONDecoder().decode(ActivitySession.self, from: Data(cached.utf8))
        #expect(!session.onVenice)
        session.codexProvider = "openai"
        #expect(!session.onVenice)
        session.codexProvider = VeniceCodex.provider
        #expect(session.onVenice)
        let line = VeniceCodex.resumeLine("s1")
        #expect(line.hasPrefix(" "))
        #expect(line.hasSuffix(" venice codex resume s1\n"))
    }

    @Test func aRemovedVeniceModelStartsNothing() {
        let line = VeniceCodex.removedAccountLine
        #expect(line.hasPrefix(" printf "))
        #expect(!line.contains("; codex"))
        #expect(VeniceCodex.adapted(line) == line)
    }
}
