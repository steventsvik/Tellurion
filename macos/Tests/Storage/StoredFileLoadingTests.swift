import Foundation
import Testing
@testable import Ghostty

/// Reading Tellurion's own files: a file that's there but unreadable is moved aside rather
/// than treated as missing, so the next save can't replace it.
struct StoredFileLoadingTests {
    private let log = StoredFile.logger("Tests")

    private struct Item: Codable, Equatable {
        var name: String
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func copies(of file: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(file.lastPathComponent + ".unreadable-") }.sorted()
    }

    @Test func aMissingFileIsMissing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        guard case .missing = StoredFile.load([Item].self, from: file, what: "test", log: log) else {
            Issue.record("expected missing")
            return
        }
        #expect(try copies(of: file).isEmpty)
    }

    @Test func aGoodFileLoads() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        try Data(#"[{"name":"a"},{"name":"b"}]"#.utf8).write(to: file)
        #expect(StoredFile.load([Item].self, from: file, what: "test", log: log).value == [Item(name: "a"), Item(name: "b")])
        #expect(try copies(of: file).isEmpty)
    }

    @Test func anUnreadableFileIsMovedAsideWithItsContents() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        let damaged = Data(#"[{"name":"a"},{"na"#.utf8)
        try damaged.write(to: file)
        guard case .unreadable = StoredFile.load([Item].self, from: file, what: "test", log: log) else {
            Issue.record("expected unreadable")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let kept = try copies(of: file)
        #expect(kept.count == 1)
        let name = try #require(kept.first)
        #expect(try Data(contentsOf: root.appendingPathComponent(name)) == damaged)
    }

    @Test func onlyTheNewestFewCopiesAreKept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        for n in 0..<(StoredFile.unreadableCopiesKept + 3) {
            try Data("bad \(n)".utf8).write(to: file)
            StoredFile.setAside(file, what: "test", log: log, stamp: "20250101-00000\(n)")
        }
        try Data("bad last".utf8).write(to: file)
        StoredFile.setAside(file, what: "test", log: log, stamp: "20250101-000009")
        let kept = try copies(of: file)
        #expect(kept.count == StoredFile.unreadableCopiesKept)
        #expect(kept.last == "items.json.unreadable-20250101-000009")
        #expect(!kept.contains("items.json.unreadable-20250101-000000"))
    }

    @Test func twoCopiesInTheSameSecondAreBothKept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        try Data("one".utf8).write(to: file)
        StoredFile.setAside(file, what: "test", log: log, stamp: "20250101-000000")
        try Data("two".utf8).write(to: file)
        StoredFile.setAside(file, what: "test", log: log, stamp: "20250101-000000")
        #expect(try copies(of: file) == ["items.json.unreadable-20250101-000000", "items.json.unreadable-20250101-000000-2"])
    }

    @Test func aListSkipsItemsItCannotDecodeAndKeepsACopy() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        let mixed = Data(#"[{"name":"a"},{"title":"no name"},7,{"name":"b"}]"#.utf8)
        try mixed.write(to: file)
        #expect(StoredFile.loadList(Item.self, from: file, what: "test", log: log).value == [Item(name: "a"), Item(name: "b")])
        // The file stays, and a copy of it as it was is beside it.
        #expect(try Data(contentsOf: file) == mixed)
        #expect(try copies(of: file).count == 1)
    }

    @Test func aListWithNothingWrongKeepsNoCopy() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("items.json")
        try Data(#"[{"name":"a"}]"#.utf8).write(to: file)
        #expect(StoredFile.loadList(Item.self, from: file, what: "test", log: log).value == [Item(name: "a")])
        #expect(try copies(of: file).isEmpty)
    }

    @Test func aLossyArrayCountsWhatItSkipped() throws {
        let list = try JSONDecoder().decode(LossyArray<Item>.self, from: Data(#"[1,{"name":"a"},null,"x"]"#.utf8))
        #expect(list.elements == [Item(name: "a")])
        #expect(list.skipped == 3)
    }

    @Test func aDecodeFailureIsSummarizedWithoutTheContents() {
        do {
            _ = try JSONDecoder().decode([Item].self, from: Data(#"[{"name":"a"},{"name":5}]"#.utf8))
            Issue.record("expected a failure")
        } catch {
            let summary = StoredFile.summary(of: error)
            #expect(summary.contains("[1].name"))
            #expect(!summary.contains("5"))
        }
    }
}
