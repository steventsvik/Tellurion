import Foundation
import Testing
@testable import Ghostty

/// Which model on this Mac gets a small job, and whether the job fits in it.
struct SmallJobModelsTests {
    private func model(_ name: String, host: LocalModel.Host = .ollama, size: Int64? = 4_000_000_000, loaded: Bool = false,
                       context: Int = 4096, embedding: Bool = false) -> SmallJobModel {
        SmallJobModel(host: host, name: name, size: size, loaded: loaded, context: context, embedding: embedding)
    }

    private func pick(_ models: [SmallJobModel], chosen: String? = nil, characters: Int = 700) -> SmallJobModels.Choice {
        SmallJobModels.pick(models, chosen: chosen, characters: characters, output: 220)
    }

    @Test func automaticPrefersAModelThatIsAlreadyLoaded() {
        let small = model("tiny:1b", size: 800_000_000)
        let loaded = model("big:27b", size: 17_000_000_000, loaded: true, context: 32768)
        #expect(pick([small, loaded]) == .model(loaded))
        // Of two loaded ones, the smaller.
        let other = model("mid:4b", size: 2_500_000_000, loaded: true)
        #expect(pick([loaded, other, small]) == .model(other))
        #expect(pick([small, loaded], chosen: "") == .model(loaded))
    }

    @Test func automaticNeverPicksAnEmbeddingModel() {
        let embedding = model("nomic-embed-text:latest", size: 270_000_000, loaded: true, embedding: true)
        let chat = model("tiny:1b", size: 800_000_000)
        #expect(pick([embedding, chat]) == .model(chat))
        #expect(pick([embedding]) == .none("no model on this Mac"))
        #expect(pick([embedding], chosen: embedding.id) == .none("the chosen model isn't available"))
    }

    @Test func automaticNeverLoadsABigModel() {
        let big = model("big:27b", size: 17_000_000_000)
        let studio = model("some-model", host: .lmStudio, size: nil)
        #expect(pick([big, studio]) == .none("no model is loaded"))
        #expect(pick([]) == .none("no model on this Mac"))
        // The smallest one that's light to load.
        let light = model("light:1b", size: 1_200_000_000), lighter = model("lighter:0.5b", size: 400_000_000)
        #expect(pick([big, light, lighter, studio]) == .model(lighter))
        #expect(SmallJobModels.lightLoad == 2_000_000_000)
    }

    @Test func aModelYouChoseMayLoad() {
        let big = model("big:27b", size: 17_000_000_000)
        let loaded = model("mid:4b", loaded: true)
        #expect(pick([big, loaded], chosen: big.id) == .model(big))
        #expect(big.id == "Ollama/big:27b")
        #expect(pick([loaded], chosen: big.id) == .none("the chosen model isn't available"))
    }

    @Test func aPromptThatDoesNotFitGoesNowhereOnThisMac() {
        let loaded = model("mid:4b", loaded: true, context: 4096)
        let roomy = model("roomy:8b", size: 6_000_000_000, loaded: true, context: 32768)
        #expect(pick([loaded], characters: 20_000) == .none("the prompt is too long for the model"))
        #expect(pick([loaded], chosen: loaded.id, characters: 20_000) == .none("the prompt is too long for the model"))
        // The one it fits in, though it's bigger.
        #expect(pick([loaded, roomy], characters: 20_000) == .model(roomy))
    }

