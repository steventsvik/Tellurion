#if os(macOS)
import Foundation

/// A model in Ollama or LM Studio, as far as a small job cares: is it in memory, how much it
/// can read at once, and whether it writes text at all.
struct SmallJobModel: Equatable, Identifiable {
    let host: LocalModel.Host
    let name: String
    /// On disk, in bytes (Ollama says; LM Studio doesn't).
    var size: Int64?
    /// In memory now, so asking it loads nothing.
    var loaded: Bool
    /// The context it answers with, in tokens: what it's loaded with, or what a server gives
    /// a model it loads by itself.
    var context: Int
    /// An embedding model: it turns text into numbers and can't write any.
    var embedding = false
    /// Thinks before it answers unless told not to.
    var thinks = false

    /// The same as `LocalModel.id`.
    var id: String { host.rawValue + "/" + name }
}

/// Which model on this Mac gets a small job, and whether the job fits in it.
enum SmallJobModels {
    /// What Ollama and LM Studio serve a model with when they load it by themselves. A longer
    /// prompt would be cut short without a word, so an unloaded model is counted as this.
    static let unloadedContext = 4096
    /// Ollama before it reported a loaded model's context.
    static let unknownContext = 2048
    /// The biggest model Automatic may load by itself, on disk. Bigger ones only run when
    /// they're already in memory or you picked them.
    static let lightLoad: Int64 = 2_000_000_000

    enum Choice: Equatable {
        case model(SmallJobModel)
        /// Why nothing on this Mac gets the job.
        case none(String)
    }

    // MARK: Fit

    /// Roughly how many tokens a text is.
    static func tokens(_ characters: Int) -> Int {
        Int((Double(characters) / 3.5).rounded(.up))
    }

    /// Whether a prompt and its answer fit in a context with room to spare.
    static func fits(characters: Int, output: Int, context: Int) -> Bool {
        tokens(characters) + output + 64 <= Int(Double(context) * 0.85)
    }

    // MARK: Choosing

    /// The model for a job of `characters` with `output` tokens to answer in. `chosen` is the
    /// id picked in Settings; nil or empty is Automatic: a model that's already loaded, else
    /// the smallest one that's light to load. Never an embedding model.
    static func pick(_ models: [SmallJobModel], chosen: String?, characters: Int, output: Int) -> Choice {
        let usable = models.filter { !$0.embedding }
        func fits(_ model: SmallJobModel) -> Bool { Self.fits(characters: characters, output: output, context: model.context) }
        if let chosen, !chosen.isEmpty {
            guard let model = usable.first(where: { $0.id == chosen }) else { return .none("the chosen model isn't available") }
            return fits(model) ? .model(model) : .none("the prompt is too long for the model")
        }
        let bySize: (SmallJobModel, SmallJobModel) -> Bool = { ($0.size ?? .max, $0.name) < ($1.size ?? .max, $1.name) }
        let candidates = usable.filter(\.loaded).sorted(by: bySize)
            + usable.filter { !$0.loaded && ($0.size ?? .max) <= lightLoad }.sorted(by: bySize)
        guard !candidates.isEmpty else {
            return .none(usable.isEmpty ? "no model on this Mac" : "no model is loaded")
        }
        guard let model = candidates.first(where: fits) else { return .none("the prompt is too long for the model") }
        return .model(model)
    }

    // MARK: Reading the servers' lists

    /// Ollama's models from `/api/tags`, with what's loaded from `/api/ps`.
    static func ollama(tags: [String: Any]?, running: [String: Any]?) -> [SmallJobModel] {
        var served: [String: Int] = [:]
        for row in running?["models"] as? [[String: Any]] ?? [] {
            guard let name = row["name"] as? String else { continue }
            served[name] = (row["context_length"] as? NSNumber)?.intValue ?? unknownContext
        }
        return (tags?["models"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let details = row["details"] as? [String: Any] ?? [:]
            let capabilities = row["capabilities"] as? [String]
            let own = (details["context_length"] as? NSNumber)?.intValue ?? unloadedContext
            return SmallJobModel(host: .ollama, name: name, size: (row["size"] as? NSNumber)?.int64Value,
                                 loaded: served[name] != nil, context: served[name] ?? min(own, unloadedContext),
                                 embedding: isEmbedding(name: name, capabilities: capabilities, family: details["family"] as? String),
                                 thinks: capabilities?.contains("thinking") ?? false)
        }
    }

    /// LM Studio's models from `/api/v0/models`.
    static func lmStudio(_ reply: [String: Any]?) -> [SmallJobModel] {
        (reply?["data"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["id"] as? String else { return nil }
            let loaded = row["state"] as? String == "loaded"
            let own = (row["max_context_length"] as? NSNumber)?.intValue ?? unloadedContext
            let served = (row["loaded_context_length"] as? NSNumber)?.intValue
            return SmallJobModel(host: .lmStudio, name: name, size: nil, loaded: loaded,
                                 context: loaded ? served ?? min(own, unloadedContext) : min(own, unloadedContext),
                                 embedding: !["llm", "vlm"].contains(row["type"] as? String ?? "llm"))
        }
    }

    /// Ollama says what a model can do; an older one doesn't, and then the name has to tell.
    static func isEmbedding(name: String, capabilities: [String]?, family: String?) -> Bool {
        if let capabilities { return !capabilities.contains("completion") }
        let name = name.lowercased()
        if let family = family?.lowercased(), family.contains("bert") { return true }
        return ["embed", "bge-", "minilm", "e5-", "gte-"].contains { name.contains($0) }
    }
}
#endif
