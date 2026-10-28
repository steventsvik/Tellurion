import Foundation
import Testing
@testable import Ghostty

/// Tellurion's own files: written with their folder made, and a failed write reported (by
/// returning false and logging) rather than dropped.
struct StoredFileTests {
    private let log = StoredFile.logger("Tests")

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writingMakesTheFolderAndReplacesTheFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a/b/presets.json")
        #expect(StoredFile.write(json: ["b": 2, "a": 1], to: file, what: "test", log: log))
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
        #expect(StoredFile.write(Data("x".utf8), to: file, what: "test", log: log))
        #expect(try Data(contentsOf: file) == Data("x".utf8))
    }

    @Test func aWriteThatFailsSaysSo() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the folder should be: neither the folder nor the file can be made.
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        #expect(!StoredFile.write(Data("x".utf8), to: blocker.appendingPathComponent("file.json"), what: "test", log: log))
    }

    @Test func removingAFileThatIsntThereIsFine() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("gone.json")
        StoredFile.remove(file, what: "test", log: log)
        try Data().write(to: file)
        StoredFile.remove(file, what: "test", log: log)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
