import Foundation
import Testing
@testable import Ghostty

/// A walk through a folder with an end (BoundedWalk), and a log that's cut when it has
/// grown too large (LocalhostAddress.trimLog).
struct BoundedWalkTests {
    private func folder(files: Int) throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("walk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("deep/er"), withIntermediateDirectories: true)
        for number in 0..<files {
            let name = number % 2 == 0 ? "file-\(number).jsonl" : "deep/er/file-\(number).jsonl"
            try Data().write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    @Test func aSmallFolderIsWalkedToItsEnd() throws {
        let root = try folder(files: 10)
        defer { try? FileManager.default.removeItem(at: root) }
        var files = 0
        let finished = BoundedWalk.each(under: root, limits: .init(entries: 1000, seconds: 10), what: "a test") { url in
            if url.pathExtension == "jsonl" { files += 1 }
            return true
        }
        #expect(finished)
        #expect(files == 10)
    }

    @Test func itStopsAtItsLimitOfEntries() throws {
        let root = try folder(files: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        var visited = 0
        let finished = BoundedWalk.each(under: root, limits: .init(entries: 20, seconds: 10), what: "a test") { _ in
            visited += 1
            return true
        }
        #expect(!finished)
        #expect(visited == 20)
    }

    @Test func itStopsWhenItsTimeIsUp() throws {
        let root = try folder(files: 600)
        defer { try? FileManager.default.removeItem(at: root) }
        // A clock that jumps an hour once the walk is under way.
        let start = Date()
        var asked = 0
        var visited = 0
        let finished = BoundedWalk.each(under: root, limits: .init(entries: 100_000, seconds: 5), what: "a test", now: {
            asked += 1
            return asked == 1 ? start : start.addingTimeInterval(3600)
        }, { _ in
            visited += 1
            return true
        })
        #expect(!finished)
        #expect(visited < 600)
    }

    @Test func beingToldToStopIsNotBeingCutShort() throws {
        let root = try folder(files: 10)
        defer { try? FileManager.default.removeItem(at: root) }
        var visited = 0
        let finished = BoundedWalk.each(under: root, limits: .init(entries: 1000, seconds: 10), what: "a test") { _ in
            visited += 1
            return visited < 3
        }
        #expect(finished)
        #expect(visited == 3)
    }

    @Test func aFolderThatIsNotThereIsAnEmptyWalk() {
        var visited = 0
        let absent = URL(fileURLWithPath: "/tmp/absent-\(UUID().uuidString)")
        #expect(BoundedWalk.each(under: absent, limits: .lookup, what: "a test") { _ in visited += 1; return true })
        #expect(visited == 0)
    }

    @Test func aHugeLogIsCutToItsEndAndSaysSo() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = (0..<1000).map { "line \($0) of the server's output" }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: file)
        // Under the limit: left alone.
        #expect(!LocalhostAddress.trimLog(at: file.path, over: 1_000_000, keeping: 1000))
        #expect(try Data(contentsOf: file).count == lines.utf8.count)

        #expect(LocalhostAddress.trimLog(at: file.path, over: 10_000, keeping: 1000))
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let kept = text.split(separator: "\n").map(String.init)
        #expect(kept.first == "[Tellurion dropped earlier output to keep this log small]")
        // Whole lines only, ending with the last one written.
        #expect(kept.dropFirst().allSatisfy { $0.hasPrefix("line ") && $0.hasSuffix(" of the server's output") })
        #expect(kept.last == "line 999 of the server's output")
        #expect(text.utf8.count <= 1000 + 64)
        // Appending carries on at the new end, as the runner does.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("after\n".utf8))
        try handle.close()
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasSuffix("line 999 of the server's output\nafter\n"))
    }

    @Test func aLogThatIsNotThereIsNothingToCut() {
        #expect(!LocalhostAddress.trimLog(at: "/tmp/absent-\(UUID().uuidString).log"))
    }
}
