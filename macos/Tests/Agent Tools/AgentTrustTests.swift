import Foundation
import Testing
@testable import Ghostty

struct AgentTrustTests {
    private let home = "/Users/someone"
    private let app = "/Users/someone/.ghostty-extreme/board-agent"

    private func reason(_ folder: String, chosen: Bool = false, worktreeOf project: String? = nil,
                        projectTrusted: Bool = false, downloaded: Bool = false) -> AgentTrust.Reason? {
        AgentTrust.reason(folder: folder, appFolder: app, chosen: chosen, worktreeOf: project,
                          projectTrusted: projectTrusted, home: home, downloaded: downloaded)
    }

    @Test func trustsOnlyWhatIsKnown() {
        #expect(reason(app) == .appFolder)
        #expect(reason("/Users/someone/Projects/site", chosen: true) == .chosen)
        #expect(reason("/Users/someone/.ghostty-extreme/races/1/a", worktreeOf: "/Users/someone/Projects/site",
                       projectTrusted: true) == .worktree(of: "/Users/someone/Projects/site"))

        // A folder nobody picked, and a worktree of a project the agent doesn't trust.
        #expect(reason("/Users/someone/Projects/site") == nil)
        #expect(reason("/Users/someone/.ghostty-extreme/races/1/a", worktreeOf: "/Users/someone/Projects/site") == nil)
    }

    @Test func neverTrustsBroadOrDownloadedPlaces() {
        for folder in ["/", "/Users", home, home + "/Documents", home + "/Desktop", home + "/Downloads",
                       home + "/Downloads/some-repo", "/tmp/x", "/private/tmp/x", "/var/folders/ab/T/x",
                       "/Volumes/USB/project", "relative/path"] {
            #expect(reason(folder, chosen: true) == nil, "\(folder)")
            #expect(reason(folder, worktreeOf: home + "/Projects/site", projectTrusted: true) == nil, "\(folder)")
        }
        // Marked as downloaded by macOS, wherever it is.
        #expect(reason(home + "/Projects/unzipped", chosen: true, downloaded: true) == nil)
        // A worktree of a place that's never trusted.
        #expect(reason(home + "/.ghostty-extreme/races/1/a", worktreeOf: home, projectTrusted: true) == nil)
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func recordsClaudeTrustAndKeepsTheRest() throws {
        let store = try scratch().appendingPathComponent(".claude.json")
        // Not set up: nothing is created.
        #expect(!AgentTrust.trustClaude("/p/new", in: store))
        #expect(!FileManager.default.fileExists(atPath: store.path))

        let original = #"{"numStartups": 41, "theme": "dark", "projects": {"/p/old": {"hasTrustDialogAccepted": false, "allowedTools": ["Bash"]}}}"#
        try original.write(to: store, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)

        #expect(!AgentTrust.claudeTrusts("/p/new", in: store))
        #expect(AgentTrust.trustClaude("/p/new", in: store))
        #expect(AgentTrust.trustClaude("/p/old", in: store))
        #expect(AgentTrust.claudeTrusts("/p/new", in: store))

        // Only the one value went in; every other byte is as it was.
        #expect(try String(contentsOf: store, encoding: .utf8) == #"{"numStartups": 41, "theme": "dark", "projects": {"/p/new":{"hasTrustDialogAccepted":true},"/p/old": {"hasTrustDialogAccepted": true, "allowedTools": ["Bash"]}}}"#)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any])
        #expect(root["numStartups"] as? Int == 41)
        #expect(root["theme"] as? String == "dark")
        let projects = try #require(root["projects"] as? [String: Any])
        let old = try #require(projects["/p/old"] as? [String: Any])
        #expect(old["hasTrustDialogAccepted"] as? Bool == true)
        #expect(old["allowedTools"] as? [String] == ["Bash"])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // Already trusted: the file is left alone.
        let before = try Data(contentsOf: store)
        #expect(AgentTrust.trustClaude("/p/new", in: store))
        #expect(try Data(contentsOf: store) == before)

        // Not something this can read: left alone.
        try "not json".write(to: store, atomically: true, encoding: .utf8)
        #expect(!AgentTrust.trustClaude("/p/new", in: store))
        #expect(try String(contentsOf: store, encoding: .utf8) == "not json")
    }

    @Test func recordsCodexTrustOnce() throws {
        let store = try scratch().appendingPathComponent("config.toml")
        #expect(!AgentTrust.trustCodex("/p/new", in: store))

        let original = "model = \"gpt\"\n\n[projects.\"/p/old\"]\ntrust_level = \"trusted\"\n\n[projects.\"/p/asked\"]\ntrust_level = \"untrusted\""
        try original.write(to: store, atomically: true, encoding: .utf8)
        #expect(AgentTrust.codexTrusts("/p/old", in: store))
        #expect(!AgentTrust.codexTrusts("/p/new", in: store))

        #expect(AgentTrust.trustCodex("/p/new", in: store))
        #expect(AgentTrust.trustCodex("/p/new", in: store))
        let text = try String(contentsOf: store, encoding: .utf8)
        #expect(text.hasPrefix(original))
        #expect(text.components(separatedBy: "[projects.\"/p/new\"]").count == 2)
        #expect(AgentTrust.codexTrusts("/p/new", in: store))

        // You said no to this one, or it's written some other way: never a second table.
        #expect(!AgentTrust.trustCodex("/p/asked", in: store))
        #expect(!AgentTrust.trustCodex("/p/we\"ird", in: store))
        #expect(try String(contentsOf: store, encoding: .utf8) == text)
    }
}
