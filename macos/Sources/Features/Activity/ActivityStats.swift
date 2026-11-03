#if os(macOS)
import AppKit

/// One agent session, summarized from its transcript on disk. Nothing is recorded by
/// Tellurion itself; Claude Code (~/.claude/projects) and Codex (~/.codex/sessions)
/// already keep everything needed.
struct ActivitySession: Identifiable, Codable, Equatable {
    let id: String
    let agent: String
    /// The provider Codex recorded for the session, and its latest model: a session on Venice
    /// has to resume there, never on another provider.
    var codexProvider: String?
    var codexModel: String?
    var onVenice: Bool { agent == "codex" && codexProvider == VeniceCodex.provider }
    var cwd: String?
    var title: String?
    var firstPrompt: String?
    var start: Date?
    var end: Date?
    var prompts = 0
    var toolCalls = 0
    var commands = 0
    var tests = 0
    var files: Set<String> = []
    var linesAdded = 0
    var linesRemoved = 0
    var tokensIn = 0
    var tokensOut = 0
    /// Claude's cost at API prices per local day: [what it read, what it wrote] in dollars.
    var claudeCostByDay: [String: [Double]] = [:]
    /// Codex tokens per local day and model: [input, cached input, output]. Priced later,
    /// with rates the user enters (see `APIPricing.codexRates`).
    var codexTokens: [String: [String: [Int]]] = [:]
    /// Active seconds per local day ("2026-09-28") and per hour of day (0-23).
    var activeByDay: [String: Double] = [:]
    var activeByHour: [Int: Double] = [:]

    var kind: VerticalTabAgentKind { VerticalTabAgentKind(id: agent) }
    var activeSeconds: Double { activeByDay.values.reduce(0, +) }
    var project: String { cwd.map { LocalhostProject(folder: $0).name } ?? "Unknown" }
    var label: String { title ?? firstPrompt ?? "Untitled session" }
}

/// Reads agents' transcripts into `ActivitySession`s, caching each file's summary by its
/// size and modification date so reopening the dashboard is instant.
final class ActivityStats {
    static let shared = ActivityStats()

    private struct CacheEntry: Codable {
        let size: Int
        let modified: Date
        let session: ActivitySession
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    // v2 added per-day API costs; older summaries are rebuilt once.
    private static let cacheFile = AgentTools.root.appendingPathComponent("activity-cache-v3.json")
    /// Gaps longer than this between events aren't counted as active time.
    private static let idleGap: TimeInterval = 300

    private init() {
        if let data = try? Data(contentsOf: Self.cacheFile),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = decoded
        }
    }

