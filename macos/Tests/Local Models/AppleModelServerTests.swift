import Foundation
import Testing
@testable import Ghostty

/// The head of a request to Apple's model, read before anything is known about the sender.
struct AppleModelServerTests {
    private func head(_ lines: String...) -> String {
        (["POST /v1/chat/completions HTTP/1.1"] + lines).joined(separator: "\r\n")
    }

    @Test func theBodyLengthIsNeverOneThatCrashes() {
        #expect(AppleModelServer.bodyLength(head("Content-Length: 42")) == 42)
        #expect(AppleModelServer.bodyLength(head("content-length:7")) == 7)
        #expect(AppleModelServer.bodyLength(head("Host: x")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length:")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length:   ")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length: -1")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length: -9223372036854775808")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length: abc")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length: 12:34")) == 0)
        #expect(AppleModelServer.bodyLength(head("Content-Length: 9223372036854775807")) == 1_048_576)
        #expect(AppleModelServer.bodyLength(head("Content-Length: 99999999999999999999999999")) == 0)
        #expect(AppleModelServer.bodyLength("") == 0)
        // Taking that much of a body never traps.
        let body = Data("hello".utf8)
        for value in ["", "-5", "abc", "3", "9223372036854775807"] {
            #expect(body.prefix(AppleModelServer.bodyLength(head("Content-Length: \(value)"))).count <= body.count)
        }
    }

    @Test func onlyThisLaunchsKeyIsAccepted() {
        #expect(AppleModelServer.authorized(head("Authorization: Bearer k1"), key: "k1"))
        #expect(AppleModelServer.authorized(head("Host: x", "authorization:Bearer k1"), key: "k1"))
        #expect(!AppleModelServer.authorized(head("Authorization: Bearer k2"), key: "k1"))
        #expect(!AppleModelServer.authorized(head("Authorization: Bearer"), key: "k1"))
        #expect(!AppleModelServer.authorized(head("Authorization:"), key: "k1"))
        #expect(!AppleModelServer.authorized(head("Host: x"), key: "k1"))
        #expect(!AppleModelServer.authorized("", key: "k1"))
        // The request line isn't a header.
        #expect(!AppleModelServer.authorized("Authorization: Bearer k1", key: "k1"))
    }
}
