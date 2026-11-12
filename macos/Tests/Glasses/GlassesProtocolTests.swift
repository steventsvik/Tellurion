import AVFoundation
import Foundation
import Testing
@testable import Ghostty

/// What the glasses are told about the agents, and what they may ask for.
struct GlassesProtocolTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func agent(_ name: String, _ activity: VerticalTabAgentActivity, after seconds: TimeInterval = 0,
                       unseen: Bool = false, detail: String? = nil) -> GlassesAgent {
        GlassesAgent(id: UUID(), name: name, kind: "claude", activity: activity, unseen: unseen, task: nil, detail: detail,
                     since: start.addingTimeInterval(seconds))
    }

    private func list(_ message: [String: Any]) -> [[String: Any]] { message["agents"] as? [[String: Any]] ?? [] }

    @Test func theOnesThatNeedYouComeFirst() {
        let agents = [
            agent("ready", .ready), agent("seen", .done), agent("working", .working), agent("unseen", .done, unseen: true),
            agent("failed", .failed), agent("input", .needsInput), agent("permission", .needsPermission),
        ]
        let message = GlassesAgents.message(agents)
        #expect(list(message).compactMap { $0["name"] as? String } == ["permission", "input", "failed", "unseen", "working", "seen", "ready"])
        #expect(message["needs"] as? Int == 2)
        #expect(message["t"] as? String == "agents")
    }

    @Test func withinAStateTheLongestWaitingIsFirst() {
        let agents = [agent("later", .needsPermission, after: 60), agent("first", .needsPermission), agent("same", .needsPermission)]
        #expect(GlassesAgents.ordered(agents).map(\.name) == ["first", "same", "later"])
    }

    @Test func textIsClippedToOneLine() {
        var long = agent(String(repeating: "n", count: 90), .needsPermission, detail: "rm -rf build\n" + String(repeating: "d", count: 400))
        long.task = "line one\r\nline\ttwo \u{1b}[31m" + String(repeating: "t", count: 300)
        long.check = .init(state: "failed", summary: String(repeating: "s", count: 200))
        let item = list(GlassesAgents.message([long]))[0]
        let task = item["task"] as? String ?? ""
        let detail = item["detail"] as? String ?? ""
        #expect(task.count == GlassesAgents.taskLength)
        #expect(task.hasPrefix("line one line two [31m"))
        #expect(task.hasSuffix("…"))
        #expect(detail.count == GlassesAgents.detailLength)
        #expect(!detail.contains("\n"))
        #expect((item["name"] as? String)?.count == GlassesAgents.nameLength)
        #expect(((item["check"] as? [String: Any])?["sum"] as? String)?.count == GlassesAgents.summaryLength)
        #expect(GlassesAgents.clip("  a \n b  ", 10) == "a b")
    }

    @Test func twoAgentsWithOneNameAreToldApart() {
        let names = GlassesAgents.names([agent("Ada", .working), agent("Otto", .working), agent("ada", .working), agent("Ada", .working)])
        #expect(names == ["Ada", "Otto", "ada 2", "Ada 3"])
    }

    @Test func theMarksAreSentOnlyWhenThereAreAny() {
        var marked = agent("Ada", .working)
        marked.budget = .init(fraction: 0.8349, state: "warning")
        marked.conflicts = 2
        marked.wired = true
        marked.project = "shop"
        let item = list(GlassesAgents.message([marked]))[0]
        #expect((item["budget"] as? [String: Any])?["f"] as? Double == 0.83)
        #expect(item["conflicts"] as? Int == 2)
        #expect(item["wired"] as? Bool == true)
        #expect(item["project"] as? String == "shop")
        #expect(item["since"] as? Int == 1_700_000_000)
        #expect(item["prompt"] == nil)
        let plain = list(GlassesAgents.message([agent("Otto", .ready)]))[0]
        #expect(Set(plain.keys) == ["id", "name", "kind", "act", "since"])
    }

    @Test func anUnchangedListGivesTheSameText() {
        let agents = [agent("Ada", .working), agent("Otto", .done)]
        #expect(GlassesRoutes.json(GlassesAgents.message(agents)) == GlassesRoutes.json(GlassesAgents.message(agents)))
    }

    // MARK: Prompts

    @Test func aPromptHasAnIdentityThatChangesWithWhatIsAsked() {
        let first = agent("Ada", .needsPermission, detail: "Bash: ls")
        var other = first
        other.detail = "Bash: rm -rf /"
        var again = first
        again.since = start.addingTimeInterval(30)
        var working = first
        working.activity = .working
        let identity = GlassesAgents.promptIdentity(first)
        #expect(identity?.count == 16)
        #expect(identity == GlassesAgents.promptIdentity(first))
        #expect(identity != GlassesAgents.promptIdentity(other))
        #expect(identity != GlassesAgents.promptIdentity(again))
        #expect(GlassesAgents.promptIdentity(working) == nil)
        #expect(list(GlassesAgents.message([first]))[0]["prompt"] as? String == identity)
        // Two agents asking the same thing at the same time are still two prompts.
        var twin = first
        twin.id = UUID()
        #expect(identity != GlassesAgents.promptIdentity(twin))
    }

    @Test func anAnswerForAnotherPromptIsRefused() throws {
        let asking = agent("Ada", .needsPermission, detail: "Bash: ls")
        let identity = try #require(GlassesAgents.promptIdentity(asking))
        #expect(GlassesRules.answerRefusal(agent: asking, prompt: identity) == nil)
        // It asked for something else since the glasses last heard.
        var moved = asking
        moved.detail = "Bash: git push --force"
        #expect(GlassesRules.answerRefusal(agent: moved, prompt: identity) != nil)
        // It isn't asking any more, or it's gone.
        var working = asking
        working.activity = .working
        #expect(GlassesRules.answerRefusal(agent: working, prompt: identity) != nil)
        #expect(GlassesRules.answerRefusal(agent: nil, prompt: identity) != nil)
        #expect(GlassesRules.answerRefusal(agent: asking, prompt: "") != nil)
    }

    // MARK: Text to an agent

    @Test func textIsNeverTypedWhereNoAgentRuns() {
        #expect(GlassesRules.sayRefusal(hasAgent: false, text: "ls") != nil)
        #expect(GlassesRules.sayRefusal(hasAgent: true, text: "run the tests again") == nil)
    }

    @Test func textWithControlCharactersIsRefused() {
        #expect(GlassesRules.sayRefusal(hasAgent: true, text: "ok\u{03}") != nil)
        #expect(GlassesRules.sayRefusal(hasAgent: true, text: "one\ntwo") != nil)
        #expect(GlassesRules.sayRefusal(hasAgent: true, text: "esc\u{1b}[2J") != nil)
        #expect(GlassesRules.sayRefusal(hasAgent: true, text: "tab\there") != nil)
    }

    // MARK: Messages

    @Test func messagesAreChecked() {
        let id = UUID()
        #expect(GlassesRequest.parse(["t": "glance"]) == .request(.glance(true)))
        #expect(GlassesRequest.parse(["t": "unglance"]) == .request(.glance(false)))
        #expect(GlassesRequest.parse(["t": "orch"]) == .request(.orchestrators(true)))
        #expect(GlassesRequest.parse(["t": "tail", "id": id.uuidString, "lines": 20]) == .request(.tail(id: id, lines: 20)))
        #expect(GlassesRequest.parse(["t": "tail", "id": id.uuidString]) == .request(.tail(id: id, lines: 12)))
        #expect(GlassesRequest.parse(["t": "answer", "id": id.uuidString, "allow": true, "prompt": "abc"])
                == .request(.answer(id: id, allow: true, prompt: "abc")))
        #expect(GlassesRequest.parse(["t": "say", "id": id.uuidString, "text": "  hello  "]) == .request(.say(id: id, text: "hello")))
        #expect(GlassesRequest.parse(["t": "orchcmd", "id": "0123abcd", "text": "ship it"])
                == .request(.orchestratorCommand(id: "0123abcd", text: "ship it")))
        #expect(GlassesRequest.parse(["t": "listen"]) == .request(.listen))
        #expect(GlassesRequest.parse(["t": "heard?"]) == .request(.heard))
    }

    @Test func unknownMessagesAreNotOurs() {
        #expect(GlassesRequest.parse(["t": "text", "id": UUID().uuidString, "text": "ls\n"]) == .unknown)
        #expect(GlassesRequest.parse(["t": "keys", "key": "enter"]) == .unknown)
        #expect(GlassesRequest.parse(["t": "paste", "id": UUID().uuidString, "text": "ls"]) == .unknown)
        #expect(GlassesRequest.parse(["t": "launch"]) == .unknown)
        #expect(GlassesRequest.parse([:]) == .unknown)
        #expect(GlassesRequest.parse(["t": 7]) == .unknown)
    }

    @Test func messagesMissingSomethingOrTooLargeAreRefused() {
        let id = UUID().uuidString
        func refused(_ message: [String: Any]) -> Bool {
            if case .invalid = GlassesRequest.parse(message) { return true }
            return false
        }
        #expect(refused(["t": "say", "id": id, "text": String(repeating: "x", count: GlassesRequest.maxText + 1)]))
        #expect(refused(["t": "say", "id": id, "text": "   "]))
        #expect(refused(["t": "say", "id": "not-a-pane", "text": "hi"]))
        #expect(refused(["t": "say", "id": id]))
        #expect(refused(["t": "orchcmd", "id": String(repeating: "a", count: 65), "text": "hi"]))
        #expect(refused(["t": "tail", "id": id, "lines": 1000]))
        #expect(refused(["t": "tail", "id": id, "lines": 0]))
        // An answer has to say which prompt it's for, and yes or no as a boolean.
        #expect(refused(["t": "answer", "id": id, "allow": true]))
        #expect(refused(["t": "answer", "id": id, "allow": "yes", "prompt": "abc"]))
        #expect(refused(["t": "answer", "id": id, "allow": true, "prompt": String(repeating: "p", count: 65)]))
        #expect(!refused(["t": "say", "id": id, "text": String(repeating: "x", count: GlassesRequest.maxText)]))
    }

    // MARK: Limits

    @Test func soManyAMinuteAndNoMore() {
        var limiter = GlassesRateLimiter(capacity: 30, per: 60, now: start)
        func allowed(_ now: Date) -> Bool { limiter.allow(now: now) }
        for _ in 0..<30 { #expect(allowed(start)) }
        #expect(!allowed(start))
        // Two seconds give one back.
        #expect(allowed(start.addingTimeInterval(2)))
        #expect(!allowed(start.addingTimeInterval(2)))
        // A long quiet spell fills it, and no further.
        let later = start.addingTimeInterval(3600)
        for _ in 0..<30 { #expect(allowed(later)) }
        #expect(!allowed(later))
    }

    @Test func audioIsLimitedByItsBytes() {
        var limiter = GlassesRateLimiter(capacity: 100_000, per: 60, now: start)
        func allowed(_ bytes: Double, _ now: Date) -> Bool { limiter.allow(bytes, now: now) }
        #expect(allowed(60_000, start))
        #expect(!allowed(60_000, start))
        #expect(allowed(40_000, start))
        #expect(!allowed(1, start))
        // A clock that steps back gives nothing.
        #expect(!allowed(1, start.addingTimeInterval(-30)))
    }

    // MARK: Output

    @Test func theTailIsPlainTrimmedAndShort() {
        let screen = "first  \n\n  \nsecond\t \n\u{1b}[32mthird\u{1b}[0m\n   indented\n\n"
        #expect(GlassesText.tail(screen, lines: 3) == "second\n[32mthird[0m\n   indented")
        #expect(GlassesText.tail(screen, lines: 50).hasPrefix("first\nsecond"))
        #expect(GlassesText.tail("", lines: 5).isEmpty)
        #expect(GlassesText.tail("a\nb", lines: 0).isEmpty)
        let long = (0..<200).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        let tail = GlassesText.tail(long, lines: 60)
        #expect(tail.count == GlassesText.tailLimit)
        #expect(tail.hasSuffix("line 199 " + String(repeating: "x", count: 40)))
    }

    // MARK: Sound

    @Test func soundBecomesSamples() throws {
        // 0, 1, -1, the largest and the smallest, little-endian.
        let pcm = Data([0x00, 0x00, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x80])
        let buffer = try #require(GlassesAudio.buffer(from: pcm))
        #expect(buffer.frameLength == 5)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        let samples = try #require(buffer.floatChannelData?[0])
        let expected: [Float] = [0, 1.0 / 32_768.0, -1.0 / 32_768.0, 32_767.0 / 32_768.0, -1]
        for (index, value) in expected.enumerated() {
            #expect(abs(samples[index] - value) < 0.000_001, "sample \(index) is \(samples[index]), not \(value)")
        }
    }

    @Test func anOddByteIsLeftOutAndNothingIsNothing() throws {
        let odd = try #require(GlassesAudio.buffer(from: Data([1, 0, 2, 0, 3])))
        #expect(odd.frameLength == 2)
        #expect(GlassesAudio.buffer(from: Data()) == nil)
        #expect(GlassesAudio.buffer(from: Data([7])) == nil)
        #expect(GlassesAudio.maxUtterance == 60 * 16_000 * 2)
    }

    // MARK: Paths and origins

    @Test func thePhonesSocketKeepsItsOwnOriginRule() {
        #expect(GlassesRoutes.acceptsSocket(path: "/api/ws", phoneOriginOK: true, glassesOn: true))
        #expect(GlassesRoutes.acceptsSocket(path: "/api/ws", phoneOriginOK: true, glassesOn: false))
        #expect(!GlassesRoutes.acceptsSocket(path: "/api/ws", phoneOriginOK: false, glassesOn: true))
        #expect(!GlassesRoutes.acceptsSocket(path: "/api/ws", phoneOriginOK: false, glassesOn: false))
    }

    @Test func theGlassesSocketTakesAnyOriginOnlyWhileGlassesAreOn() {
        #expect(GlassesRoutes.acceptsSocket(path: "/glasses/ws", phoneOriginOK: false, glassesOn: true))
        #expect(GlassesRoutes.acceptsSocket(path: "/glasses/ws", phoneOriginOK: true, glassesOn: true))
        #expect(!GlassesRoutes.acceptsSocket(path: "/glasses/ws", phoneOriginOK: true, glassesOn: false))
        #expect(!GlassesRoutes.acceptsSocket(path: "/glasses/ws/", phoneOriginOK: true, glassesOn: true))
        #expect(!GlassesRoutes.acceptsSocket(path: "/ws", phoneOriginOK: true, glassesOn: true))
        #expect(!GlassesRoutes.acceptsSocket(path: "/glasses/api/ws", phoneOriginOK: true, glassesOn: true))
    }

    @Test func onlyTheGlassesAPIAnswersOtherOrigins() {
        #expect(GlassesRoutes.corsHeaders(path: "/glasses/api/pair-request")["Access-Control-Allow-Origin"] == "*")
        #expect(GlassesRoutes.corsHeaders(path: "/glasses/api/ping")["Access-Control-Allow-Headers"] == "Content-Type")
        #expect(GlassesRoutes.corsHeaders(path: "/api/pair").isEmpty)
        #expect(GlassesRoutes.corsHeaders(path: "/api/ping").isEmpty)
        #expect(GlassesRoutes.corsHeaders(path: "/").isEmpty)
        #expect(GlassesRoutes.corsHeaders(path: "/glasses/index.html").isEmpty)
        #expect(GlassesRoutes.corsHeaders(path: "/glasses/apix").isEmpty)
    }

    @Test func theTestsAndThePackagingHelperAreNotServed() {
        #expect(GlassesRoutes.isHidden(path: "/glasses/test/input.test.js"))
        #expect(GlassesRoutes.isHidden(path: "/glasses/pack/pack.sh"))
        #expect(!GlassesRoutes.isHidden(path: "/glasses/app.js"))
        #expect(!GlassesRoutes.isHidden(path: "/glasses/vendor/even_hub_sdk/index.js"))
    }

    private func request(_ method: String, _ path: String, _ body: [String: Any] = [:]) -> PhoneHTTPServer.Request {
        PhoneHTTPServer.Request(method: method, path: path, query: [:], headers: [:],
                                body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    @Test func nothingUnderGlassesAnswersWhileGlassesAreOff() throws {
        for path in ["/glasses/", "/glasses/app.js", "/glasses/api/ping", "/glasses/api/pair-request", "/glasses"] {
            #expect(GlassesHTTP.response(for: request("GET", path), isOn: false)?.status == 404)
            #expect(GlassesHTTP.response(for: request("POST", path), isOn: false)?.status == 404)
        }
        // The app can still tell "off" from "unreachable": the refusal is readable from its origin.
        let off = try #require(GlassesHTTP.response(for: request("GET", "/glasses/api/ping"), isOn: false))
        #expect(off.headers["Access-Control-Allow-Origin"] == "*")
    }

    @Test func thePhonesPathsAreLeftToThePhone() {
        for path in ["/", "/api/pair", "/api/ping", "/app.js", "/glassesx", "/api/ws"] {
            #expect(GlassesHTTP.response(for: request("GET", path), isOn: true) == nil)
            #expect(GlassesHTTP.response(for: request("POST", path), isOn: true) == nil)
            #expect(GlassesHTTP.response(for: request("GET", path), isOn: false) == nil)
        }
    }

    @Test func theGlassesPathsWhileOn() throws {
        // The page's files are served as files; its tests and packaging helper aren't.
        #expect(GlassesHTTP.response(for: request("GET", "/glasses/"), isOn: true) == nil)
        #expect(GlassesHTTP.response(for: request("GET", "/glasses/app.js"), isOn: true) == nil)
        #expect(GlassesHTTP.response(for: request("GET", "/glasses/test/fit.test.js"), isOn: true)?.status == 404)
        #expect(GlassesHTTP.response(for: request("GET", "/glasses/pack/app.json"), isOn: true)?.status == 404)
        #expect(GlassesHTTP.response(for: request("GET", "/glasses"), isOn: true)?.status == 404)
        #expect(GlassesHTTP.response(for: request("POST", "/glasses/app.js"), isOn: true)?.status == 404)
        // A browser asks before it posts from another origin.
        let preflight = try #require(GlassesHTTP.response(for: request("OPTIONS", "/glasses/api/pair-request"), isOn: true))
        #expect(preflight.status == 204)
        #expect(preflight.headers["Access-Control-Allow-Methods"]?.contains("POST") == true)
        let ping = try #require(GlassesHTTP.response(for: request("GET", "/glasses/api/ping"), isOn: true))
        #expect(ping.status == 200)
        #expect(ping.headers["Access-Control-Allow-Origin"] == "*")
        #expect(GlassesHTTP.response(for: request("GET", "/glasses/api/nothing"), isOn: true)?.status == 404)
        #expect(GlassesHTTP.response(for: request("POST", "/glasses/api/pair"), isOn: true)?.status == 400)
        #expect(GlassesHTTP.response(for: request("POST", "/glasses/api/pair-wait"), isOn: true)?.status == 400)
    }
}
