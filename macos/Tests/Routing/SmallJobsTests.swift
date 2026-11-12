import Foundation
import Testing
@testable import Ghostty

/// A stand-in for Ollama and LM Studio: answers the model lists, and `chat` answers a job.
private final class Servers: @unchecked Sendable {
    typealias Chat = @Sendable (URLRequest) async throws -> (status: Int, body: String)

    private let lock = NSLock()
    private var seen: [URLRequest] = []
    private let tags: String
    private let running: String
    private let studio: String?
    private let chat: Chat

    init(tags: String = #"{"models":[{"name":"mid:4b","size":2500000000,"details":{"context_length":32768},"capabilities":["completion"]}]}"#,
         running: String = #"{"models":[{"name":"mid:4b","context_length":8192}]}"#,
         studio: String? = nil, chat: @escaping Chat) {
        self.tags = tags
        self.running = running
        self.studio = studio
        self.chat = chat
    }

    var requests: [URLRequest] { lock.withLock { seen } }
    /// The requests that asked a model for an answer.
    var asked: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }

    var client: SmallJobClient {
        SmallJobClient(transport: { [self] request in
            lock.withLock { seen.append(request) }
            let url = request.url ?? URL(fileURLWithPath: "/")
            var status = 200, body = ""
            switch url.path {
            case "/api/tags": body = tags
            case "/api/ps": body = running
            case "/api/v0/models":
                guard let studio else { throw URLError(.cannotConnectToHost) }
                body = studio
            default: (status, body) = try await chat(request)
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) ?? HTTPURLResponse())
        }, ollamaBase: URL(string: "http://127.0.0.1:11434")!, lmStudioBase: URL(string: "http://127.0.0.1:1234")!, configuredHosts: [])
    }

    static func ollama(_ text: String, stop: String = "stop") -> String {
        let reply: [String: Any] = ["model": "mid:4b", "message": ["role": "assistant", "content": text], "done": true, "done_reason": stop]
        return String(data: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(), encoding: .utf8) ?? ""
    }
}

/// What the router wrote down, and how often the job's own path ran.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SmallJobOutcome] = []
    private var count = 0

    var outcomes: [SmallJobOutcome] { lock.withLock { recorded } }
    var fallbacks: Int { lock.withLock { count } }
    func record(_ outcome: SmallJobOutcome) { lock.withLock { recorded.append(outcome) } }
    func fellBack() { lock.withLock { count += 1 } }
}

/// Where a small job runs: on this Mac when a model can take it and answers well, and on to
/// its own path when it's off, too slow, failing or wrong.
struct SmallJobsTests {
    private func jobs(_ servers: Servers, _ seen: Seen, on: Bool = true, chosen: String? = nil,
                      limits: SmallJobs.Limits = .init()) -> SmallJobs {
        SmallJobs(client: servers.client, isOn: { on }, chosen: { chosen }, limits: limits, record: { seen.record($0) })
    }

    private func job(_ seen: Seen, prompt: String = "Diff:\n+let retries = 3\n", answer: Result<String, Error> = .success("From the agent")) -> SmallJob {
        SmallJob(kind: .commitMessage, instructions: "Write a git commit message for the changes below.", prompt: prompt,
                 fallbackName: "Claude Code", fallback: { done in
            seen.fellBack()
            done(answer)
        })
    }

    private func text(_ result: Result<String, Error>) -> String? { try? result.get() }

    @Test func aGoodAnswerFromThisMacIsUsedAndNothingIsSentOn() async {
        let seen = Seen()
        let servers = Servers { _ in (200, Servers.ollama("Here is the commit message:\n\nAdd three login retries")) }
        let (result, outcome) = await jobs(servers, seen).run(job(seen))
        #expect(text(result) == "Add three login retries")
        #expect(outcome.route == .local(model: "mid:4b"))
        #expect(outcome.isLocal && outcome.reason == nil)
        #expect(seen.fallbacks == 0)
        #expect(seen.outcomes == [outcome])
        #expect(servers.asked.map { $0.url?.absoluteString } == ["http://127.0.0.1:11434/api/chat"])
    }

