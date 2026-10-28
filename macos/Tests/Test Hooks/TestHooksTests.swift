import Foundation
import Testing
@testable import Ghostty

/// The test log that test copies write to (`GHOSTTY_EXTREME_TEST_LOG`): every writer appends
/// through `TestHooks.note`, so lines from different hooks never overwrite each other.
@Suite(.serialized)
struct TestHooksTests {
    @Test func notesAppendLinesToTheLog() throws {
        // Release-style builds have no test log at all.
        guard TestHooks.available else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("test-log-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let previous = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_LOG"]
        setenv("GHOSTTY_EXTREME_TEST_LOG", path, 1)
        defer {
            if let previous { setenv("GHOSTTY_EXTREME_TEST_LOG", previous, 1) } else { unsetenv("GHOSTTY_EXTREME_TEST_LOG") }
        }
        #expect(TestHooks.log == path)
        TestHooks.note("first")
        TestHooks.note("setup: ok")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "first\nsetup: ok\n")
    }
}
