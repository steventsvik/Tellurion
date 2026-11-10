#if os(macOS)
import Foundation

/// What a session has used so far.
struct BudgetUsage: Equatable {
    /// Tokens in and out, cached context included.
    var tokens = 0
    /// At API prices, for the models whose price is known.
    var dollars = 0.0
    /// Models with no known price: their tokens are counted, their cost isn't.
    var unpriced: Set<String> = []

    /// The cost, or nil when part of it can't be priced.
    var spent: Double? { unpriced.isEmpty ? dollars : nil }

    static func + (a: BudgetUsage, b: BudgetUsage) -> BudgetUsage {
        BudgetUsage(tokens: a.tokens + b.tokens, dollars: a.dollars + b.dollars, unpriced: a.unpriced.union(b.unpriced))
    }
}

/// The prices a Codex session is costed with. Claude's are fixed (see `APIPricing`).
struct BudgetPrices: Equatable {
    /// OpenAI's models, with the user's own rates on top (`APIPricing.codexRates`).
    var codex: [String: APIPricing.CodexRates] = [:]
    /// Venice's models, from its own list, once that has been read.
    var venice: [String: APIPricing.CodexRates] = [:]
    /// The provider the pane reported ("venice", "ollama"), for a transcript that doesn't name one.
    var provider: String?
}

/// Adds up one transcript's usage a piece at a time: it remembers how far it has read and
/// only parses the complete lines added since. The per-line reading is the Activity window's
/// (`ActivityStats.parseClaude` and `parseCodex`), kept here so it can go line by line.
struct TranscriptMeter {
    enum Format: Equatable {
        case claude
        case codex
    }

    let format: Format
    /// Bytes read so far, always ending after a newline.
    private(set) var offset: UInt64 = 0
    /// The file being read; a different one at the same path starts over.
    private var fileID: UInt64?

    // Claude: each response carries its own usage, repeated on every line of a streamed reply.
    private var claudeTokens = 0
    private var claudeDollars = 0.0
    private var claudeUnpriced: Set<String> = []
    private var seenMessages: Set<String> = []
    /// The reply still being written and what it has added, so its last line's figures count.
    private var latest: (id: String, tokens: Int, dollars: Double)?

    // Codex: totals are cumulative; each increase goes to the model in use at the time.
    private var codexModel = "unknown"
    private var codexCounted = [0, 0, 0]
    /// [input, cached input, output] per model.
    private(set) var codexTokens: [String: [Int]] = [:]
    /// The provider the session recorded ("openai", "venice", "ollama").
    private(set) var codexProvider: String?

    init(format: Format) {
        self.format = format
    }

