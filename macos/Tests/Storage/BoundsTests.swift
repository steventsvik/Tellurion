import Foundation
import Testing
@testable import Ghostty

/// Ceilings on work whose size the app doesn't choose: what a program writes
/// (ProcessRunner), and files that pile up (StoredFile.removeFiles).
struct BoundsTests {
    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    @Test func outputUnderTheCeilingIsKeptWhole() async {
        let result = await Task.detached { ProcessRunner.run(self.shell("printf 'hello'; printf 'oops' 1>&2"), timeout: 10, maxOutput: 100) }.value
        #expect(result.ok)
        #expect(result.text == "hello")
        #expect(result.errorText == "oops")
        #expect(!result.truncated)
    }

    @Test func outputPastTheCeilingIsCutAndSaidToBe() async {
        // Two megabytes written, a thousand bytes kept; the program still runs to its end.
        let script = "head -c 2000000 /dev/zero | tr '\\0' 'a'; echo done 1>&2"
        let result = await Task.detached { ProcessRunner.run(self.shell(script), timeout: 20, maxOutput: 1000) }.value
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.stdout.count == 1000)
        #expect(result.truncated)
        #expect(result.errorText == "done\n")
    }

    @Test func eachOutputHasItsOwnCeiling() async {
        let script = "head -c 5000 /dev/zero | tr '\\0' 'e' 1>&2; printf 'ok'"
        let result = await Task.detached { ProcessRunner.run(self.shell(script), timeout: 20, maxOutput: 100) }.value
        #expect(result.text == "ok")
        #expect(result.stderr.count == 100)
        #expect(result.truncated)
    }

    @Test func oldFilesGoAndNewOnesAndFoldersStay() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("bounds-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let now = Date()
        let day: TimeInterval = 24 * 3600
        for (name, age) in [("old.md", 20 * day), ("new.md", 2 * day), ("inner/old.md", 20 * day)] {
            let file = folder.appendingPathComponent(name)
            try Data("prompt".utf8).write(to: file)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: folder.appendingPathComponent("inner").path)

        #expect(StoredFile.removeFiles(in: folder, olderThan: 14 * day, now: now) == 1)
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("old.md").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("new.md").path))
        // Only the folder's own files: nothing inside a folder in it is touched.
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("inner/old.md").path))
        // A folder that isn't there is nothing to do, not an error.
        #expect(StoredFile.removeFiles(in: folder.appendingPathComponent("absent"), olderThan: day, now: now) == 0)
    }
}
