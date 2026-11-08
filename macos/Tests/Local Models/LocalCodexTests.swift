import Foundation
import Testing
@testable import Ghostty

/// A pane on a model on this Mac stays there: what's typed into it, and how its sessions come back.
struct LocalCodexTests {
    @Test func startingCodexInALocalPaneGoesThroughTellurion() {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables = LocalCodex.environment(model: "qwen3:4b", provider: "ollama")
        config.initialInput = " codex resume abc\n"
        VeniceCodex.adapt(&config)
        #expect(config.initialInput?.hasPrefix(" ") == true)
        #expect(config.initialInput?.hasSuffix(" local codex resume abc\n") == true)
        #expect(config.environmentVariables["TELLURION_CODEX_BACKEND"] == "local")
        #expect(config.environmentVariables["TELLURION_LOCAL_MODEL"] == "qwen3:4b")
        #expect(config.environmentVariables["TELLURION_LOCAL_PROVIDER"] == "ollama")
    }

    @Test func otherCommandsInALocalPaneAreLeftAlone() {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables = LocalCodex.environment(model: "m", provider: "ollama")
        for line in ["claude\n", "codexx\n", "ls\n", "echo codex\n"] {
            config.initialInput = line
            VeniceCodex.adapt(&config)
            #expect(config.initialInput == line)
        }
    }

    @Test func aPaneOnAnUnknownBackendIsLeftAlone() {
        var config = Ghostty.SurfaceConfiguration()
        config.environmentVariables = [VeniceCodex.backendVariable: "other"]
        config.initialInput = "codex\n"
        VeniceCodex.adapt(&config)
        #expect(config.initialInput == "codex\n")
    }

    @Test func aSessionResumesOnItsModelAndHost() {
        let line = LocalCodex.resumeLine("s1", provider: "lmstudio", model: "qwen3:4b")
        #expect(line.hasPrefix(" TELLURION_LOCAL_PROVIDER=lmstudio TELLURION_LOCAL_MODEL="))
        #expect(line.contains("qwen3:4b"))
        #expect(line.hasSuffix(" local codex resume s1\n"))
        #expect(LocalCodex.resumeLine("s1", provider: nil, model: nil).hasSuffix(" local codex resume s1\n"))
    }

    @Test func whatComesFromAFileIsNotTypedUnchecked() {
        let line = LocalCodex.resumeLine("s1", provider: "openai", model: "x; rm -rf ~")
        #expect(!line.contains("rm -rf"))
        #expect(!line.contains("openai"))
        #expect(line.hasSuffix(" local codex resume s1\n"))
        #expect(LocalCodex.isValidName("orcarouter/Qwen3.8-27B-Uncensored:latest"))
        #expect(LocalCodex.isValidName("qwen3:4b"))
        #expect(!LocalCodex.isValidName("-m"))
        #expect(!LocalCodex.isValidName("a b"))
        #expect(!LocalCodex.isValidName(""))
    }

    @Test func aSessionOnALocalModelIsKnownByCodexsProvider() {
        var session = ActivitySession(id: "s1", agent: "codex")
        #expect(!session.onLocal)
        session.codexProvider = "openai"
        #expect(!session.onLocal)
        session.codexProvider = "ollama"
        #expect(session.onLocal && !session.onVenice)
        session.codexProvider = "lmstudio"
        #expect(session.onLocal)
        session.codexProvider = VeniceCodex.provider
        #expect(!session.onLocal && session.onVenice)
        #expect(!ActivitySession(id: "c", agent: "claude", codexProvider: "ollama").onLocal)
    }

    @Test func aResumePlanFromBeforeLocalModelsStillLoads() throws {
        let saved = #"{"kind":"codex","surface":"s","cwd":null,"value":"v","venice":"m"}"#
        let entry = try JSONDecoder().decode(ResumeAfterUpdate.Entry.self, from: Data(saved.utf8))
        #expect(entry.venice == "m")
        #expect(entry.localModel == nil && entry.localProvider == nil)
    }

    @Test func aSessionThatIsntOnDiskIsntLocal() {
        #expect(LocalCodex.session("00000000-0000-0000-0000-000000000000") == nil)
    }
}
