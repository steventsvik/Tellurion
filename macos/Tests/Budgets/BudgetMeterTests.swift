import Foundation
import Testing
@testable import Ghostty

/// Measuring a session from its transcript a piece at a time, at the Activity window's prices.
struct BudgetMeterTests {
    private let prices = BudgetPrices(codex: APIPricing.publishedCodexRates)

    /// One line of a Claude Code transcript: a response with its usage.
    private func claude(_ id: String, model: String = "claude-sonnet-4-5-20250929", input: Int = 1000, written: Int = 2000,
                        read: Int = 10_000, output: Int = 500) -> String {
        """
        {"type":"assistant","timestamp":"2026-10-01T10:00:00.000Z","cwd":"/tmp/project","message":{"id":"\(id)","model":"\(model)",\
        "content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(written),\
        "cache_read_input_tokens":\(read),"output_tokens":\(output),"cache_creation":{"ephemeral_5m_input_tokens":\(written),\
        "ephemeral_1h_input_tokens":0}}}}
        """
    }

    /// One line of a Codex rollout: the session's running totals.
    private func codexTotals(input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"2026-10-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\
        {"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}}}}
        """
    }

    private func codexMeta(provider: String) -> String {
        #"{"timestamp":"2026-10-01T10:00:00.000Z","type":"session_meta","payload":{"id":"0198c5f2","cwd":"/tmp/project","model_provider":"\#(provider)"}}"#
    }

    private func codexModel(_ model: String) -> String {
        #"{"timestamp":"2026-10-01T10:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp/project","model":"\#(model)"}}"#
    }

    private func meter(_ format: TranscriptMeter.Format, _ lines: [String]) -> TranscriptMeter {
        var meter = TranscriptMeter(format: format)
        for line in lines { meter.add(line: Data(line.utf8)) }
        return meter
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func append(_ text: String, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func near(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 1e-9
    }

    // MARK: Cost

    @Test func aClaudeResponseIsCostedAtAPIPrices() {
        let usage = meter(.claude, [claude("msg_1")]).usage(prices)
        // Sonnet 4.5: $3 in, $15 out, $3.75 written to the cache, $0.30 read from it, per million.
        #expect(usage.tokens == 13_500)
        let cost: Double = 1000 * 3 + 2000 * 3.75 + 10_000 * 0.3 + 500 * 15
        #expect(near(usage.spent, cost / 1_000_000))
        #expect(usage.unpriced.isEmpty)
    }

    @Test func aStreamedReplyCountsOnceWithItsLastFigures() {
        // The same message on three lines, its output growing; then an earlier one again.
        let lines = [claude("msg_1", output: 500), claude("msg_2", output: 1), claude("msg_2", output: 40),
                     claude("msg_2", output: 900), claude("msg_1", output: 500)]
        let usage = meter(.claude, lines).usage(prices)
        #expect(usage.tokens == 13_500 + 13_900)
        let input: Double = 1000 * 3 + 2000 * 3.75 + 10_000 * 0.3
        let output: Double = (500 + 900) * 15
        #expect(near(usage.spent, (input * 2 + output) / 1_000_000))
    }

    @Test func aModelWithNoPriceCountsTokensOnly() {
        let usage = meter(.claude, [claude("msg_1"), claude("msg_2", model: "claude-nova-9")]).usage(prices)
        #expect(usage.tokens == 27_000)
        #expect(usage.spent == nil)
        #expect(usage.unpriced == ["claude-nova-9"])
    }

    @Test func linesWithoutUsageAreSkipped() {
        let lines = [#"{"type":"user","message":{"content":"what's my \"usage\" so far?"}}"#, "not json \"usage\"", "",
                     #"{"type":"assistant","message":{"id":"msg_0","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#]
        let usage = meter(.claude, lines).usage(prices)
        #expect(usage == BudgetUsage())
    }

    @Test func codexTotalsAreCumulativeAndGoToTheModelInUse() {
        let lines = [codexMeta(provider: "openai"), codexModel("gpt-5.3-codex"),
                     codexTotals(input: 60_000, cached: 40_000, output: 1000),
                     codexTotals(input: 100_000, cached: 80_000, output: 2000),
                     // The same totals again add nothing.
                     codexTotals(input: 100_000, cached: 80_000, output: 2000),
                     codexModel("gpt-5.6-luna"),
                     codexTotals(input: 150_000, cached: 80_000, output: 3000)]
        let read = meter(.codex, lines)
        #expect(read.codexTokens["gpt-5.3-codex"] == [100_000, 80_000, 2000])
        #expect(read.codexTokens["gpt-5.6-luna"] == [50_000, 0, 1000])
        let usage = read.usage(prices)
        #expect(usage.tokens == 153_000)
        // gpt-5.3-codex: $1.75 fresh, $0.175 cached, $14 out. gpt-5.6-luna: $0.20 in, $1.20 out.
        let first: Double = (20_000 * 1.75 + 80_000 * 0.175 + 2000 * 14) / 1_000_000
        let second: Double = (50_000 * 0.2 + 1000 * 1.2) / 1_000_000
        #expect(near(usage.spent, first + second))
    }

    @Test func aCodexModelWithNoPriceCountsTokensOnly() {
        let usage = meter(.codex, [codexModel("gpt-9-unlisted"), codexTotals(input: 5000, cached: 0, output: 100)]).usage(prices)
        #expect(usage.tokens == 5100)
        #expect(usage.spent == nil)
        #expect(usage.unpriced == ["gpt-9-unlisted"])
    }

    @Test func codexOnAModelOnThisMacCostsNothing() {
        let lines = [codexMeta(provider: "ollama"), codexModel("qwen3:4b"), codexTotals(input: 5000, cached: 0, output: 100)]
        let usage = meter(.codex, lines).usage(prices)
        #expect(usage.tokens == 5100)
        #expect(usage.spent == 0)
        // The pane's own word for it counts when the transcript doesn't say.
        var hinted = prices
        hinted.provider = "lmstudio"
        #expect(meter(.codex, Array(lines.dropFirst())).usage(hinted).spent == 0)
    }

    @Test func codexOnVeniceUsesVenicesPrices() {
        let model = VeniceAPI.Model(id: "qwen3-coder", name: "Qwen 3 Coder", uncensored: false, isPrivate: true, context: nil,
                                    maxOutput: nil, inputPrice: 0.5, cachedInputPrice: nil, outputPrice: 2, tools: true,
                                    optimizedForCode: true, vision: false, reasoning: false, encrypted: false)
        var unlisted = model
        unlisted.inputPrice = nil
        let rates = AgentBudgets.veniceRates([model, unlisted])
        #expect(rates == ["qwen3-coder": APIPricing.CodexRates(input: 0.5, cached: 0.5, output: 2)])

        let lines = [codexMeta(provider: VeniceCodex.provider), codexModel("qwen3-coder"),
                     codexTotals(input: 1_000_000, cached: 0, output: 100_000)]
        var venice = prices
        venice.venice = rates
        #expect(near(meter(.codex, lines).usage(venice).spent, 0.5 + 0.2))
        // Before Venice's list has been read there's no price, and OpenAI's aren't used instead.
        #expect(meter(.codex, lines).usage(prices).spent == nil)
    }

    // MARK: Reading a growing file

    @Test func onlyAppendedLinesAreRead() throws {
        let file = try folder().appendingPathComponent("session.jsonl")
        try append(claude("msg_1") + "\n", to: file)
        var meter = TranscriptMeter(format: .claude)
        meter.read(file)
        let first = meter.offset
        #expect(meter.usage(prices).tokens == 13_500)
        #expect(first == UInt64((claude("msg_1") + "\n").utf8.count))

        // Nothing new: nothing changes.
        meter.read(file)
        #expect(meter.offset == first)
        #expect(meter.usage(prices).tokens == 13_500)

        try append(claude("msg_2") + "\n" + claude("msg_3") + "\n", to: file)
        meter.read(file)
        #expect(meter.usage(prices).tokens == 13_500 * 3)
        #expect(meter.offset > first)
    }

    @Test func aLineStillBeingWrittenWaitsForItsEnd() throws {
        let file = try folder().appendingPathComponent("session.jsonl")
        let second = claude("msg_2")
        let cut = second.index(second.startIndex, offsetBy: 80)
        try append(claude("msg_1") + "\n" + String(second[..<cut]), to: file)
        var meter = TranscriptMeter(format: .claude)
        meter.read(file)
        #expect(meter.usage(prices).tokens == 13_500)
        #expect(meter.offset == UInt64((claude("msg_1") + "\n").utf8.count))

        try append(String(second[cut...]) + "\n", to: file)
        meter.read(file)
        #expect(meter.usage(prices).tokens == 27_000)
    }

    @Test func longLinesAreReadAcrossSmallChunks() throws {
        let file = try folder().appendingPathComponent("session.jsonl")
        try append(claude("msg_1") + "\n" + claude("msg_2") + "\n" + claude("msg_3"), to: file)
        var meter = TranscriptMeter(format: .claude)
        meter.read(file, chunk: 16)
        #expect(meter.usage(prices).tokens == 27_000)
        #expect(meter.offset == UInt64((claude("msg_1") + "\n" + claude("msg_2") + "\n").utf8.count))
    }

    @Test func aFileThatShrinksIsReadFromTheStart() throws {
        let file = try folder().appendingPathComponent("rollout.jsonl")
        try append(codexModel("gpt-5.3-codex") + "\n" + codexTotals(input: 100_000, cached: 0, output: 2000) + "\n", to: file)
        var meter = TranscriptMeter(format: .codex)
        meter.read(file)
        #expect(meter.usage(prices).tokens == 102_000)

        // Rewritten shorter, in place.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((codexTotals(input: 3000, cached: 0, output: 50) + "\n").utf8))
        try handle.close()
        meter.read(file)
        #expect(meter.usage(prices).tokens == 3050)
        #expect(meter.codexTokens["gpt-5.3-codex"] == nil)
    }

    @Test func aNewFileAtTheSamePathIsReadFromTheStart() throws {
        let folder = try folder()
        let file = folder.appendingPathComponent("session.jsonl")
        try append(claude("msg_1") + "\n", to: file)
        var meter = TranscriptMeter(format: .claude)
        meter.read(file)
        // Replaced by a longer file: the size alone wouldn't say so.
        let other = folder.appendingPathComponent("other.jsonl")
        try append(claude("msg_7", output: 100) + "\n" + claude("msg_8", output: 100) + "\n", to: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: other, to: file)
        meter.read(file)
        #expect(meter.usage(prices).tokens == 13_100 * 2)
    }

    @Test func aMissingFileIsNothingYet() {
        var meter = TranscriptMeter(format: .claude)
        meter.read(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl"))
        #expect(meter.offset == 0)
        #expect(meter.usage(prices) == BudgetUsage())
    }

    @Test func subagentsSpendAddsToTheSessions() throws {
        let folder = try folder()
        let transcript = folder.appendingPathComponent("0198c5f2.jsonl")
        try append(claude("msg_1") + "\n", to: transcript)
        var session = SessionMeter(transcript: transcript, format: .claude)
        session.read()
        #expect(session.usage(prices).tokens == 13_500)
        let started = session.start()
        #expect(started != nil)

        let subagents = folder.appendingPathComponent("0198c5f2/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try append(claude("msg_a") + "\n", to: subagents.appendingPathComponent("agent-1.jsonl"))
        try append("not a transcript\n", to: subagents.appendingPathComponent("notes.txt"))
        session.read()
        #expect(session.usage(prices).tokens == 27_000)
        try append(claude("msg_b") + "\n", to: subagents.appendingPathComponent("agent-1.jsonl"))
        try append(claude("msg_c") + "\n", to: subagents.appendingPathComponent("agent-2.jsonl"))
        session.read()
        #expect(session.usage(prices).tokens == 13_500 * 4)
    }
}
