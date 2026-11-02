import Foundation
import Testing
@testable import Ghostty

/// What a key and a model's name may look like, reading Venice's list, and what the proxy lets
/// through and changes.
struct VeniceAPITests {
    @Test func aKeyOnlyHasToFitInAHeader() {
        #expect(VeniceAPI.isValidKey("VENICE_INFERENCE_KEY_abc-123"))
        #expect(!VeniceAPI.isValidKey(""))
        #expect(!VeniceAPI.isValidKey("has space"))
        #expect(!VeniceAPI.isValidKey("line\nbreak"))
        #expect(!VeniceAPI.isValidKey("line\r\nX-Evil: 1"))
        #expect(!VeniceAPI.isValidKey(String(repeating: "a", count: 513)))
    }

    @Test func aModelNameCantPassForAnOptionOrCarryAnythingElse() {
        #expect(VeniceAPI.isValidSlug("deepseek-v4-1-flash-1017-uncensored"))
        #expect(VeniceAPI.isValidSlug("model_1.2:free"))
        #expect(!VeniceAPI.isValidSlug(""))
        #expect(!VeniceAPI.isValidSlug("--base"))
        #expect(!VeniceAPI.isValidSlug("model; rm -rf x"))
        #expect(!VeniceAPI.isValidSlug("model\u{1B}]2;x\u{07}"))
        #expect(!VeniceAPI.isValidSlug("$(id)"))
        #expect(!VeniceAPI.isValidSlug("a/../b"))
    }

    @Test func theProxyForwardsModelRequestsAndNothingElse() {
        #expect(VeniceAPI.proxyAllows(method: "POST", target: "/api/v1/responses"))
        #expect(VeniceAPI.proxyAllows(method: "POST", target: "/api/v1/chat/completions"))
        #expect(VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models"))
        #expect(VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?type=text"))
        #expect(VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?client_version=0.165.0&a_b=c-d"))
        #expect(!VeniceAPI.proxyAllows(method: "POST", target: "/api/v1/models"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/responses"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/api_keys"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/api_keys/rate_limits"))
        #expect(!VeniceAPI.proxyAllows(method: "DELETE", target: "/api/v1/models"))
        #expect(!VeniceAPI.proxyAllows(method: "POST", target: "/api/v1/responses/../api_keys"))
        #expect(!VeniceAPI.proxyAllows(method: "POST", target: "/api/v1/responses?x=1"))
        #expect(!VeniceAPI.proxyAllows(method: "POST", target: "//evil.example/api/v1/responses"))
        #expect(!VeniceAPI.proxyAllows(method: "POST", target: "http://evil.example/api/v1/responses"))
        #expect(!VeniceAPI.proxyAllows(method: "POST", target: "/api/v1/%72esponses"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models/../api_keys"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?x=//evil.example"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?x=%2F%2Fevil"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?x=..%2F"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?x=1#frag"))
        #expect(!VeniceAPI.proxyAllows(method: "GET", target: "/api/v1/models?x=@evil"))
    }

