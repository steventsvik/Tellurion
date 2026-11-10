import Foundation
import Testing
@testable import Ghostty

/// Adding the design's include line to the user's Ghostty config (GhosttyDesignConfig): the
/// config's own contents are never replaced, whatever they are.
struct DesignConfigTests {
    private let ours = Data((GhosttyDesignConfig.marker + "\n" + GhosttyDesignConfig.includeLine + "\n").utf8)

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("design-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aMissingConfigBecomesJustOurLines() {
        #expect(GhosttyDesignConfig.configIncludingFragment(nil) == ours)
        #expect(GhosttyDesignConfig.configIncludingFragment(Data()) == ours)
    }

    @Test func ourLinesGoAfterTheConfigsOwn() {
        let config = Data("font-size = 14\ntheme = nord".utf8)
        #expect(GhosttyDesignConfig.configIncludingFragment(config) == config + Data("\n\n".utf8) + ours)
        let ended = Data("font-size = 14\n".utf8)
        #expect(GhosttyDesignConfig.configIncludingFragment(ended) == ended + Data("\n".utf8) + ours)
    }

    @Test func aConfigThatIncludesItAlreadyIsLeftAlone() {
        for line in ["config-file = ?tellurion-design.ghostty", "config-file=tellurion-design.ghostty",
                     "  config-file = \"tellurion-design.ghostty\""] {
            #expect(GhosttyDesignConfig.configIncludingFragment(Data("font-size = 14\n\(line)\n".utf8)) == nil)
        }
        #expect(GhosttyDesignConfig.configIncludingFragment(Data("config-file = other.ghostty\n".utf8)) != nil)
    }

    @Test func bytesThatAreNotUTF8SurviveUntouched() throws {
        // Latin-1 "é" in a comment: not valid UTF-8.
        let config = Data("# caf".utf8) + Data([0xE9, 0x0A]) + Data("font-size = 14\n".utf8)
        #expect(String(data: config, encoding: .utf8) == nil)
        let updated = try #require(GhosttyDesignConfig.configIncludingFragment(config))
        #expect(updated == config + Data("\n".utf8) + ours)
        // And once included, it's recognised despite those bytes.
        #expect(GhosttyDesignConfig.configIncludingFragment(updated) == nil)
    }

    @Test func includingWritesTheFileOnceAndBacksItUp() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let original = Data("# caf".utf8) + Data([0xE9, 0x0A])
        try original.write(to: config)
        try GhosttyDesignConfig.include(in: config)
        #expect(try Data(contentsOf: config) == original + Data("\n".utf8) + ours)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("config.ghostty-extreme-backup-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: root.appendingPathComponent(backup)) == original)
        // Again: nothing to do, no second backup.
        try GhosttyDesignConfig.include(in: config)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func aMissingConfigIsCreated() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("ghostty/config")
        try GhosttyDesignConfig.include(in: config)
        #expect(try Data(contentsOf: config) == ours)
    }

    @Test func aSymlinkedConfigStaysALink() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("ghostty-config")
        try Data("theme = nord\n".utf8).write(to: target)
        let link = root.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try GhosttyDesignConfig.include(in: link)
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(try Data(contentsOf: target) == Data("theme = nord\n\n".utf8) + ours)
    }

    @Test func aConfigThatCannotBeReadIsLeftAlone() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // A folder where the file should be: it exists, and reading it fails.
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try GhosttyDesignConfig.include(in: config) }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: config.path, isDirectory: &isFolder) && isFolder.boolValue)
    }
}