    @Test func offMeansItsOwnPathAndNothingElse() async {
        let seen = Seen()
        let servers = Servers { _ in (200, Servers.ollama("Add three login retries")) }
        let (result, outcome) = await jobs(servers, seen, on: false).run(job(seen))
        #expect(text(result) == "From the agent")
        #expect(outcome.route == .fallbackOnly)
        #expect(seen.fallbacks == 1)
        // No server is asked anything, and nothing is logged.
        #expect(servers.requests.isEmpty)
        #expect(seen.outcomes.isEmpty)
    }

    @Test func aModelThatTakesTooLongIsGivenUpOn() async {
        let seen = Seen()
        let servers = Servers { _ in
            try await Task.sleep(nanoseconds: 300_000_000_000)
            return (200, Servers.ollama("Add three login retries"))
        }
        let started = Date()
        let (result, outcome) = await jobs(servers, seen, limits: .init(loaded: 0.2, loading: 0.2)).run(job(seen))
        // Far below the server's five minutes. The bound is loose on purpose: on a machine busy
        // with other tests, noticing the deadline has taken over twenty seconds.
        #expect(Date().timeIntervalSince(started) < 120)
        #expect(text(result) == "From the agent")
        #expect(outcome.route == .escalated(reason: "it took too long"))
        #expect(outcome.model == "mid:4b" && outcome.reason == "it took too long")
        #expect(seen.fallbacks == 1)
        #expect(seen.outcomes == [outcome])
    }