    /// Sessions with activity since `since`. Slow the first time; call off the main thread.
    func sessions(since: Date) -> [ActivitySession] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var claude: [String: [URL]] = [:]
        var codex: [URL] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        // Claude Code: <project>/<session>.jsonl, plus sub-agents in <project>/<session>/subagents/*.jsonl.
        if let walker = fm.enumerator(at: home.appendingPathComponent(".claude/projects"), includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= since else { continue }
                let parent = url.deletingLastPathComponent()
                let session = parent.lastPathComponent == "subagents"
                    ? parent.deletingLastPathComponent().lastPathComponent
                    : url.deletingPathExtension().lastPathComponent
                claude[session, default: []].append(url)
            }
        }
        if let walker = fm.enumerator(at: home.appendingPathComponent(".codex/sessions"), includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified >= since else { continue }
                codex.append(url)
            }
        }

        var result: [ActivitySession] = []
        for (id, files) in claude {
            // The main transcript first, so it names the session.
            let ordered = files.sorted { a, _ in a.deletingLastPathComponent().lastPathComponent != "subagents" }
            var merged: ActivitySession?
            for file in ordered {
                guard let part = summary(of: file, agent: "claude", id: id) else { continue }
                merged = merged.map { Self.merge($0, part) } ?? part
            }
            if let merged, merged.start != nil { result.append(merged) }
        }
        for file in codex {
            let id = file.deletingPathExtension().lastPathComponent
            if let session = summary(of: file, agent: "codex", id: id), session.start != nil { result.append(session) }
        }
        saveCache()
        return result.sorted { ($0.end ?? .distantPast) > ($1.end ?? .distantPast) }
    }

    private func summary(of file: URL, agent: String, id: String) -> ActivitySession? {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate ?? Date()
        lock.lock()
        let cached = cache[file.path]
        lock.unlock()
        if let cached, cached.size == size, cached.modified == modified { return cached.session }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        let session = agent == "codex" ? Self.parseCodex(data, id: id) : Self.parseClaude(data, id: id)
        lock.lock()
        cache[file.path] = CacheEntry(size: size, modified: modified, session: session)
        lock.unlock()
        return session
    }

    private func saveCache() {
        lock.lock()
        // Forget files that are gone.
        cache = cache.filter { FileManager.default.fileExists(atPath: $0.key) }
        let snapshot = cache
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.cacheFile, options: .atomic)
        }
    }

    private static func merge(_ a: ActivitySession, _ b: ActivitySession) -> ActivitySession {
        var m = a
        m.cwd = a.cwd ?? b.cwd
        m.title = a.title ?? b.title
        m.firstPrompt = a.firstPrompt ?? b.firstPrompt
        m.start = [a.start, b.start].compactMap { $0 }.min()
        m.end = [a.end, b.end].compactMap { $0 }.max()
        m.toolCalls += b.toolCalls
        m.commands += b.commands
        m.tests += b.tests
        m.files.formUnion(b.files)
        m.tokensIn += b.tokensIn
        m.tokensOut += b.tokensOut
        // Sub-agents' spend is their own, so it adds up.
        for (day, cost) in b.claudeCostByDay {
            let mine = m.claudeCostByDay[day] ?? [0, 0]
            m.claudeCostByDay[day] = [mine[0] + cost[0], mine[1] + cost[1]]
        }
        for (day, models) in b.codexTokens {
            for (model, tokens) in models {
                let mine = m.codexTokens[day]?[model] ?? [0, 0, 0]
                m.codexTokens[day, default: [:]][model] = zip(mine, tokens).map(+)
            }
        }
        // Sub-agents run while the main agent waits, so their time overlaps; keep the larger.
        for (day, seconds) in b.activeByDay { m.activeByDay[day] = max(m.activeByDay[day] ?? 0, seconds) }
        for (hour, seconds) in b.activeByHour { m.activeByHour[hour] = max(m.activeByHour[hour] ?? 0, seconds) }
        return m
    }

    // MARK: Parsing

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// The local start of the day a `dayKey` names.
    static func date(fromDayKey key: String) -> Date? { dayFormatter.date(from: key) }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    // A fixed, known-good pattern.
    // swiftlint:disable:next force_try
    private static let testPattern = try! NSRegularExpression(
        pattern: #"(^|[\s;&|(])(pytest|jest|vitest|mocha|rspec|phpunit|go test|cargo test|swift test|zig build test|xcodebuild[^\n]*\btest\b|(npm|pnpm|yarn|bun)( run)? test|make test|python -m (pytest|unittest)|playwright test)"#)

    private static func isTest(_ command: String) -> Bool {
        testPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"))
    }

    /// Adds active time between consecutive events.
    private static func accumulate(_ times: [Date], into session: inout ActivitySession) {
        let sorted = times.sorted()
        session.start = sorted.first
        session.end = sorted.last
        let calendar = Calendar.current
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.timeIntervalSince(previous)
            guard gap > 0, gap <= idleGap else { continue }
            session.activeByDay[dayKey(next), default: 0] += gap
            session.activeByHour[calendar.component(.hour, from: next), default: 0] += gap
        }
    }

    private static func cleanPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:"),
              !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return String(trimmed.prefix(200))
    }

    static func parseClaude(_ data: Data, id: String) -> ActivitySession {
        var session = ActivitySession(id: id, agent: "claude")
        var times: [Date] = []
        var seenMessages: Set<String> = []
        var seenTools: Set<String> = []
        for line in lines(data) {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = record["type"] as? String
            if type == "ai-title", let title = record["aiTitle"] as? String { session.title = title }
            if type == "cost-state" {
                session.linesAdded = record["totalLinesAdded"] as? Int ?? session.linesAdded
                session.linesRemoved = record["totalLinesRemoved"] as? Int ?? session.linesRemoved
            }
            guard let time = date(record["timestamp"]) else { continue }
            times.append(time)
            if session.cwd == nil, let cwd = record["cwd"] as? String { session.cwd = cwd }
            let message = record["message"] as? [String: Any]

            if type == "user", record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true {
                if let text = message?["content"] as? String, let prompt = cleanPrompt(text) {
                    session.prompts += 1
                    if session.firstPrompt == nil { session.firstPrompt = prompt }
                } else if let parts = message?["content"] as? [[String: Any]],
                          !parts.contains(where: { $0["type"] as? String == "tool_result" }),
                          let text = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                          let prompt = cleanPrompt(text) {
                    session.prompts += 1
                    if session.firstPrompt == nil { session.firstPrompt = prompt }
                }
            }

            guard type == "assistant", let message else { continue }
            // Streamed replies repeat the same message (and usage) once per content block.
            if let messageID = message["id"] as? String, seenMessages.insert(messageID).inserted,
               let usage = message["usage"] as? [String: Any] {
                session.tokensIn += (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                session.tokensOut += usage["output_tokens"] as? Int ?? 0
                if let model = message["model"] as? String, let cost = APIPricing.claudeCost(model: model, usage: usage) {
                    let day = dayKey(time)
                    let sofar = session.claudeCostByDay[day] ?? [0, 0]
                    session.claudeCostByDay[day] = [sofar[0] + cost.input, sofar[1] + cost.output]
                }
            }
            for part in message["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "tool_use" {
                guard let toolID = part["id"] as? String, seenTools.insert(toolID).inserted else { continue }
                session.toolCalls += 1
                let name = part["name"] as? String ?? ""
                let input = part["input"] as? [String: Any] ?? [:]
                if name == "Bash", let command = input["command"] as? String {
                    session.commands += 1
                    if isTest(command) { session.tests += 1 }
                }
                if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name),
                   let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    session.files.insert(path)
                }
            }
        }
        accumulate(times, into: &session)
        return session
    }

    // swiftlint:disable:next force_try
    private static let execCommand = try! NSRegularExpression(pattern: #"exec_command\(\{\\?"cmd\\?":\\?"((?:[^"\\]|\\.)*)"#)

    static func parseCodex(_ data: Data, id: String) -> ActivitySession {
        var session = ActivitySession(id: id, agent: "codex")
        var times: [Date] = []
        var userEvents = 0
        var userMessages: [String] = []
        // Token totals are cumulative; each increase goes to the model in use at the time.
        var model = "unknown"
        var counted = [0, 0, 0]
        for line in lines(data) {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let time = date(record["timestamp"])
            if let time { times.append(time) }
            let payload = record["payload"] as? [String: Any] ?? [:]
            let type = record["type"] as? String
            let kind = payload["type"] as? String

            if type == "session_meta" {
                session.cwd = payload["cwd"] as? String ?? session.cwd
                if let id = payload["id"] as? String { session = ActivitySession(id: id, agent: "codex", cwd: session.cwd) }
            }
            if type == "session_meta", let provider = payload["model_provider"] as? String {
                session.codexProvider = provider
            }
            if type == "turn_context" {
                if session.cwd == nil { session.cwd = payload["cwd"] as? String }
                if let name = payload["model"] as? String, !name.isEmpty {
                    model = name
                    session.codexModel = name
                }
            }
            if type == "event_msg", kind == "user_message", let text = payload["message"] as? String, let prompt = cleanPrompt(text) {
                userEvents += 1
                if session.firstPrompt == nil { session.firstPrompt = prompt }
            }
            if type == "event_msg", kind == "token_count",
               let usage = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] {
                // Cumulative for the session; keep the latest.
                session.tokensIn = max(session.tokensIn, usage["input_tokens"] as? Int ?? 0)
                session.tokensOut = max(session.tokensOut, usage["output_tokens"] as? Int ?? 0)
                let total = [usage["input_tokens"] as? Int ?? 0, usage["cached_input_tokens"] as? Int ?? 0,
                             usage["output_tokens"] as? Int ?? 0]
                let delta = zip(total, counted).map { max(0, $0 - $1) }
                if delta.contains(where: { $0 > 0 }), let time {
                    let day = dayKey(time)
                    let sofar = session.codexTokens[day]?[model] ?? [0, 0, 0]
                    session.codexTokens[day, default: [:]][model] = zip(sofar, delta).map(+)
                }
                counted = zip(total, counted).map { max($0, $1) }
            }
            if type == "response_item", kind == "message", payload["role"] as? String == "user" {
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                if let prompt = cleanPrompt(text), !prompt.hasPrefix("# AGENTS.md") { userMessages.append(prompt) }
            }
            if type == "response_item", kind == "function_call" || kind == "custom_tool_call" || kind == "local_shell_call" {
                session.toolCalls += 1
                let name = payload["name"] as? String ?? ""
                let body = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
                if ["shell", "exec_command", "local_shell", "container.exec"].contains(name) || kind == "local_shell_call" {
                    session.commands += 1
                    if isTest(body) { session.tests += 1 }
                } else if name == "exec" {
                    // Code-mode: commands are calls inside the script.
                    let range = NSRange(body.startIndex..., in: body)
                    for match in execCommand.matches(in: body, range: range) {
                        session.commands += 1
                        if let r = Range(match.range(at: 1), in: body), isTest(String(body[r])) { session.tests += 1 }
                    }
                }
                countPatch(body, into: &session)
            }
        }
        session.prompts = userEvents > 0 ? userEvents : userMessages.count
        if session.firstPrompt == nil { session.firstPrompt = userMessages.first }
        accumulate(times, into: &session)
        return session
    }

    /// Files and lines changed by an apply_patch call (its text may be JSON-escaped).
    private static func countPatch(_ body: String, into session: inout ActivitySession) {
        guard body.contains("*** Begin Patch") else { return }
        let text = body.replacingOccurrences(of: "\\n", with: "\n")
        for line in text.split(separator: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                session.files.insert(String(line.dropFirst(marker.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"\\ ")))
            }
            if line.hasPrefix("+") && !line.hasPrefix("+++") { session.linesAdded += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { session.linesRemoved += 1 }
        }
    }
}
#endif
