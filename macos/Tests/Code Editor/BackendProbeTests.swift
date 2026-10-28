import Foundation
import Testing
@testable import Ghostty

/// The Backend view runs nothing that came with the project, and passes nothing from the
/// project's files to a CLI as an option.
struct BackendProbeTests {
    private func project() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        try "name = \"demo\"\n".write(to: folder.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func theProjectsOwnWranglerNeverRuns() throws {
        let folder = try project()
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ran")
        let planted = folder.appendingPathComponent("node_modules/.bin/wrangler")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: planted, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)

        let command = BackendProbe.wranglerCommand()
        #expect(command?.contains { $0.hasPrefix(folder.path) } != true)
        #expect(command?.first != "npx")
        // Only ask for real when no wrangler is installed, so the test never reaches Cloudflare.
        if command == nil {
            let result = BackendProbe.run("wrangler", root: folder.path, body: ["dir": "", "what": "whoami"]) as? [String: Any]
            #expect(result?["missing"] as? String == "wrangler")
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func namesNeverPassForOptions() {
        #expect(BackendProbe.isName("production"))
        #expect(BackendProbe.isName("my_db-2"))
        #expect(!BackendProbe.isName("-c"))
        #expect(!BackendProbe.isName("--config"))
        #expect(!BackendProbe.isName(""))
        #expect(!BackendProbe.isName("a b"))
    }

    @Test func aVercelProjectNameNeverPassesForAnOption() throws {
        let folder = try project()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vercel = folder.appendingPathComponent(".vercel")
        try FileManager.default.createDirectory(at: vercel, withIntermediateDirectories: true)
        for (name, expected) in [("my-app", "my-app"), ("--scope=other", nil), ("-t", nil), (".hidden", nil)] as [(String, String?)] {
            try #"{"projectName": "\#(name)"}"#.write(to: vercel.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
            #expect(BackendProbe.vercelProject(folder.path) == expected)
        }
    }

    @Test func onlyProviderPagesOpenWithoutAsking() throws {
        for allowed in ["https://vercel.com/team/app", "https://dash.cloudflare.com/x", "https://app.vercel.app",
                        "https://demo.workers.dev"] {
            #expect(BackendProbe.isDashboard(try #require(URL(string: allowed))))
        }
        for other in ["https://example.com", "https://vercel.com.example.net", "http://vercel.com", "https://evilvercel.com"] {
            #expect(!BackendProbe.isDashboard(try #require(URL(string: other))))
        }
    }

    @Test func helpersDontGetTheEventToken() {
        #expect(EventToken.scrubbed([EventToken.environmentKey: "secret", "PATH": "/usr/bin"]) == ["PATH": "/usr/bin"])
        // The app puts the token in its own environment; git started by the app must not see it.
        if ProcessInfo.processInfo.environment[EventToken.environmentKey] == nil { EventToken.install() }
        let env = AgentTools.git(["-c", "alias.showenv=!env", "showenv"], in: FileManager.default.temporaryDirectory.path).output
        #expect(env.contains("PATH="))
        #expect(!env.contains(EventToken.environmentKey))
    }
}
