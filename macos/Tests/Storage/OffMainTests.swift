import Foundation
import Testing
@testable import Ghostty

/// The rule that blocking work stays off the main thread (OffMain): a call from the main
/// thread is counted by where it came from; one from anywhere else passes unnoticed.
@Suite(.serialized) struct OffMainTests {
    @Test func offTheMainThreadNothingIsCounted() async {
        OffMain.reset()
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                OffMain.require("a test's work")
                done.resume()
            }
        }
        #expect(OffMain.counts.isEmpty)
    }

    @MainActor @Test func onTheMainThreadItIsCountedByPlace() {
        OffMain.reset()
        for _ in 0..<3 { OffMain.require("a test's work") }
        OffMain.require("other work")
        let counts = OffMain.counts
        #expect(counts.count == 2)
        #expect(counts.values.sorted() == [1, 3])
        #expect(counts.keys.contains { $0.hasPrefix("a test's work (") && $0.contains("OffMainTests.swift:") })
        #expect(AppHealth.snapshot.verdict == .fine)
        OffMain.reset()
        #expect(OffMain.counts.isEmpty)
    }
}
