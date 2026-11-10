import Foundation
import Testing
@testable import Ghostty

/// The texts the change watcher keeps (RecentTexts): bounded, dropping the oldest.
struct RecentTextsTests {
    @Test func keepsWhatFits() {
        var texts = RecentTexts(limit: 10)
        texts.set("a", "1234")
        texts.set("b", "5678")
        #expect(texts["a"] == "1234")
        #expect(texts["b"] == "5678")
        #expect(texts.total == 8)
    }

    @Test func dropsTheOldestPastTheLimit() {
        var texts = RecentTexts(limit: 10)
        texts.set("a", "1234")
        texts.set("b", "5678")
        texts.set("c", "abcd")
        #expect(texts["a"] == nil)
        #expect(texts["b"] == "5678")
        #expect(texts["c"] == "abcd")
        #expect(texts.total == 8)
    }

    @Test func settingAgainMakesItTheNewest() {
        var texts = RecentTexts(limit: 9)
        texts.set("a", "1234")
        texts.set("b", "5678")
        texts.set("a", "12")
        texts.set("c", "abcd")
        #expect(texts["a"] == "12")
        #expect(texts["b"] == nil)
        #expect(texts.total == 6)
    }

    @Test func oneTextLargerThanTheLimitIsStillKept() {
        var texts = RecentTexts(limit: 4)
        texts.set("a", "12")
        texts.set("big", "123456789")
        #expect(texts["a"] == nil)
        #expect(texts["big"] == "123456789")
        #expect(texts.count == 1)
    }

    @Test func removingGivesTheRoomBack() {
        var texts = RecentTexts(limit: 10)
        texts.set("a", "1234")
        texts.remove("a")
        texts.remove("never there")
        #expect(texts.total == 0)
        texts.set("b", "é")
        #expect(texts.total == 2)
        texts.removeAll()
        #expect(texts.total == 0)
        #expect(texts.count == 0)
    }
}
