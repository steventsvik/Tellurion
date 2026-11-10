import Foundation
import Testing
@testable import Ghostty

/// A localhost session's address comes from what its server printed, and only when that's a
/// local address on a port the server listens on.
struct LocalhostAddressTests {
    private func announced(_ log: String, _ ports: [Int]) -> String? {
        LocalhostAddress.announced(in: log, listening: ports)?.absoluteString
    }

    /// What real servers print, the ports they listen on, and the address that should come out.
    private static let printed: [(line: String, ports: [Int], expected: String)] = [
        ("  ➜  Local:   http://localhost:5173/app/", [5173], "http://localhost:5173/app/"),
        ("  ➜  Local:   http://localhost:5173/", [5173], "http://localhost:5173"),
        ("   - Local:        http://localhost:3000", [3000], "http://localhost:3000"),
        ("   - Local:        http://localhost:3000/docs", [3000], "http://localhost:3000/docs"),
        ("ready - started server on 0.0.0.0:3000, url: http://localhost:3000", [3000], "http://localhost:3000"),
        (" * Running on http://127.0.0.1:5000", [5000], "http://localhost:5000"),
        ("Starting development server at http://127.0.0.1:8000/", [8000], "http://localhost:8000"),
        ("Starting development server at http://127.0.0.1:8000/admin/", [8000], "http://localhost:8000/admin/"),
        ("│   Local:            http://localhost:6006/   │", [6006], "http://localhost:6006"),
        ("  ➜  Local:   https://localhost:5173/", [5173], "https://localhost:5173"),
        ("Listening on http://[::1]:4321/", [4321], "http://localhost:4321"),
        ("Server running at http://0.0.0.0:8080/docs/", [8080], "http://localhost:8080/docs/"),
        ("Serving HTTP on :: port 8000 (http://[::]:8000/) ...", [8000], "http://localhost:8000"),
        ("** Angular Live Development Server is listening on localhost:4200, open your browser on http://localhost:4200/ **",
         [4200], "http://localhost:4200"),
        ("Jupyter Server is running at: http://localhost:8888/lab?token=abc123", [8888], "http://localhost:8888/lab?token=abc123"),
        ("Docs are at http://localhost:3000/guide.", [3000], "http://localhost:3000/guide"),
        ("  ➜  Local:   http://shop.localhost:5173/", [5173], "http://shop.localhost:5173"),
        ("Secure server on https://127.0.0.1:8443/", [8443], "https://127.0.0.1:8443"),
        ("Listening on HTTP://LOCALHOST:3000/App", [3000], "http://localhost:3000/App"),
        ("Serving on http://localhost/site/", [80], "http://localhost:80/site/"),
        ("Serving on https://localhost/", [443, 8080], "https://localhost:443"),
    ]

    @Test func readsWhatServersPrint() {
        for row in Self.printed {
            #expect(announced(row.line, row.ports) == row.expected, "\(row.line)")
        }
    }

    @Test func seesThroughTerminalColors() {
        // Vite colors the label and makes the port bold.
        let esc = "\u{1B}"
        let vite = "\r\n  \(esc)[32m\(esc)[1mVITE\(esc)[22m v5.4.2\(esc)[39m  \(esc)[2mready in \(esc)[0m\(esc)[1m312\(esc)[22m ms\r\n\r\n"
            + "  \(esc)[32m➜\(esc)[39m  \(esc)[1mLocal\(esc)[22m:   \(esc)[36mhttp://localhost:\(esc)[1m5173\(esc)[22m/app/\(esc)[39m\r\n"
            + "  \(esc)[2m\(esc)[32m➜\(esc)[39m\(esc)[22m  \(esc)[2mNetwork\(esc)[22m\(esc)[2m: use \(esc)[22m\(esc)[1m--host\(esc)[22m\(esc)[2m to expose\(esc)[22m\r\n"
        #expect(announced(vite, [5173]) == "http://localhost:5173/app/")
        // A window title set on the way doesn't hide it either.
        #expect(announced("\(esc)]0;dev\u{07}Local: http://localhost:3000/x\n", [3000]) == "http://localhost:3000/x")
    }

    @Test func theAppsPortWinsOverALowerOne() {
        // The inspector and a reload socket listen too; the lowest port isn't the app.
        let log = """
        Debugger listening on ws://127.0.0.1:9229/0f2c3a
        For help, see: https://nodejs.org/en/docs/inspector
          ➜  Local:   http://localhost:5173/app/
        """
        #expect(announced(log, [3001, 5173, 9229]) == "http://localhost:5173/app/")
    }

    @Test func ignoresPortsThatArentListening() {
        #expect(announced("Local: http://localhost:5173/", [3000]) == nil)
        #expect(announced("Local: http://localhost:5173/", []) == nil)
        // No port means 80 (or 443), which has to be listening like any other.
        #expect(announced("See http://localhost/docs", [3000]) == nil)
        // Another server's address above the session's own.
        let log = "API proxied to http://localhost:4000/api\nListening at http://localhost:3000/shop\n"
        #expect(announced(log, [3000]) == "http://localhost:3000/shop")
    }

    @Test func prefersTheLineLabelledLocal() {
        let log = """
        App running at:
          - Network: http://0.0.0.0:8080/net/
          - Local:   http://localhost:8080/app/
        GET http://localhost:8080/later 200
        """
        #expect(announced(log, [8080]) == "http://localhost:8080/app/")
        // With no label, the first one.
        #expect(announced("up at http://localhost:8080/a\nGET http://localhost:8080/b\n", [8080]) == "http://localhost:8080/a")
        // A network line is still better than nothing.
        #expect(announced("  - Network: http://0.0.0.0:8080/net/", [8080]) == "http://localhost:8080/net/")
    }

