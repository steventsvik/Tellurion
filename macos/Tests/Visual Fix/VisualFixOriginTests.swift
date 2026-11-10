import Foundation
import Testing
@testable import Ghostty

/// Whose pages may talk to Visual Fix: your own app's, by the page's origin.
struct VisualFixOriginTests {
    @Test func aLocalOriginIsAccepted() {
        #expect(VisualFixSession.isLocal(scheme: "http", host: "localhost"))
        #expect(VisualFixSession.isLocal(scheme: "http", host: "127.0.0.1"))
        #expect(VisualFixSession.isLocal(scheme: "https", host: "::1"))
        #expect(VisualFixSession.isLocal(scheme: "http", host: "app.localhost"))
        #expect(VisualFixSession.isLocal(scheme: "http", host: "LOCALHOST"))
    }

    @Test func anyOtherOriginIsNot() throws {
        #expect(!VisualFixSession.isLocal(scheme: "https", host: "example.com"))
        #expect(!VisualFixSession.isLocal(scheme: "https", host: "localhost.example.com"))
        #expect(!VisualFixSession.isLocal(scheme: "file", host: "localhost"))
        #expect(!VisualFixSession.isLocal(scheme: "http", host: nil))
        #expect(!VisualFixSession.isLocal(scheme: nil, host: "localhost"))
        #expect(!VisualFixSession.isLocal(scheme: "http", host: ""))
        // A name that only starts like a private IPv6 address.
        #expect(!VisualFixSession.isLocal(scheme: "https", host: "fdroid.example.org"))
        #expect(VisualFixSession.isLocal(scheme: "http", host: "fd12:3456::1"))
        #expect(VisualFixSession.isLocal(scheme: "http", host: "192.168.1.20"))
        // The same answer as for a page's address.
        #expect(VisualFixSession.isLocal(try #require(URL(string: "http://localhost:3000/x"))))
        #expect(!VisualFixSession.isLocal(try #require(URL(string: "https://example.com/"))))
    }
}