    private func forwarded(_ json: String) throws -> [String: Any] {
        let out = try #require(VeniceAPI.forwardedBody(Data(json.utf8)))
        return try #require(try JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    @Test func folderPathsStayHomeAndVenicesSystemPromptStaysOff() throws {
        let body = try forwarded(#"{"model":"m","client_metadata":{"x-codex-turn-metadata":"/home/me/secret"},"prompt_cache_key":"k","tools":[{"name":"a"}]}"#)
        #expect(body["client_metadata"] == nil)
        #expect((body["venice_parameters"] as? [String: Any])?["include_venice_system_prompt"] as? Bool == false)
        #expect(body["prompt_cache_key"] as? String == "k")
        #expect(body["model"] as? String == "m")
        #expect((body["tools"] as? [[String: Any]])?.first?["name"] as? String == "a")
    }

    @Test func venicesOtherParametersStayAndItsPromptIsAlwaysOff() throws {
        let body = try forwarded(#"{"venice_parameters":{"include_venice_system_prompt":true,"enable_web_search":"off"}}"#)
        let parameters = try #require(body["venice_parameters"] as? [String: Any])
        #expect(parameters["include_venice_system_prompt"] as? Bool == false)
        #expect(parameters["enable_web_search"] as? String == "off")
    }

    @Test func theSameToolsComeOutTheSameEveryTurn() throws {
        // The model's prompt cache only matches on an identical start.
        let one = try #require(VeniceAPI.forwardedBody(Data(#"{"tools":[{"b":1,"a":2,"c":{"z":1,"y":2}}],"model":"m"}"#.utf8)))
        let two = try #require(VeniceAPI.forwardedBody(Data(#"{"model":"m","tools":[{"c":{"y":2,"z":1},"a":2,"b":1}]}"#.utf8)))
        #expect(one == two)
    }

    @Test func aBodyThatIsntAnObjectIsNotForwarded() {
        #expect(VeniceAPI.forwardedBody(Data("[]".utf8)) == nil)
        #expect(VeniceAPI.forwardedBody(Data("not json".utf8)) == nil)
        #expect(VeniceAPI.forwardedBody(Data()) == nil)
    }

    @Test func proxyContentLength() {
        #expect(VeniceProxy.contentLength("POST / HTTP/1.1\r\nContent-Length: 12") == 12)
        #expect(VeniceProxy.contentLength("POST / HTTP/1.1\r\ncontent-length:7") == 7)
        #expect(VeniceProxy.contentLength("POST / HTTP/1.1") == 0)
        #expect(VeniceProxy.contentLength("POST / HTTP/1.1\r\nContent-Length: nope") == 0)
        // A negative length would crash the app, and it arrives before the token is checked.
        #expect(VeniceProxy.contentLength("POST / HTTP/1.1\r\nContent-Length: -1") == 0)
    }

    @Test func readingTheModelList() throws {
        let json = #"""
        {"data":[
          {"id":"good-uncensored","model_spec":{"name":"Good\u001b]2;x","uncensored":true,"privacy":"private","availableContextTokens":1000000,
           "maxCompletionTokens":131072,"pricing":{"input":{"usd":0.33},"cache_input":{"usd":0.00825},"output":{"usd":1.32}},
           "capabilities":{"supportsFunctionCalling":true,"optimizedForCode":true,"supportsVision":true,"supportsReasoning":true,"supportsE2EE":false}}},
          {"id":"anon","model_spec":{"name":"Anon","privacy":"anonymized","capabilities":{"supportsFunctionCalling":true}}},
          {"id":"sealed","model_spec":{"name":"Sealed","privacy":"private","capabilities":{"supportsFunctionCalling":true,"supportsE2EE":true}}},
          {"id":"no-tools","model_spec":{"name":"Plain","privacy":"private","capabilities":{}}},
          {"id":"gone","model_spec":{"offline":true,"capabilities":{}}},
          {"id":"--bad","model_spec":{}}
        ]}
        """#
        let models = try #require(VeniceAPI.parseModels(Data(json.utf8)))
        #expect(models.map(\.id) == ["good-uncensored", "anon", "sealed", "no-tools"])
        let good = models[0]
        #expect(good.name == "Good]2;x")
        #expect(good.uncensored && good.isPrivate && good.tools && good.worksInCodex)
        #expect(good.context == 1_000_000 && good.maxOutput == 131072)
        #expect(good.inputPrice == 0.33 && good.cachedInputPrice == 0.00825 && good.outputPrice == 1.32)
        #expect(good.detail == "1M context · $0.33 in · $1.32 out per M · Tools")
        #expect(!models[1].isPrivate && models[1].worksInCodex)
        #expect(models[2].tools && !models[2].worksInCodex)
        #expect(!models[3].worksInCodex)
        #expect(VeniceAPI.parseModels(Data("{}".utf8)) == nil)
    }

    @Test func uncensoredModelsComeFirstThenThoseMadeForCode() throws {
        let json = #"{"data":[{"id":"z","model_spec":{"name":"Z"}},{"id":"c","model_spec":{"name":"C","capabilities":{"optimizedForCode":true}}},{"id":"u","model_spec":{"name":"U","uncensored":true}}]}"#
        let models = try #require(VeniceAPI.parseModels(Data(json.utf8)))
        #expect(VeniceAPI.sorted(models).map(\.id) == ["u", "c", "z"])
    }

    @Test func aRejectedKeyIsSaidPlainly() {
        #expect(VeniceAPI.connectionProblem(status: 401).contains("doesn't accept"))
        #expect(VeniceAPI.connectionProblem(status: 429).contains("limiting"))
        #expect(VeniceAPI.connectionProblem(status: 500).contains("500"))
    }
}