    @Test func onlyTheCurrentRunCounts() {
        let log = """

        ──── 2026-01-05 10:00:00 ────
          ➜  Local:   http://localhost:5173/old/

        ──── 2026-01-05 10:05:00 ────
          ➜  Local:   http://localhost:5173/new/
        """
        #expect(announced(log, [5173]) == "http://localhost:5173/new/")
        let restarting = "\n──── 2026-01-05 10:00:00 ────\nLocal: http://localhost:5173/old/\n\n──── 2026-01-05 10:05:00 ────\n"
        #expect(announced(restarting, [5173]) == nil)
    }

    @Test(arguments: [
        "Local: javascript://localhost:3000/%0Aalert(1)",
        "Local: file://localhost:3000/etc/passwd",
        "Local: ftp://localhost:3000/",
        "Local: http://example.com:3000/",
        "Local: http://192.168.1.20:3000/",
        "Local: http://localhost.example.com:3000/",
        "Local: http://evil.com:3000/?next=localhost",
        "Local: http://localhost:3000@example.com/",
        "Local: http://user:secret@localhost:3000/",
        "Local: http://notlocalhost:3000/",
        "Local: http://localhost:30\u{01}00/",
        "Local: http://localhost:3000\u{1B}/admin",
        "Local: http://local\u{00}host:3000/",
        "Local: localhost:3000/app",
    ])
    func refusesWhatIsntALocalAddress(line: String) {
        #expect(announced(line, [3000, 30, 80, 443]) == nil)
    }

    @Test func refusesHugeLines() {
        let long = "Local: http://localhost:3000/" + String(repeating: "a", count: 5000)
        #expect(announced(long, [3000]) == nil)
        #expect(LocalhostAddress.address("http://localhost:3000/" + String(repeating: "a", count: 5000), listening: [3000]) == nil)
        // The address after it is still found.
        #expect(announced(long + "\nLocal: http://localhost:3000/ok\n", [3000]) == "http://localhost:3000/ok")
    }

    @Test func keepsOnlyWhatAnAddressCanHold() {
        // Quotes, brackets and spaces end an address; nothing after them comes along.
        #expect(announced("open \"http://localhost:3000/a\"; rm -rf ~", [3000]) == "http://localhost:3000/a")
        #expect(announced("<http://localhost:3000/a> `whoami`", [3000]) == "http://localhost:3000/a")
        // What a shell would act on isn't passed along at all.
        #expect(announced("http://localhost:3000/a$(whoami)", [3000]) == nil)
        #expect(announced("http://localhost:3000/?a=1&reboot", [3000]) == nil)
        #expect(announced("http://localhost:3000/a;id", [3000]) == nil)
        #expect(announced("http://localhost:3000/a#top", [3000]) == "http://localhost:3000/a")
    }

    @Test func showsTheAddressCompactly() throws {
        #expect(LocalhostAddress.display(try #require(URL(string: "http://localhost:5173/app/"))) == "localhost:5173/app/")
        #expect(LocalhostAddress.display(try #require(URL(string: "http://localhost:3000"))) == "localhost:3000")
        #expect(LocalhostAddress.display(try #require(URL(string: "http://localhost:3000/"))) == "localhost:3000")
        #expect(LocalhostAddress.display(try #require(URL(string: "https://shop.localhost:8443/lab?token=abc"))) == "shop.localhost:8443/lab")
    }

    @Test func aSessionOpensWhatItsServerAnnounced() throws {
        var session = LocalhostSession(id: "lh-1-1", cwd: "/tmp", command: "vite", log: "/tmp/none.log", agent: nil, created: Date())
        session.ports = [5173, 24678]
        #expect(session.wantsAddress)
        session.mainPort = 5173
        session.announced = try #require(URL(string: "http://localhost:5173/app/"))
        #expect(session.url?.absoluteString == "http://localhost:5173/app/")
        #expect(session.tabAddress == "localhost:5173/app/")
        #expect(!session.wantsAddress)
        // Its port closed: there's no address, and the log is worth another look.
        session.ports = [24678]
        #expect(session.url == nil)
        #expect(session.wantsAddress)
        // Without an announcement it's the port it went live on, as before.
        session.announced = nil
        session.ports = [5173, 24678]
        #expect(session.url?.absoluteString == "http://localhost:5173")
    }

    @Test func readsTheStartAndEndOfALongLog() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("localhost-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let noise = String(repeating: "GET /api/items 200 in 12ms\n", count: 20_000)
        let log = "\n──── 2026-01-05 10:00:00 ────\nLocal: http://localhost:5173/old/\n" + noise
            + "\n──── 2026-01-05 10:05:00 ────\nLocal: http://localhost:5173/new/\n" + noise + "last line\n"
        try log.write(to: file, atomically: true, encoding: .utf8)
        let text = LocalhostAddress.read(logAt: file.path)
        #expect(text.utf8.count <= 2 * LocalhostAddress.readLimit + 1)
        #expect(text.hasSuffix("last line\n"))
        #expect(LocalhostAddress.announced(in: text, listening: [5173])?.absoluteString == "http://localhost:5173/new/")
        #expect(LocalhostAddress.read(logAt: file.path + ".missing").isEmpty)
    }
}