    @Test func aServerErrorSendsTheJobOn() async {
        let seen = Seen()
        // Whatever the server says about it stays out of the log.
        let servers = Servers { _ in (500, #"{"error":"the prompt was: secret"}"#) }
        let (result, outcome) = await jobs(servers, seen).run(job(seen))
        #expect(text(result) == "From the agent")
        #expect(outcome.route == .escalated(reason: "the model's server answered 500"))
        #expect(seen.fallbacks == 1)

        let down = Servers { _ in throw URLError(.cannotConnectToHost) }
        #expect(await jobs(down, seen).run(job(seen)).outcome.route == .escalated(reason: "the model's server didn't answer"))
        let slow = Servers { _ in throw URLError(.timedOut) }
        #expect(await jobs(slow, seen).run(job(seen)).outcome.route == .escalated(reason: "it took too long"))
        let garbled = Servers { _ in (200, "<html>") }
        #expect(await jobs(garbled, seen).run(job(seen)).outcome.route == .escalated(reason: "an answer that couldn't be read"))
        let huge = Servers { _ in (200, Servers.ollama(String(repeating: "a", count: SmallJobClient.responseLimit))) }
        #expect(await jobs(huge, seen).run(job(seen)).outcome.route == .escalated(reason: "an answer that's too big"))
        let cut = Servers { _ in (200, Servers.ollama("Add three login", stop: "length")) }
        #expect(await jobs(cut, seen).run(job(seen)).outcome.route == .escalated(reason: "an answer that was cut off"))
        #expect(seen.fallbacks == 6)
    }

    @Test func anAnswerThatWillNotDoSendsTheJobOn() async {
        let seen = Seen()
        for (answer, why) in [("I'm sorry, I can't help with that.", "it wouldn't answer"),
                              (String(repeating: "long ", count: 20), "a subject line over 72 characters"),
                              ("<think>still thinking", "an empty answer"),
                              ("Add a retry\n\n```\nretry(3)\n```\nas shown", "a code fence in the answer")] {
            let servers = Servers { _ in (200, Servers.ollama(answer)) }
            let (result, outcome) = await jobs(servers, seen).run(job(seen))
            #expect(text(result) == "From the agent")
            #expect(outcome.route == .escalated(reason: why))
        }
        #expect(seen.fallbacks == 4)
        #expect(seen.outcomes.count == 4)
    }

    @Test func withNoModelToTakeItTheJobGoesOnAsBefore() async {
        let seen = Seen()
        // Installed but not loaded, and too big to load for a commit message.
        let big = #"{"models":[{"name":"big:27b","size":17000000000,"details":{"context_length":262144},"capabilities":["completion"]}]}"#
        let servers = Servers(tags: big, running: #"{"models":[]}"#) { _ in (200, Servers.ollama("Add three login retries")) }
        let (result, outcome) = await jobs(servers, seen).run(job(seen))
        #expect(text(result) == "From the agent")
        #expect(outcome.route == .fallbackOnly)
        #expect(outcome.reason == "no model is loaded" && outcome.model == nil)
        #expect(servers.asked.isEmpty)
        #expect(seen.outcomes == [outcome])

        // Picked in Settings, it may load.
        let (chosen, picked) = await jobs(servers, seen, chosen: "Ollama/big:27b").run(job(seen))
        #expect(text(chosen) == "Add three login retries")
        #expect(picked.route == .local(model: "big:27b"))

        // A prompt longer than the loaded model reads at once is never sent to it.
        let loaded = Servers { _ in (200, Servers.ollama("Add three login retries")) }
        let long = await jobs(loaded, seen).run(job(seen, prompt: String(repeating: "+line\n", count: 6000))).outcome
        #expect(long.route == .fallbackOnly && long.reason == "the prompt is too long for the model")
        #expect(loaded.asked.isEmpty)
    }

    @Test func itsOwnPathFailingIsTheAnswer() async {
        let seen = Seen()
        let servers = Servers { _ in (500, "") }
        let failed = await jobs(servers, seen).run(job(seen, answer: .failure(URLError(.badServerResponse))))
        #expect(text(failed.result) == nil)
        // An answer from there is used even when it's not quite the shape, minus control characters.
        let loose = await jobs(servers, seen).run(job(seen, answer: .success(String(repeating: "w", count: 80) + "\u{1B}[0m\u{07}")))
        #expect(text(loose.result) == String(repeating: "w", count: 80))
        let empty = await jobs(servers, seen).run(job(seen, answer: .success(" \n")))
        #expect(text(empty.result) == nil)
    }

    @Test func lmStudioIsAskedTheOpenAIWay() async {
        let seen = Seen()
        let studio = #"{"data":[{"id":"qwen-coder","type":"llm","state":"loaded","max_context_length":32768,"loaded_context_length":8192}]}"#
        let servers = Servers(tags: #"{"models":[]}"#, running: #"{"models":[]}"#, studio: studio) { _ in
            (200, #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Add three login retries"},"finish_reason":"stop"}]}"#)
        }
        let (result, outcome) = await jobs(servers, seen).run(job(seen))
        #expect(text(result) == "Add three login retries")
        #expect(outcome.route == .local(model: "qwen-coder"))
        #expect(servers.asked.map { $0.url?.absoluteString } == ["http://127.0.0.1:1234/v1/chat/completions"])
    }
}

/// What's sent to a model's server, where it may go, and how its answer is read.
struct SmallJobClientTests {
    private let client = SmallJobClient(transport: { _ in throw URLError(.badURL) }, ollamaBase: URL(string: "http://127.0.0.1:11434")!,
                                        lmStudioBase: URL(string: "http://127.0.0.1:1234")!, configuredHosts: [])

    private func body(_ request: URLRequest?) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: request?.httpBody ?? Data())) as? [String: Any]) ?? [:]
    }

