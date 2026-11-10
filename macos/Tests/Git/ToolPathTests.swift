import Foundation
import Testing
@testable import Ghostty

/// Finding tools (ToolPath): hits are remembered, misses only for a while, and the slow
/// lookup is never repeated inside that while.
@Suite(.serialized) struct ToolPathTests {
    private func folderWithTool(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return folder
    }

    @Test func aToolInAFolderIsFoundAndRemembered() throws {
        let name = "tool-\(UUID().uuidString)"
        let folder = try folderWithTool(name)
        #expect(ToolPath.find([name], in: [folder.path], thorough: false, locate: nil) == folder.path + "/" + name)
        try FileManager.default.removeItem(at: folder)
        // Remembered, even with nowhere to look.
        #expect(ToolPath.find([name], in: [], thorough: false, locate: nil) == folder.path + "/" + name)
    }

    @Test func aMissIsRememberedForAWhileThenLookedForAgain() throws {
        let name = "tool-\(UUID().uuidString)"
        var asked = 0
        let locate: (String) -> String? = { _ in asked += 1; return nil }
        let start = Date()
        #expect(ToolPath.find([name], in: [], thorough: true, now: start, locate: locate) == nil)
        #expect(ToolPath.find([name], in: [], thorough: true, now: start.addingTimeInterval(1), locate: locate) == nil)
        #expect(asked == 1)
        // Installed since: found once the miss has expired.
        let folder = try folderWithTool(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ToolPath.find([name], in: [folder.path], thorough: true, now: start.addingTimeInterval(2), locate: locate) == nil)
        let later = start.addingTimeInterval(ToolPath.missExpiry + 1)
        #expect(ToolPath.find([name], in: [folder.path], thorough: true, now: later, locate: locate) == folder.path + "/" + name)
    }

    @Test func aQuickMissDoesNotStandInForAThoroughLook() {
        let name = "tool-\(UUID().uuidString)"
        let start = Date()
        #expect(ToolPath.find([name], in: [], thorough: false, now: start, locate: nil) == nil)
        #expect(ToolPath.find([name], in: [], thorough: true, now: start, locate: { _ in "/somewhere/" + name }) == "/somewhere/" + name)
    }

    @Test func theFirstNameFoundWins() throws {
        let first = "tool-\(UUID().uuidString)", second = "tool-\(UUID().uuidString)"
        let folder = try folderWithTool(second)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ToolPath.find([first, second], in: [folder.path], thorough: false, locate: nil) == folder.path + "/" + second)
    }
}
