import Foundation
import Testing
@testable import Ghostty

/// Transcripts made up for the tests, in a folder of their own, laid out the way Claude
/// Code and Codex lay theirs out.
private final class SearchFixture {
    let root: URL
    let roots: SessionSearchRoots
    let cache = SessionMetaCache(file: nil)

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("session-search-" + UUID().uuidString, isDirectory: true)
        roots = SessionSearchRoots(claude: root.appendingPathComponent("claude"), codex: root.appendingPathComponent("codex"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func day(_ daysAgo: Double) -> Date { Date(timeIntervalSinceNow: -daysAgo * 86_400) }

    @discardableResult
    func write(_ lines: [String], to url: URL, modified: Date) -> URL {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func claude(_ session: String, project: String = "-work-app", subagent: String? = nil, modified: Date = Date(), _ lines: [String]) -> URL {
        let folder = roots.claude!.appendingPathComponent(project)
        let url = subagent.map { folder.appendingPathComponent(session).appendingPathComponent("subagents").appendingPathComponent($0 + ".jsonl") }
            ?? folder.appendingPathComponent(session + ".jsonl")
        return write(lines, to: url, modified: modified)
    }

    @discardableResult
    func codex(_ name: String, modified: Date = Date(), _ lines: [String]) -> URL {
        write(lines, to: roots.codex!.appendingPathComponent("2026/01/02").appendingPathComponent(name + ".jsonl"), modified: modified)
    }

    func search(_ text: String, filters: SessionSearchFilters = SessionSearchFilters(), limit: Int = 200,
                limits: SessionSearchLimits = SessionSearchLimits()) -> (results: [SessionSearchResult], summary: SessionSearchSummary) {
        SessionSearchEngine.results(SessionSearchEngine.Request(query: SessionSearchQuery(text), filters: filters, limit: limit),
                                    roots: roots, cache: cache, limits: limits)
    }
}

/// Lines in the shapes the two agents write.
private enum Line {
    static func prompt(_ text: String, cwd: String = "/work/app") -> String {
        SearchFixture.json(["type": "user", "cwd": cwd, "timestamp": "2026-01-02T10:00:00.000Z",
                            "message": ["role": "user", "content": text]])
    }

    static func agent(_ text: String) -> String {
        SearchFixture.json(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    static func tool(_ name: String, _ input: [String: Any]) -> String {
        SearchFixture.json(["type": "assistant",
                            "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": name, "input": input]]]])
    }

    static func result(_ text: String) -> String {
        SearchFixture.json(["type": "user", "message": ["role": "user",
                                                        "content": [["type": "tool_result", "tool_use_id": "t1", "content": text]]]])
    }

    static func codexMeta(id: String, cwd: String = "/work/api", provider: String = "openai") -> String {
        SearchFixture.json(["type": "session_meta", "payload": ["id": id, "cwd": cwd, "model_provider": provider]])
    }

    static func codexTurn(model: String) -> String {
        SearchFixture.json(["type": "turn_context", "payload": ["cwd": "/work/api", "model": model]])
    }

    static func codexPrompt(_ text: String) -> String {
        SearchFixture.json(["type": "event_msg", "payload": ["type": "user_message", "message": text]])
    }

    static func codexMessage(_ role: String, _ text: String) -> String {
        SearchFixture.json(["type": "response_item",
                            "payload": ["type": "message", "role": role, "content": [["type": "text", "text": text]]]])
    }

    static func codexCall(_ name: String, arguments: [String: Any]) -> String {
        SearchFixture.json(["type": "response_item",
                            "payload": ["type": "function_call", "name": name, "call_id": "c1", "arguments": SearchFixture.json(arguments)]])
    }

    static func codexPatch(_ patch: String) -> String {
        SearchFixture.json(["type": "response_item",
                            "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2", "input": patch]])
    }

    static func codexOutput(_ text: String) -> String {
        SearchFixture.json(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": text]])
    }
}

struct SessionSearchTests {
    private let everything = Set(SearchLineKind.allCases)

    private func segments(_ line: String, agent: String, wanted: Set<SearchLineKind>? = nil) -> [SearchSegment] {
        Array(line.utf8).withUnsafeBufferPointer {
            SessionLineParser.segments(of: $0, agent: agent, wanted: wanted ?? everything)
        }
    }

    private func excerpt(_ text: String, _ query: String, lead: Int = SearchSnippets.lead,
                         length: Int = SearchSnippets.length) -> (text: String, lit: [String]) {
        let matcher = SearchMatcher(SessionSearchQuery(query))
        let made = Array(text.utf8).withUnsafeBufferPointer {
            SearchSnippets.excerpt(of: $0, terms: matcher.highlighted, fold: matcher.fold, lead: lead, length: length)
        }
        let snippet = SearchSnippet(id: 1, kind: .agent, text: made.text, highlights: made.highlights)
        return (made.text, snippet.pieces.filter(\.lit).map(\.text))
    }

    // MARK: The query

    @Test func wordsAreAllNeeded() {
        let query = SessionSearchQuery("  retry   backoff ")
        #expect(query.words == ["retry", "backoff"])
        #expect(query.excluded.isEmpty)
        #expect(!query.caseSensitive)
        #expect(!query.isEmpty)
    }

    @Test func phrasesExclusionsAndFiles() {
        let query = SessionSearchQuery(#""exactly once" -flaky file:queue.swift -"two words" -file:"old dir/x.swift" plain"#)
        #expect(query.words == ["exactly once", "plain"])
        #expect(query.excluded == ["flaky", "two words"])
        #expect(query.files == ["queue.swift"])
        #expect(query.excludedFiles == ["old dir/x.swift"])
    }

    @Test func aCapitalLetterMakesItExact() {
        #expect(!SessionSearchQuery("retry file:queue.swift").caseSensitive)
        #expect(SessionSearchQuery("Retry").caseSensitive)
        #expect(SessionSearchQuery("retry file:Queue.swift").caseSensitive)
        #expect(SessionSearchQuery("retry -Flaky").caseSensitive)
    }

    @Test func oddQueries() {
        #expect(SessionSearchQuery("").isEmpty)
        #expect(SessionSearchQuery("   ").isEmpty)
        // Leaving things out isn't a search by itself.
        #expect(SessionSearchQuery("-flaky").isEmpty)
        #expect(SessionSearchQuery("-").words == ["-"])
        #expect(SessionSearchQuery("a - b").words == ["a", "-", "b"])
        #expect(SessionSearchQuery(#""never closed"#).words == ["never closed"])
        #expect(SessionSearchQuery(#""" file: x"#).words == ["x"])
        #expect(SessionSearchQuery("a\u{7}b\u{202E}c").words == ["abc"])
        #expect(SessionSearchQuery(String(repeating: "x", count: 500)).words[0].count == SessionSearchQuery.termLimit)
        #expect(SessionSearchQuery((0..<40).map { "w\($0)" }.joined(separator: " ")).words.count == SessionSearchQuery.termCount)
    }

    // MARK: Skimming bytes

    @Test func findingBytes() {
        let hay = Array("Deploy the Retry queue; RETRY twice. naïve Über".utf8)
        hay.withUnsafeBufferPointer { bytes in
            let folded = SearchBytes.needle("retry", fold: true)
            #expect(SearchBytes.find(folded, in: bytes, from: 0, to: bytes.count, fold: true) == 11)
            #expect(SearchBytes.ranges(of: folded, in: bytes, from: 0, to: bytes.count, fold: true).map(\.lowerBound) == [11, 24])
            #expect(SearchBytes.find(Array("retry".utf8), in: bytes, from: 0, to: bytes.count, fold: false) == nil)
            #expect(SearchBytes.find(Array("RETRY".utf8), in: bytes, from: 0, to: bytes.count, fold: false) == 24)
            // Only ASCII letters fold.
            #expect(SearchBytes.contains(SearchBytes.needle("naïve", fold: true), in: bytes, fold: true))
            #expect(!SearchBytes.contains(SearchBytes.needle("über", fold: true), in: bytes, fold: true))
            // Never past the end it was given.
            #expect(SearchBytes.find(folded, in: bytes, from: 12, to: 28, fold: true) == nil)
            #expect(SearchBytes.find(folded, in: bytes, from: 12, to: 29, fold: true) == 24)
            #expect(SearchBytes.find([], in: bytes, from: 0, to: bytes.count, fold: true) == nil)
        }
    }

    @Test func theSkimOnlyLooksForWhatJSONLeavesAlone() {
        let matcher = SearchMatcher(SessionSearchQuery(#"say"hello file:src/a.swift back\slash -gone"#))
        // Longest first; a quote or a backslash is written differently on disk, so the
        // longest stretch without one stands in for the term. Exclusions can't rule a line out.
        #expect(matcher.prefilter.map { String(decoding: $0, as: UTF8.self) } == ["src/a.swift", "hello", "slash"])
        let line = Line.tool("Edit", ["file_path": "/work/app/src/a.swift", "old_string": "x", "new_string": #"say"hello back\slash"#])
        Array(line.utf8).withUnsafeBufferPointer { #expect(matcher.mayMatch($0)) }
        Array(Line.agent("hello slash").utf8).withUnsafeBufferPointer { #expect(!matcher.mayMatch($0)) }
        #expect(SearchMatcher(SessionSearchQuery(#"""#)).prefilter.isEmpty)
    }

    // MARK: Lines

    @Test func claudeLines() {
        #expect(segments(Line.prompt("Fix the retry queue"), agent: "claude") == [SearchSegment(kind: .prompt, text: "Fix the retry queue")])
        #expect(segments(Line.prompt("<system-reminder>retry</system-reminder>"), agent: "claude").map(\.kind) == [.output])
        #expect(segments(Line.agent("I'll use backoff"), agent: "claude") == [SearchSegment(kind: .agent, text: "I'll use backoff")])
        #expect(segments(Line.tool("Bash", ["command": "swift test --filter Retry"]), agent: "claude")
                == [SearchSegment(kind: .command, text: "swift test --filter Retry")])
        let edit = segments(Line.tool("Edit", ["file_path": "/work/app/Queue.swift", "old_string": "once", "new_string": "twice"]), agent: "claude")
        #expect(edit == [SearchSegment(kind: .edit, text: "/work/app/Queue.swift", paths: ["/work/app/Queue.swift"]),
                         SearchSegment(kind: .output, text: "twice\nonce", paths: ["/work/app/Queue.swift"])])
        let read = segments(Line.tool("Read", ["file_path": "/work/app/Queue.swift"]), agent: "claude")
        #expect(read == [SearchSegment(kind: .output, text: "Read /work/app/Queue.swift", paths: ["/work/app/Queue.swift"])])
        #expect(segments(Line.result("3 tests passed"), agent: "claude") == [SearchSegment(kind: .output, text: "3 tests passed")])

        let thinking = SearchFixture.json(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "Backoff is safer"]]]])
        #expect(segments(thinking, agent: "claude") == [SearchSegment(kind: .agent, text: "Backoff is safer")])
        // What a sub-agent is told comes from the agent that started it.
        let side = SearchFixture.json(["type": "user", "isSidechain": true, "message": ["role": "user", "content": "Look for retries"]])
        #expect(segments(side, agent: "claude").map(\.kind) == [.agent])
        let meta = SearchFixture.json(["type": "user", "isMeta": true, "message": ["role": "user", "content": "A note"]])
        #expect(segments(meta, agent: "claude").map(\.kind) == [.output])
    }

    @Test func codexLines() {
        #expect(segments(Line.codexPrompt("Add a health check"), agent: "codex") == [SearchSegment(kind: .prompt, text: "Add a health check")])
        #expect(segments(Line.codexMessage("user", "Add a health check"), agent: "codex").map(\.kind) == [.prompt])
        #expect(segments(Line.codexMessage("user", "<environment_context>x</environment_context>"), agent: "codex").map(\.kind) == [.output])
        #expect(segments(Line.codexMessage("user", "# AGENTS.md instructions"), agent: "codex").map(\.kind) == [.output])
        #expect(segments(Line.codexMessage("assistant", "Done: /health returns 200"), agent: "codex")
                == [SearchSegment(kind: .agent, text: "Done: /health returns 200")])
        #expect(segments(Line.codexMessage("developer", "Be brief"), agent: "codex").map(\.kind) == [.output])

        #expect(segments(Line.codexCall("exec_command", arguments: ["cmd": "cargo test health"]), agent: "codex")
                == [SearchSegment(kind: .command, text: "cargo test health")])
        #expect(segments(Line.codexCall("shell", arguments: ["command": ["bash", "-lc", "git status --short"]]), agent: "codex")
                == [SearchSegment(kind: .command, text: "git status --short")])
        #expect(segments(Line.codexCall("shell", arguments: ["command": ["ls", "-la"]]), agent: "codex")
                == [SearchSegment(kind: .command, text: "ls -la")])
        let local = SearchFixture.json(["type": "response_item",
                                        "payload": ["type": "local_shell_call", "action": ["command": ["zsh", "-c", "make lint"]]]])
        #expect(segments(local, agent: "codex") == [SearchSegment(kind: .command, text: "make lint")])

        let patch = "*** Begin Patch\n*** Update File: src/health.rs\n@@\n-old\n+new\n*** Add File: src/probe.rs\n+fn probe() {}\n*** End Patch"
        let patched = segments(Line.codexPatch(patch), agent: "codex")
        #expect(patched == [SearchSegment(kind: .edit, text: "src/health.rs", paths: ["src/health.rs"]),
                            SearchSegment(kind: .edit, text: "src/probe.rs", paths: ["src/probe.rs"]),
                            SearchSegment(kind: .output, text: patch, paths: ["src/health.rs", "src/probe.rs"])])
        #expect(segments(Line.codexCall("apply_patch", arguments: ["input": patch]), agent: "codex") == patched)

        #expect(segments(Line.codexOutput("test result: ok"), agent: "codex") == [SearchSegment(kind: .output, text: "test result: ok")])
        #expect(segments(Line.codexCall("update_plan", arguments: ["plan": "ship"]), agent: "codex").map(\.kind) == [.output])
        let reasoning = SearchFixture.json(["type": "response_item",
                                            "payload": ["type": "reasoning", "summary": [["type": "summary_text", "text": "Probe first"]]]])
        #expect(segments(reasoning, agent: "codex") == [SearchSegment(kind: .agent, text: "Probe first")])
    }

    @Test func unknownShapesAreToolOutputAsTheyAre() {
        let unknown = SearchFixture.json(["type": "queue-operation", "content": "retry later"])
        #expect(segments(unknown, agent: "claude") == [SearchSegment(kind: .output, text: unknown)])
        #expect(segments("not json at all: retry", agent: "codex") == [SearchSegment(kind: .output, text: "not json at all: retry")])
        #expect(segments(SearchFixture.json(["type": "token_usage_record", "payload": ["n": 1]]), agent: "codex").map(\.kind) == [.output])
        // Not unless tool output is searched.
        #expect(segments(unknown, agent: "claude", wanted: SearchLineKind.standard).isEmpty)
        #expect(segments(Line.result("3 tests passed"), agent: "claude", wanted: SearchLineKind.standard).isEmpty)
        #expect(!SearchLineKind.standard.contains(.output))
    }

    // MARK: Snippets

    @Test func aSnippetMarksEveryTerm() {
        let made = excerpt("We retry with Backoff, then retry again.", "retry backoff")
        #expect(made.text == "We retry with Backoff, then retry again.")
        #expect(made.lit == ["retry", "Backoff", "retry"])
        // Exact when the search has a capital.
        #expect(excerpt("backoff or Backoff", "Backoff").lit == ["Backoff"])
        // Terms that touch are one mark.
        #expect(excerpt("a retryqueue b", "retry queue").lit == ["retryqueue"])
        // Nothing to mark: the start of the text.
        #expect(excerpt("only a path matched", "file:x.swift").lit.isEmpty)
    }

    @Test func aSnippetOfALongLineIsCutAroundTheMatch() {
        let long = String(repeating: "lorem ipsum ", count: 400) + "the needle here " + String(repeating: "dolor sit ", count: 400)
        let made = excerpt(long, "needle")
        #expect(made.text.hasPrefix("…") && made.text.hasSuffix("…"))
        #expect(made.text.utf8.count <= SearchSnippets.length + 6)
        #expect(made.lit == ["needle"])

        let atStart = excerpt("needle " + String(repeating: "x ", count: 400), "needle")
        #expect(atStart.text.hasPrefix("needle") && atStart.text.hasSuffix("…"))
        #expect(atStart.lit == ["needle"])

        let atEnd = excerpt(String(repeating: "x ", count: 400) + "needle", "needle")
        #expect(atEnd.text.hasPrefix("…") && atEnd.text.hasSuffix("needle"))
        #expect(atEnd.lit == ["needle"])

        // A term the cut runs through is marked as far as it shows.
        #expect(excerpt("abc needle", "needle", lead: 4, length: 7).lit == ["nee"])
    }

    @Test func aSnippetNeverSplitsACharacter() {
        let text = String(repeating: "日本語のテキスト。", count: 40) + "検索 naïve 🧑‍🚀 café" + String(repeating: "éàü😀", count: 60)
        for lead in 0..<12 {
            for length in [1, 2, 3, 5, 17, 64] {
                let made = excerpt(text, "naïve", lead: lead, length: length)
                #expect(!made.text.unicodeScalars.contains("\u{FFFD}"))
                for word in made.lit { #expect("naïve".hasPrefix(word)) }
            }
        }
        #expect(excerpt(text, "検索").lit == ["検索"])
        #expect(excerpt(text, "café").lit == ["café"])
        // Offsets are in UTF-16, past characters that take two units.
        let made = excerpt("😀😀 retry 😀", "retry")
        #expect(made.text == "😀😀 retry 😀")
        #expect(made.lit == ["retry"])
    }

    @Test func aSnippetIsPlainText() {
        let made = excerpt("line one\n\tline\u{0}two\u{1B}[31m retry\r\n\u{202E}evil\u{2028}next\u{7F}", "retry")
        #expect(made.text == "line one line two [31m retry evil next ")
        #expect(made.lit == ["retry"])
        #expect(!made.text.unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(SearchSnippets.clean("  a\n\nb\u{1B}c\u{202E}d  ", limit: 100) == "a b cd")
        #expect(SearchSnippets.clean(String(repeating: "x", count: 50), limit: 10) == String(repeating: "x", count: 10) + "…")
    }

    // MARK: Searching

    @Test func findsInBothAgentsNewestFirst() {
        let fixture = SearchFixture()
        fixture.claude("11111111-1111-4111-8111-111111111111", modified: SearchFixture.day(3), [
            Line.prompt("Fix the retry queue"), Line.agent("I'll add backoff to the retry loop"),
            Line.tool("Bash", ["command": "swift test --filter Retry"]),
        ])
        fixture.codex("rollout-a", modified: SearchFixture.day(1), [
            Line.codexMeta(id: "22222222-2222-4222-8222-222222222222"), Line.codexTurn(model: "model-a"),
            Line.codexPrompt("Why does retry fail?"), Line.codexMessage("assistant", "The retry budget is zero"),
        ])
        fixture.claude("33333333-3333-4333-8333-333333333333", modified: SearchFixture.day(2), [
            Line.prompt("Rename the module"), Line.agent("Nothing about that word here"),
        ])
        fixture.claude("44444444-4444-4444-8444-444444444444", project: "-work-site", modified: SearchFixture.day(0.5), [
            Line.prompt("Retry the deploy", cwd: "/work/site"),
        ])

        let found = fixture.search("retry")
        #expect(found.results.map(\.meta.session) == ["44444444-4444-4444-8444-444444444444", "22222222-2222-4222-8222-222222222222",
                                                      "11111111-1111-4111-8111-111111111111"])
        #expect(found.results.map(\.meta.agent) == ["claude", "codex", "claude"])
        #expect(found.results.map(\.meta.title) == ["Retry the deploy", "Why does retry fail?", "Fix the retry queue"])
        #expect(found.results.map(\.meta.cwd) == ["/work/site", "/work/api", "/work/app"])
        #expect(found.results[1].meta.codexProvider == "openai" && found.results[1].meta.codexModel == "model-a")
        #expect(found.results[2].snippets.map(\.kind) == [.prompt, .agent, .command])
        #expect(found.results[2].matches == 3)
        #expect(found.summary == SessionSearchSummary(sessions: 4, results: 3, matches: 6))
        #expect(found.results.allSatisfy { $0.modified >= SearchFixture.day(4) })

        // Words must be on the same line; a capital makes it exact.
        #expect(fixture.search("retry backoff").results.map(\.matches) == [1])
        #expect(fixture.search("retry -backoff -deploy").summary.matches == 4)
        #expect(fixture.search("Retry").summary.matches == 2)
        #expect(fixture.search(#""retry queue""#).summary.matches == 1)
        #expect(fixture.search("nowhere").results.isEmpty)
        #expect(fixture.search("").summary == SessionSearchSummary())
    }

    @Test func filtersByAgentProjectAndTime() {
        let fixture = SearchFixture()
        fixture.claude("11111111-1111-4111-8111-111111111111", modified: SearchFixture.day(1), [Line.prompt("needle one", cwd: "/work/app")])
        fixture.claude("22222222-2222-4222-8222-222222222222", project: "-work-app-tools", modified: SearchFixture.day(10),
                       [Line.prompt("needle two", cwd: "/work/app/tools")])
        fixture.claude("33333333-3333-4333-8333-333333333333", project: "-work-application", modified: SearchFixture.day(40),
                       [Line.prompt("needle three", cwd: "/work/application")])
        fixture.codex("rollout-b", modified: SearchFixture.day(2), [Line.codexMeta(id: "44444444-4444-4444-8444-444444444444", cwd: "/work/api"),
                                                                    Line.codexPrompt("needle four")])

        #expect(fixture.search("needle").results.count == 4)
        #expect(fixture.search("needle", filters: SessionSearchFilters(agent: "codex")).results.map(\.meta.title) == ["needle four"])
        #expect(fixture.search("needle", filters: SessionSearchFilters(agent: "claude")).results.count == 3)
        // A project is its folder and what's under it, not a folder that starts the same.
        let inApp = fixture.search("needle", filters: SessionSearchFilters(project: "/work/app/"))
        #expect(inApp.results.map(\.meta.title) == ["needle one", "needle two"])
        #expect(inApp.summary.sessions == 2)
        let week = fixture.search("needle", filters: SessionSearchFilters(since: SearchFixture.day(7)))
        #expect(week.results.map(\.meta.title) == ["needle one", "needle four"])
        #expect(week.summary.sessions == 2)
        #expect(fixture.search("needle", filters: SessionSearchFilters(since: SearchFixture.day(30))).results.count == 3)
        #expect(fixture.search("needle", filters: SessionSearchFilters(agent: "codex", project: "/work/app")).results.isEmpty)
        #expect(SessionSearchFilters(project: "/").includes(folder: "/work"))
        #expect(!SessionSearchFilters(project: "/work").includes(folder: nil))
    }

    @Test func searchesOnlyWhatIsAskedFor() {
        let fixture = SearchFixture()
        fixture.claude("11111111-1111-4111-8111-111111111111", [
            Line.prompt("needle in a prompt"), Line.agent("needle in a message"), Line.tool("Bash", ["command": "grep needle ."]),
            Line.tool("Write", ["file_path": "/work/app/needle.txt", "content": "needle inside the file"]),
            Line.result("needle in output"), SearchFixture.json(["type": "queue-operation", "content": "needle queued"]),
        ])
        let standard = fixture.search("needle").results[0]
        #expect(standard.snippets.map(\.kind) == [.prompt, .agent, .command, .edit])
        let everything = fixture.search("needle", filters: SessionSearchFilters(kinds: Set(SearchLineKind.allCases))).results[0]
        #expect(everything.snippets.map(\.kind) == [.prompt, .agent, .command, .edit, .output, .output, .output])
        #expect(fixture.search("needle", filters: SessionSearchFilters(kinds: [.command])).results[0].snippets.map(\.text) == ["grep needle ."])
        #expect(fixture.search("needle", filters: SessionSearchFilters(kinds: [])).results.isEmpty)
        #expect(standard.snippets[3].text == "/work/app/needle.txt")
        #expect(standard.snippets[3].pieces.filter(\.lit).map(\.text) == ["needle"])
    }

    @Test func fileKeepsToLinesAboutAPath() {
        let fixture = SearchFixture()
        fixture.claude("11111111-1111-4111-8111-111111111111", [
            Line.prompt("Please look at Queue.swift"),
            Line.tool("Edit", ["file_path": "/work/app/Sources/Queue.swift", "old_string": "a", "new_string": "retry"]),
            Line.tool("Edit", ["file_path": "/work/app/Sources/Other.swift", "old_string": "a", "new_string": "retry"]),
            Line.tool("Bash", ["command": "swiftlint lint Sources/Queue.swift"]),
            Line.tool("Read", ["file_path": "/work/app/Sources/Queue.swift"]),
        ])
        fixture.codex("rollout-c", [
            Line.codexMeta(id: "22222222-2222-4222-8222-222222222222"),
            Line.codexPatch("*** Begin Patch\n*** Update File: Sources/Queue.swift\n+retry\n*** End Patch"),
        ])
        let found = fixture.search("file:queue.swift")
        #expect(Set(found.results.map(\.meta.agent)) == ["claude", "codex"])
        let claude = found.results.first { $0.meta.agent == "claude" }
        // The edit and the command; the prompt only mentions it, and reading is tool output.
        #expect(claude?.snippets.map(\.kind) == [.edit, .command])
        #expect(claude?.snippets[0].pieces.filter(\.lit).map(\.text) == ["Queue.swift"])
        let all = SessionSearchFilters(kinds: Set(SearchLineKind.allCases))
        #expect(fixture.search("file:queue.swift", filters: all).results.first { $0.meta.agent == "claude" }?.matches == 4)
        #expect(fixture.search("retry file:queue.swift", filters: all).summary.matches == 2)
        #expect(fixture.search("file:.swift -file:other").results.first { $0.meta.agent == "claude" }?.matches == 2)
        #expect(fixture.search("file:Queue.swift").summary.matches == 3)
        #expect(fixture.search("file:QUEUE.swift").results.isEmpty)
    }

    @Test func whatIsRecordedTwiceCountsOnce() {
        let fixture = SearchFixture()
        fixture.codex("rollout-d", [
            Line.codexMeta(id: "22222222-2222-4222-8222-222222222222"),
            Line.codexPrompt("needle please"), Line.codexMessage("user", "needle please\n"),
            Line.codexMessage("assistant", "needle found"),
            SearchFixture.json(["type": "event_msg", "payload": ["type": "agent_message", "message": "needle found"]]),
        ])
        let found = fixture.search("needle")
        #expect(found.results[0].matches == 2)
        #expect(found.results[0].snippets.map(\.kind) == [.prompt, .agent])
    }

    @Test func subAgentsBelongToTheirSession() {
        let fixture = SearchFixture()
        let id = "11111111-1111-4111-8111-111111111111"
        let main = fixture.claude(id, modified: SearchFixture.day(5), [Line.prompt("Audit the retries")])
        fixture.claude(id, subagent: "agent-a", modified: SearchFixture.day(1), [Line.agent("The needle is in Queue.swift")])
        fixture.claude(id, subagent: "workflows/wf-1/agent-b", modified: SearchFixture.day(3), [Line.agent("A second needle")])
        let found = fixture.search("needle", filters: SessionSearchFilters(since: SearchFixture.day(2)))
        #expect(found.results.count == 1)
        #expect(found.results[0].matches == 2)
        #expect(found.results[0].meta.title == "Audit the retries")
        #expect(found.results[0].transcript.resolvingSymlinksInPath().path == main.resolvingSymlinksInPath().path)
        #expect(found.summary.sessions == 1)
        // The same id in another project is another session.
        fixture.claude(id, project: "-work-site", [Line.prompt("needle elsewhere", cwd: "/work/site")])
        #expect(fixture.search("needle").results.count == 2)
    }

    @Test func stopsAtTheMostResultsAskedFor() {
        let fixture = SearchFixture()
        for index in 0..<12 {
            fixture.claude(String(format: "00000000-0000-4000-8000-%012d", index), modified: SearchFixture.day(Double(index)),
                           [Line.prompt("needle \(index)")])
        }
        let page = fixture.search("needle", limit: 5)
        #expect(page.results.map(\.meta.title) == (0..<5).map { "needle \($0)" })
        #expect(page.summary.capped)
        #expect(page.summary.results == 5)
        let all = fixture.search("needle", limit: 50)
        #expect(all.results.map(\.meta.title) == (0..<12).map { "needle \($0)" })
        #expect(!all.summary.capped)
    }

    @Test func aSessionKeepsAFewSnippetsAndStopsCounting() {
        let fixture = SearchFixture()
        fixture.claude("11111111-1111-4111-8111-111111111111", (0..<60).map { Line.agent("needle number \($0)") })
        var limits = SessionSearchLimits()
        limits.snippetsPerSession = 4
        limits.matchesPerSession = 25
        let result = fixture.search("needle", limits: limits).results[0]
        #expect(result.snippets.map(\.text) == (0..<4).map { "needle number \($0)" })
        #expect(result.matches == 25)
        #expect(result.more)
        #expect(!fixture.search("needle").results[0].more)
    }

    @Test func aLargeFileIsReadOnlyAtItsEnd() {
        let fixture = SearchFixture()
        let filler = (0..<200).map { Line.agent("filler line \($0) " + String(repeating: "pad ", count: 20)) }
        let url = fixture.claude("11111111-1111-4111-8111-111111111111",
                                 [Line.prompt("needle early")] + filler + [Line.agent("needle late")])
        var limits = SessionSearchLimits()
        limits.bytesPerFile = 4096
        let matcher = SearchMatcher(SessionSearchQuery("needle"))
        var texts: [String] = []
        let outcome = SessionFileScanner.scan(url, agent: "claude", matcher: matcher, kinds: SearchLineKind.standard, limits: limits,
                                              isCancelled: { false }, onMatch: { _, text in
            texts.append(String(decoding: text, as: UTF8.self))
            return true
        })
        #expect(outcome.cut)
        #expect(outcome.bytes <= 4096)
        #expect(texts == ["needle late"])

        let cut = fixture.search("needle", limits: limits)
        #expect(cut.summary.cutFiles == 1)
        #expect(cut.results[0].snippets.map(\.text) == ["needle late"])
        // Its title still comes from its first prompt.
        #expect(cut.results[0].meta.title == "needle early")
        let whole = fixture.search("needle")
        #expect(whole.summary.cutFiles == 0)
        #expect(whole.results[0].matches == 2)
    }

    @Test func skimsInBlocksWithoutLosingLines() {
        let fixture = SearchFixture()
        let lines = (0..<300).map { $0 % 7 == 0 ? Line.agent("needle \($0)") : Line.agent("nothing \($0) " + String(repeating: "z", count: $0)) }
        let url = fixture.claude("11111111-1111-4111-8111-111111111111", lines)
        for block in [1, 64, 1000, 1 << 20] {
            var limits = SessionSearchLimits()
            limits.block = block
            var count = 0
            let outcome = SessionFileScanner.scan(url, agent: "claude", matcher: SearchMatcher(SessionSearchQuery("needle")),
                                                  kinds: SearchLineKind.standard, limits: limits, isCancelled: { false }, onMatch: { _, _ in
                count += 1
                return true
            })
            #expect(count == 43)
            // Only lines with the word are decoded.
            #expect(outcome.decoded == 43)
        }
    }

    @Test func aCancelStopsALargeFilePromptly() {
        let fixture = SearchFixture()
        let url = fixture.claude("11111111-1111-4111-8111-111111111111", (0..<20_000).map { Line.agent("needle \($0)") })
        var polls = 0
        var matches = 0
        let outcome = SessionFileScanner.scan(url, agent: "claude", matcher: SearchMatcher(SessionSearchQuery("needle")),
                                              kinds: SearchLineKind.standard, isCancelled: {
            polls += 1
            return polls > 40
        }, onMatch: { _, _ in
            matches += 1
            return true
        })
        #expect(outcome.cancelled)
        #expect(outcome.decoded < 40 && matches == outcome.decoded)

        // Nothing matching at all: still asked once per block.
        var limits = SessionSearchLimits()
        limits.block = 4096
        polls = 0
        let skimmed = SessionFileScanner.scan(url, agent: "claude", matcher: SearchMatcher(SessionSearchQuery("absent")),
                                              kinds: SearchLineKind.standard, limits: limits, isCancelled: {
            polls += 1
            return polls > 3
        }, onMatch: { _, _ in true })
        #expect(skimmed.cancelled && skimmed.decoded == 0)

        let token = SessionSearchToken()
        token.cancel()
        let found = SessionSearchEngine.results(SessionSearchEngine.Request(query: SessionSearchQuery("needle")),
                                                roots: fixture.roots, cache: fixture.cache, token: token)
        #expect(found.results.isEmpty)
        #expect(found.summary.cancelled)
    }

    // MARK: What's remembered about a session

    @Test func theCacheIsRedoneWhenAFileChanges() {
        let fixture = SearchFixture()
        let store = fixture.root.appendingPathComponent("cache.json")
        var reads = 0
        let counting: (SessionFileInfo) -> SessionSearchMeta = {
            reads += 1
            return SessionSearchMeta.read($0)
        }
        let cache = SessionMetaCache(file: store, read: counting)
        let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        let url = fixture.claude("11111111-1111-4111-8111-111111111111", modified: stamp, [Line.prompt("first title")])
        func info() -> SessionFileInfo { fixture.roots.sessions()[0].main }

        #expect(cache.meta(for: info()).title == "first title")
        #expect(cache.meta(for: info()).title == "first title")
        #expect(reads == 1)

        // Same size, later date.
        fixture.write([Line.prompt("other title")], to: url, modified: stamp.addingTimeInterval(5))
        #expect(cache.meta(for: info()).title == "other title")
        #expect(reads == 2)
        // Same date, another size.
        fixture.write([Line.prompt("a longer title")], to: url, modified: stamp.addingTimeInterval(5))
        #expect(cache.meta(for: info()).title == "a longer title")
        #expect(reads == 3)

        // Kept between launches, and nothing is written when nothing changed.
        let save = cache.pendingSave()
        #expect(save?.file == store)
        try? save?.data.write(to: store)
        #expect(cache.pendingSave() == nil)
        let reopened = SessionMetaCache(file: store, read: counting)
        #expect(reopened.meta(for: info()).title == "a longer title")
        #expect(reads == 3)
        #expect(SessionMetaCache(file: nil).pendingSave() == nil)
    }

    @Test func theCacheForgetsTheOldestPastItsLimit() {
        let fixture = SearchFixture()
        let store = fixture.root.appendingPathComponent("cache.json")
        for index in 0..<8 {
            fixture.claude(String(format: "00000000-0000-4000-8000-%012d", index), modified: SearchFixture.day(Double(index)),
                           [Line.prompt("title \(index)")])
        }
        let cache = SessionMetaCache(file: store, limit: 3)
        #expect(SessionSearchEngine.folders(roots: fixture.roots, cache: cache) == ["/work/app"])
        #expect(cache.count == 8)
        let save = cache.pendingSave()
        try? save?.data.write(to: store)
        #expect(cache.count == 3)
        var reads = 0
        let reopened = SessionMetaCache(file: store, limit: 3) {
            reads += 1
            return SessionSearchMeta.read($0)
        }
        for session in fixture.roots.sessions().prefix(3) { _ = reopened.meta(for: session.main) }
        #expect(reads == 0)
    }

    @Test func readsWhatAResumeNeeds() {
        let fixture = SearchFixture()
        let big = (0..<4000).map { Line.codexMessage("assistant", "padding \($0) " + String(repeating: "p", count: 700)) }
        fixture.codex("rollout-e", [
            Line.codexMeta(id: "22222222-2222-4222-8222-222222222222", cwd: "/work/api", provider: "ollama"),
            Line.codexMessage("user", "<environment_context>ignored</environment_context>"),
            Line.codexTurn(model: "first-model"), Line.codexPrompt("  Ship\nthe \u{1B}probe  "),
        ] + big + [Line.codexTurn(model: "latest-model"), Line.codexMessage("assistant", "done")])
        let meta = SessionSearchMeta.read(fixture.roots.sessions()[0].main)
        #expect(meta == SessionSearchMeta(agent: "codex", session: "22222222-2222-4222-8222-222222222222", cwd: "/work/api",
                                          title: "Ship the probe", codexProvider: "ollama", codexModel: "latest-model"))

        fixture.claude("11111111-1111-4111-8111-111111111111", project: "-work-site", modified: SearchFixture.day(1), [
            SearchFixture.json(["type": "mode", "mode": "default"]),
            Line.prompt("<command-name>/clear</command-name>", cwd: "/work/site"), Line.result("ignored"),
            Line.prompt(String(repeating: "long ", count: 100), cwd: "/work/site"),
        ])
        let claude = SessionSearchMeta.read(fixture.roots.sessions()[1].main)
        #expect(claude.session == "11111111-1111-4111-8111-111111111111" && claude.cwd == "/work/site")
        #expect(claude.title?.hasPrefix("long long") == true && claude.title?.count == 201)
        // A file that's gone still has a name.
        let gone = SessionFileInfo(url: fixture.root.appendingPathComponent("gone.jsonl"), agent: "claude", session: "x",
                                   subagent: false, modified: Date(), size: 0)
        #expect(SessionSearchMeta.read(gone) == SessionSearchMeta(agent: "claude", session: "x"))
    }
}
