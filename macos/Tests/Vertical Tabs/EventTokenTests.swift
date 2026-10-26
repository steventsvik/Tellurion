import Foundation
import Testing
@testable import Ghostty

/// Agent and localhost events are accepted only with this launch's token in them.
struct EventTokenTests {
    private func body(token: Any?) -> String {
        var object: [String: Any] = ["kind": "agent", "status": "working"]
        if let token { object["t"] = token }
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }

    @Test func theTokenIsRandomHex() {
        #expect(EventToken.value.count == 32)
        #expect(EventToken.value.allSatisfy { $0.isHexDigit })
        #expect(EventToken.value == EventToken.value)
    }

    @Test func acceptsThisLaunchsToken() {
        #expect(EventToken.verify(body(token: EventToken.value)))
        // The token is all that's checked; an event can carry anything else.
        #expect(EventToken.verify("{\"t\":\"\(EventToken.value)\"}"))
    }

    @Test func rejectsAWrongToken() {
        let flipped = String(EventToken.value.map { $0 == "0" ? "1" : "0" })
        #expect(!EventToken.verify(body(token: flipped)))
        // Same length, one character off.
        var one = Array(EventToken.value)
        one[one.count - 1] = one[one.count - 1] == "a" ? "b" : "a"
        #expect(!EventToken.verify(body(token: String(one))))
        #expect(!EventToken.verify(body(token: String(EventToken.value.dropLast()))))
        #expect(!EventToken.verify(body(token: EventToken.value + "0")))
        #expect(!EventToken.verify(body(token: EventToken.value.uppercased())))
    }

    @Test func rejectsAMissingOrOddToken() {
        #expect(!EventToken.verify(body(token: nil)))
        #expect(!EventToken.verify(body(token: "")))
        #expect(!EventToken.verify(body(token: 12345)))
        #expect(!EventToken.verify(body(token: [EventToken.value])))
    }

    @Test func rejectsWhatIsNotAnEventObject() {
        #expect(!EventToken.verify(""))
        #expect(!EventToken.verify("not json"))
        #expect(!EventToken.verify("[\"\(EventToken.value)\"]"))
        #expect(!EventToken.verify("\"\(EventToken.value)\""))
        #expect(!EventToken.verify("{\"t\": \"\(EventToken.value)\""))
    }
}