    @Test func thePromptHasToFitWithRoomForTheAnswer() {
        #expect(SmallJobModels.tokens(0) == 0)
        #expect(SmallJobModels.tokens(35) == 10)
        #expect(SmallJobModels.tokens(36) == 11)
        // 4096 × 0.85 = 3481 tokens to use; 220 for the answer and 64 spare leave 3197 for the prompt.
        #expect(SmallJobModels.fits(characters: 11_189, output: 220, context: 4096))
        #expect(!SmallJobModels.fits(characters: 11_200, output: 220, context: 4096))
        #expect(SmallJobModels.fits(characters: CommitSuggestion.limit, output: SmallJob.Kind.commitMessage.outputTokens,
                                    context: SmallJobModels.unloadedContext))
        #expect(!SmallJobModels.fits(characters: 100, output: 220, context: 256))
    }

    private func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    @Test func ollamaListSaysWhatIsLoadedAndWithHowMuchContext() {
        let tags = json("""
        {"models":[
          {"name":"big:27b","size":17741860746,"details":{"family":"qwen35","context_length":262144},"capabilities":["completion","vision","tools","thinking"]},
          {"name":"plain:7b","size":4108940323,"details":{"family":"llama","context_length":32768},"capabilities":["completion"]},
          {"name":"nomic-embed-text:latest","size":274302450,"details":{"family":"nomic-bert","context_length":2048},"capabilities":["embedding"]},
          {"name":"old:1b","size":900000000,"details":{"family":"llama"}},
          {"name":"all-minilm:latest","size":45000000,"details":{"family":"bert"}}
        ]}
        """)
        let running = json(#"{"models":[{"name":"plain:7b","size":5000000000,"size_vram":5000000000,"context_length":8192}]}"#)
        let models = SmallJobModels.ollama(tags: tags, running: running)
        #expect(models.map(\.name) == ["big:27b", "plain:7b", "nomic-embed-text:latest", "old:1b", "all-minilm:latest"])
        #expect(models.map(\.loaded) == [false, true, false, false, false])
        // Loaded: what it's served with. Not loaded: what the server would give it, not the model's most.
        #expect(models.map(\.context) == [4096, 8192, 2048, 4096, 4096])
        #expect(models.map(\.embedding) == [false, false, true, false, true])
        #expect(models.map(\.thinks) == [true, false, false, false, false])
        #expect(models[0].size == 17_741_860_746)
        #expect(SmallJobModels.ollama(tags: nil, running: nil).isEmpty)
        // An older Ollama doesn't say what a loaded model is served with.
        let older = SmallJobModels.ollama(tags: tags, running: json(#"{"models":[{"name":"old:1b"}]}"#))
        #expect(older[3].loaded && older[3].context == SmallJobModels.unknownContext)
    }

    @Test func lmStudioListSaysWhatIsLoadedAndSkipsEmbeddings() {
        let reply = json("""
        {"data":[
          {"id":"qwen-coder","type":"llm","state":"loaded","max_context_length":32768,"loaded_context_length":8192},
          {"id":"vision-model","type":"vlm","state":"not-loaded","max_context_length":131072},
          {"id":"text-embedding-nomic","type":"embeddings","state":"not-loaded","max_context_length":2048}
        ]}
        """)
        let models = SmallJobModels.lmStudio(reply)
        #expect(models.map(\.id) == ["LM Studio/qwen-coder", "LM Studio/vision-model", "LM Studio/text-embedding-nomic"])
        #expect(models.map(\.loaded) == [true, false, false])
        #expect(models.map(\.context) == [8192, 4096, 2048])
        #expect(models.map(\.embedding) == [false, false, true])
        #expect(models.allSatisfy { $0.size == nil })
        #expect(SmallJobModels.lmStudio(nil).isEmpty)
    }

    @Test func anEmbeddingModelIsKnownByWhatItCanDoOrItsName() {
        #expect(SmallJobModels.isEmbedding(name: "x", capabilities: ["embedding"], family: nil))
        #expect(!SmallJobModels.isEmbedding(name: "embedder-that-chats", capabilities: ["completion"], family: nil))
        #expect(SmallJobModels.isEmbedding(name: "mxbai-embed-large", capabilities: nil, family: nil))
        #expect(SmallJobModels.isEmbedding(name: "x", capabilities: nil, family: "nomic-bert"))
        #expect(!SmallJobModels.isEmbedding(name: "qwen3:4b", capabilities: nil, family: "qwen3"))
    }
}