    /// Reads what was added to `url` since the last call. A file that shrank or was replaced
    /// (a new one at the same path) is read again from the start.
    mutating func read(_ url: URL, chunk: Int = 1 << 20) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let id = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
        if size < offset || (fileID != nil && id != nil && fileID != id) { self = TranscriptMeter(format: format) }
        fileID = id ?? fileID
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil else { return }
        var pending = Data()
        while let data = try? handle.read(upToCount: max(chunk, 1)), !data.isEmpty {
            pending.append(data)
            // A line still being written stays unread until its newline arrives.
            guard let end = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...end]
            for line in complete.split(separator: 0x0A) { add(line: line) }
            offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: end)...])
        }
    }

    /// Takes one complete line of the transcript.
    mutating func add(line: Data) {
        switch format {
        case .claude:
            guard line.range(of: Self.usageMarker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            addClaude(record)
        case .codex:
            guard line.range(of: Self.tokenMarker) != nil || line.range(of: Self.contextMarker) != nil
                    || line.range(of: Self.metaMarker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            addCodex(record)
        }
    }

    // Most lines are tool output with no usage; these skip decoding them.
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let tokenMarker = Data("token_count".utf8)
    private static let contextMarker = Data("turn_context".utf8)
    private static let metaMarker = Data("session_meta".utf8)

    private mutating func addClaude(_ record: [String: Any]) {
        guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any],
              let id = message["id"] as? String, let usage = message["usage"] as? [String: Any] else { return }
        if let latest, latest.id == id {
            // The same reply again: its newest figures replace the ones counted before.
            claudeTokens -= latest.tokens
            claudeDollars -= latest.dollars
        } else if !seenMessages.insert(id).inserted {
            return
        }
        let tokens = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0) + (usage["output_tokens"] as? Int ?? 0)
        var dollars = 0.0
        let model = message["model"] as? String ?? "unknown"
        if let cost = APIPricing.claudeCost(model: model, usage: usage) {
            dollars = cost.input + cost.output
        } else if tokens > 0 {
            claudeUnpriced.insert(model)
        }
        claudeTokens += tokens
        claudeDollars += dollars
        latest = (id, tokens, dollars)
    }

    private mutating func addCodex(_ record: [String: Any]) {
        let payload = record["payload"] as? [String: Any] ?? [:]
        let type = record["type"] as? String
        if type == "session_meta", let provider = payload["model_provider"] as? String { codexProvider = provider }
        if type == "turn_context", let name = payload["model"] as? String, !name.isEmpty { codexModel = name }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
        let total = [usage["input_tokens"] as? Int ?? 0, usage["cached_input_tokens"] as? Int ?? 0,
                     usage["output_tokens"] as? Int ?? 0]
        let delta = zip(total, codexCounted).map { max(0, $0 - $1) }
        if delta.contains(where: { $0 > 0 }) {
            codexTokens[codexModel] = zip(codexTokens[codexModel] ?? [0, 0, 0], delta).map(+)
        }
        codexCounted = zip(total, codexCounted).map { max($0, $1) }
    }

    /// What has been read so far, at `prices`.
    func usage(_ prices: BudgetPrices) -> BudgetUsage {
        switch format {
        case .claude:
            return BudgetUsage(tokens: claudeTokens, dollars: claudeDollars, unpriced: claudeUnpriced)
        case .codex:
            // Input already includes the cached part.
            var usage = BudgetUsage(tokens: codexCounted[0] + codexCounted[2])
            let provider = codexProvider ?? prices.provider
            // A model on this Mac costs nothing; only its tokens count.
            if let provider, LocalCodex.providers.contains(provider) { return usage }
            let rates = provider == VeniceCodex.provider ? prices.venice : prices.codex
            for (model, tokens) in codexTokens {
                if let cost = APIPricing.codexCost(model: model, tokens: tokens, rates: rates) {
                    usage.dollars += cost.input + cost.output
                } else if tokens.contains(where: { $0 > 0 }) {
                    usage.unpriced.insert(model)
                }
            }
            return usage
        }
    }
}

/// One session's transcript and, for Claude Code, the transcripts of the sub-agents it
/// started (`<session>/subagents/*.jsonl` beside it), whose spend is their own and adds up.
struct SessionMeter {
    let transcript: URL
    private(set) var main: TranscriptMeter
    private(set) var subagents: [String: TranscriptMeter] = [:]
    /// When the transcript was created: when the session started.
    private(set) var started: Date?

    init(transcript: URL, format: TranscriptMeter.Format) {
        self.transcript = transcript
        main = TranscriptMeter(format: format)
    }

    /// When the session started, read once from the transcript's creation date.
    mutating func start() -> Date? {
        if started == nil {
            started = (try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.creationDate] as? Date
        }
        return started
    }

    /// Reads what's new in the transcript and in each sub-agent's.
    mutating func read() {
        main.read(transcript)
        guard main.format == .claude else { return }
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".jsonl") {
            var meter = subagents[name] ?? TranscriptMeter(format: .claude)
            meter.read(folder.appendingPathComponent(name))
            subagents[name] = meter
        }
    }

    func usage(_ prices: BudgetPrices) -> BudgetUsage {
        subagents.values.reduce(main.usage(prices)) { $0 + $1.usage(prices) }
    }
}
#endif