    @Test func anOllamaAnswerIsRead() throws {
        let reply = #"{"model":"qwen3:4b","created_at":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":"Add a retry","thinking":"hm"},"done_reason":"stop","done":true,"total_duration":1}"#
        #expect(try SmallJobClient.answer(.ollama, in: Data(reply.utf8)) == "Add a retry")
        #expect(throws: SmallJobClient.Failure.cutOff) {
            _ = try SmallJobClient.answer(.ollama, in: Data(#"{"message":{"content":"Add a"},"done_reason":"length","done":true}"#.utf8))
        }
        #expect(throws: SmallJobClient.Failure.unreadable) { _ = try SmallJobClient.answer(.ollama, in: Data(#"{"error":"model not found"}"#.utf8)) }
        #expect(throws: SmallJobClient.Failure.unreadable) { _ = try SmallJobClient.answer(.ollama, in: Data("not json".utf8)) }
    }

    @Test func anLMStudioAnswerIsRead() throws {
        let reply = #"{"id":"chatcmpl-1","object":"chat.completion","model":"qwen-coder","choices":[{"index":0,"message":{"role":"assistant","content":"Add a retry"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#
        #expect(try SmallJobClient.answer(.lmStudio, in: Data(reply.utf8)) == "Add a retry")
        #expect(throws: SmallJobClient.Failure.cutOff) {
            _ = try SmallJobClient.answer(.lmStudio, in: Data(#"{"choices":[{"message":{"content":"Add"},"finish_reason":"length"}]}"#.utf8))
        }
        #expect(throws: SmallJobClient.Failure.unreadable) { _ = try SmallJobClient.answer(.lmStudio, in: Data(#"{"choices":[]}"#.utf8)) }
        #expect(throws: SmallJobClient.Failure.unreadable) {
            _ = try SmallJobClient.answer(.lmStudio, in: Data(#"{"choices":[{"message":{"content":null,"reasoning_content":"hm"}}]}"#.utf8))
        }
    }

    @Test func anOllamaRequestAsksForOneAnswerAndLeavesTheModelLoadedAsItIs() {
        let model = SmallJobModel(host: .ollama, name: "qwen3:4b", size: nil, loaded: true, context: 8192, thinks: true)
        let request = client.request(model, instructions: "Write a title.", prompt: "The text", outputTokens: 40, timeout: 30)
        #expect(request?.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(request?.httpMethod == "POST" && request?.timeoutInterval == 30)
        let sent = body(request)
        #expect(sent["model"] as? String == "qwen3:4b")
        #expect(sent["stream"] as? Bool == false)
        #expect(sent["think"] as? Bool == false)
        #expect(sent["keep_alive"] == nil)
        let options = sent["options"] as? [String: Any] ?? [:]
        #expect(Set(options.keys) == ["temperature", "num_predict"])
        #expect(options["num_predict"] as? Int == 80)
        let messages = sent["messages"] as? [[String: String]] ?? []
        #expect(messages == [["role": "system", "content": "Write a title."], ["role": "user", "content": "The text"]])
        // A model that doesn't think isn't told not to: an older server would refuse the request.
        var plain = model
        plain.thinks = false
        #expect(body(client.request(plain, instructions: "", prompt: "", outputTokens: 40, timeout: 30))["think"] == nil)
    }

    @Test func anLMStudioRequestIsAChatCompletion() {
        let model = SmallJobModel(host: .lmStudio, name: "qwen-coder", size: nil, loaded: true, context: 8192)
        let request = client.request(model, instructions: "Write a title.", prompt: "The text", outputTokens: 40, timeout: 30)
        #expect(request?.url?.absoluteString == "http://127.0.0.1:1234/v1/chat/completions")
        let sent = body(request)
        #expect(sent["stream"] as? Bool == false)
        #expect(sent["max_tokens"] as? Int == 80)
        #expect((sent["messages"] as? [[String: String]])?.count == 2)
        #expect(sent["options"] == nil)
    }

    @Test func requestsOnlyGoToThisMacOrAServerNamedOnPurpose() {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "127.8.9.1", "::1", "[::1]"] { #expect(SmallJobClient.isLoopback(host)) }
        for host in ["192.168.1.5", "example.com", "127.0.0.1.example.com", "localhost.example.com", "127.1", "0.0.0.0", "", "1270.0.0.1"] {
            #expect(!SmallJobClient.isLoopback(host))
        }
        #expect(!SmallJobClient.isLoopback(nil))
        var elsewhere = client
        elsewhere.ollamaBase = URL(string: "http://192.168.1.5:11434")!
        let model = SmallJobModel(host: .ollama, name: "qwen3:4b", size: nil, loaded: true, context: 8192)
        #expect(elsewhere.request(model, instructions: "", prompt: "", outputTokens: 40, timeout: 30) == nil)
        #expect(!elsewhere.isAllowed(URL(string: "http://192.168.1.5:11434/api/chat")!))
        // OLLAMA_HOST named it.
        elsewhere.configuredHosts = ["192.168.1.5"]
        #expect(elsewhere.request(model, instructions: "", prompt: "", outputTokens: 40, timeout: 30) != nil)
        #expect(!elsewhere.isAllowed(URL(string: "http://192.168.1.6:11434/api/chat")!))
        #expect(!client.isAllowed(URL(string: "file:///etc/hosts")!))
        #expect(!client.isAllowed(URL(string: "ftp://127.0.0.1/x")!))
        // Models that aren't served by Ollama or LM Studio aren't asked.
        let cloud = SmallJobModel(host: .venice, name: "some-model", size: nil, loaded: true, context: 8192)
        #expect(client.request(cloud, instructions: "", prompt: "", outputTokens: 40, timeout: 30) == nil)
    }

    @Test func aServerElsewhereIsNeverAskedAndTheJobGoesOn() async {
        let model = SmallJobModel(host: .venice, name: "some-model", size: nil, loaded: true, context: 8192)
        await #expect(throws: SmallJobClient.Failure.notAllowed) {
            _ = try await client.ask(model, instructions: "", prompt: "", outputTokens: 40, timeout: 1)
        }
    }
}

/// The log of where jobs ran: short, and with no text of theirs in it.
@MainActor
struct SmallJobLogTests {
    private func outcome(_ route: SmallJobOutcome.Route, to name: String = "Claude Code", model: String? = "mid:4b") -> SmallJobOutcome {
        SmallJobOutcome(kind: .commitMessage, route: route, model: model, fallbackName: name, duration: 1.5)
    }

    @Test func itKeepsOnlyTheLastFifty() {
        let suite = "small-jobs-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = SmallJobLog(defaults: defaults, key: "log")
        #expect(log.entries.isEmpty)
        for index in 0..<(SmallJobLog.limit + 15) { log.record(outcome(.local(model: "model-\(index)"))) }
        #expect(log.entries.count == SmallJobLog.limit)
        #expect(log.entries.first?.route == .local(model: "model-15"))
        #expect(log.entries.last?.route == .local(model: "model-64"))
        // It's there after a restart, and no longer.
        let again = SmallJobLog(defaults: defaults, key: "log")
        #expect(again.entries == log.entries)
        again.clear()
        #expect(SmallJobLog(defaults: defaults, key: "log").entries.isEmpty)
    }

    @Test func anEntrySaysWhereAJobRanAndNothingOfWhatItSaid() throws {
        let entry = outcome(.escalated(reason: "it took too long"))
        let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any] ?? [:]
        #expect(Set(stored.keys) == ["id", "kind", "route", "model", "fallbackName", "duration", "date"])
        #expect(try JSONDecoder().decode(SmallJobOutcome.self, from: JSONEncoder().encode(entry)) == entry)
        let skipped = SmallJobOutcome(kind: .title, route: .fallbackOnly, fallbackName: "Codex", note: "no model is loaded", duration: 0)
        #expect(try JSONDecoder().decode(SmallJobOutcome.self, from: JSONEncoder().encode(skipped)) == skipped)
        #expect(skipped.reason == "no model is loaded" && !skipped.isLocal)
    }

    @Test func theSummaryCountsTheLastTwenty() {
        #expect(SmallJobLog.summary([]) == nil)
        let local = (0..<17).map { _ in outcome(.local(model: "mid:4b")) }
        let sent = [outcome(.escalated(reason: "it took too long")), outcome(.fallbackOnly, model: nil), outcome(.escalated(reason: "an empty answer"))]
        #expect(SmallJobLog.summary(local + sent) == "Last 20: 17 on this Mac, 3 sent on to Claude Code")
        // Older ones don't count.
        #expect(SmallJobLog.summary(sent + local + sent) == "Last 20: 17 on this Mac, 3 sent on to Claude Code")
        #expect(SmallJobLog.summary(Array(local.prefix(2))) == "Last 2: 2 on this Mac")
        let mixed = [outcome(.fallbackOnly, to: "Codex"), outcome(.escalated(reason: "x")), outcome(.fallbackOnly, to: "Codex")]
        #expect(SmallJobLog.summary(mixed) == "Last 3: 2 sent on to Codex, 1 sent on to Claude Code")
        #expect(SmallJobLog.lastReason(local + sent) == "an empty answer (mid:4b)")
        #expect(SmallJobLog.lastReason(local) == nil)
    }
}
