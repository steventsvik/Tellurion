#if os(macOS)
import Foundation

/// What agent usage would cost at API prices, for the activity dashboard's dollar view.
///
/// Claude's rates are Anthropic's list prices per million tokens, the same table Claude
/// Code uses for its own cost display. Codex's come from OpenAI's API pricing page
/// (Standard tier, standard context), and the user can override them or price models
/// that aren't listed (see `codexRates`).
enum APIPricing {
    /// Dollars per million tokens.
    struct Rates: Equatable {
        let input: Double
        let output: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double
    }

    private static let tier15x75 = Rates(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5)
    private static let tier5x25 = Rates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5)
    private static let tier4x20 = Rates(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2)
    private static let tier3x15 = Rates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3)
    private static let tier2x10 = Rates(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2)
    private static let tier10x50 = Rates(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1)
    private static let tier10x50Read025 = Rates(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25)
    private static let tier30x150 = Rates(input: 30, output: 150, cacheWrite5m: 37.5, cacheWrite1h: 60, cacheRead: 3)
    private static let tier8x40 = Rates(input: 8, output: 40, cacheWrite5m: 10, cacheWrite1h: 16, cacheRead: 0.4)
    private static let tier8x40Read02 = Rates(input: 8, output: 40, cacheWrite5m: 10, cacheWrite1h: 16, cacheRead: 0.2)
    private static let tier16x80 = Rates(input: 16, output: 80, cacheWrite5m: 20, cacheWrite1h: 32, cacheRead: 0.4)
    private static let tier2x10Read01 = Rates(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.1)
    private static let haiku45 = Rates(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1)
    private static let haiku35 = Rates(input: 0.8, output: 4, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08)

    private static let claudeRates: [String: Rates] = [
        "opus-5-5": tier4x20, "opus-5": tier5x25, "opus-4-8": tier5x25, "opus-4-7": tier5x25, "opus-4-6": tier5x25,
        "opus-4-5": tier5x25, "opus-4-1": tier15x75, "opus-4-0": tier15x75, "opus-4": tier15x75,
        "sonnet-5-5": tier2x10Read01, "sonnet-5": tier2x10, "sonnet-4-6": tier3x15, "sonnet-4-5": tier3x15,
        "sonnet-4-0": tier3x15, "sonnet-4": tier3x15, "3-7-sonnet": tier3x15, "3-5-sonnet": tier3x15,
        "haiku-4-5": haiku45, "3-5-haiku": haiku35,
        "fable-5-2": tier8x40Read02, "mythos-5-2": tier8x40Read02,
        "fable-5-1": tier10x50Read025, "fable-5": tier10x50, "mythos-5-1": tier10x50Read025, "mythos-5": tier10x50,
    ]

    /// Fast mode is billed at a premium on the models that offer it.
    private static let claudeFastRates: [String: Rates] = [
        "opus-5-5": tier8x40, "opus-5": tier10x50, "opus-4-8": tier10x50, "opus-4-7": tier30x150, "opus-4-6": tier30x150,
        "fable-5-2": tier16x80, "mythos-5-2": tier16x80,
    ]

    /// "claude-haiku-4-5-20251001" or "claude-opus-5-5[1m]" -> "haiku-4-5", "opus-5-5".
    static func claudeKey(_ model: String) -> String {
        var key = model.lowercased()
        if key.hasPrefix("claude-") { key.removeFirst(7) }
        if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
        // Drop a trailing release date.
        if let range = key.range(of: #"-\d{8}$"#, options: .regularExpression) { key.removeSubrange(range) }
        return key
    }

    static func claude(model: String, fast: Bool) -> Rates? {
        let key = claudeKey(model)
        if fast, let rates = claudeFastRates[key] { return rates }
        return claudeRates[key]
    }

    /// The API cost of one Claude response's `usage`, split into what it read (input and
    /// cache) and what it wrote (output), in dollars.
    static func claudeCost(model: String, usage: [String: Any]) -> (input: Double, output: Double)? {
        guard let rates = claude(model: model, fast: usage["speed"] as? String == "fast") else { return nil }
        let input = Double(usage["input_tokens"] as? Int ?? 0)
        let output = Double(usage["output_tokens"] as? Int ?? 0)
        let read = Double(usage["cache_read_input_tokens"] as? Int ?? 0)
        let written = Double(usage["cache_creation_input_tokens"] as? Int ?? 0)
        let details = usage["cache_creation"] as? [String: Any]
        let hour = min(Double(details?["ephemeral_1h_input_tokens"] as? Int ?? 0), written)
        var inputCost = input * rates.input + read * rates.cacheRead + hour * rates.cacheWrite1h + (written - hour) * rates.cacheWrite5m
        var outputCost = output * rates.output
        // US-only inference is billed at 1.1×.
        if usage["inference_geo"] as? String == "us" {
            inputCost *= 1.1
            outputCost *= 1.1
        }
        let searches = Double((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0)
        return (inputCost / 1_000_000 + searches * 0.01, outputCost / 1_000_000)
    }

    // MARK: Codex

    static let codexRatesKey = "ActivityCodexRates"

    /// Dollars per million tokens for a Codex model: fresh input, cached input, output.
    struct CodexRates: Equatable {
        var input: Double
        var cached: Double
        var output: Double
    }

    /// OpenAI's published Standard-tier prices (developers.openai.com/api/docs/pricing,
    /// September 2026). Long-context requests cost more; they aren't distinguished here.
    static let publishedCodexRates: [String: CodexRates] = [
        "gpt-6.1-sol": CodexRates(input: 2, cached: 0.1, output: 10),
        "gpt-6-astra": CodexRates(input: 10, cached: 1, output: 50),
        "gpt-5.6-sol": CodexRates(input: 4, cached: 0.4, output: 20),
        "gpt-5.6-luna": CodexRates(input: 0.2, cached: 0.02, output: 1.2),
        "gpt-5.3-codex": CodexRates(input: 1.75, cached: 0.175, output: 14),
    ]

    /// Published prices, with the user's own rates on top.
    static var codexRates: [String: CodexRates] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: codexRatesKey) as? [String: [Double]] ?? [:]
            let own = stored.compactMapValues { $0.count == 3 ? CodexRates(input: $0[0], cached: $0[1], output: $0[2]) : nil }
            return publishedCodexRates.merging(own) { _, mine in mine }
        }
        set {
            // Only what differs from the published prices is the user's own.
            let own = newValue.filter { publishedCodexRates[$0.key] != $0.value }
            UserDefaults.standard.set(own.mapValues { [$0.input, $0.cached, $0.output] }, forKey: codexRatesKey)
        }
    }

    /// `tokens` is [input, cached input, output]; input includes the cached part.
    static func codexCost(model: String, tokens: [Int], rates: [String: CodexRates]) -> (input: Double, output: Double)? {
        guard tokens.count == 3, let rate = rates[model] else { return nil }
        let cached = Double(min(tokens[1], tokens[0]))
        let fresh = Double(tokens[0]) - cached
        return ((fresh * rate.input + cached * rate.cached) / 1_000_000, Double(tokens[2]) * rate.output / 1_000_000)
    }
}
#endif
