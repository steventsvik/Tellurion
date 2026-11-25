import Foundation
import Testing
@testable import Ghostty

/// A cache with a ceiling (BoundedCache): full, it drops what was used longest ago.
struct BoundedCacheTests {
    @Test func holdsWhatItIsGivenUpToItsLimit() {
        var cache = BoundedCache<String, Int>(limit: 3)
        cache["a"] = 1
        cache["b"] = 2
        cache["c"] = 3
        #expect(cache.count == 3)
        let found = cache["a"], missing = cache["missing"]
        #expect(found == 1)
        #expect(missing == nil)
    }

    @Test func theOneUsedLongestAgoGoesFirst() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache["a"] = 1
        cache["b"] = 2
        // Reading is use: "a" is now the newer of the two.
        let read = cache["a"]
        #expect(read == 1)
        cache["c"] = 3
        #expect(cache.count == 2)
        #expect(cache.peek("b") == nil)
        #expect(cache.peek("a") == 1)
        #expect(cache.peek("c") == 3)
    }

    @Test func peekingIsNotUse() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache["a"] = 1
        cache["b"] = 2
        #expect(cache.peek("a") == 1)
        cache["c"] = 3
        #expect(cache.peek("a") == nil)
    }

    @Test func writingAgainKeepsOneEntry() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache["a"] = 1
        cache["a"] = 2
        cache["b"] = 3
        #expect(cache.count == 2)
        #expect(cache.peek("a") == 2)
    }

    @Test func itNeverGrowsPastItsLimit() {
        var cache = BoundedCache<Int, Int>(limit: 50)
        for number in 0..<10_000 { cache[number] = number }
        #expect(cache.count == 50)
        #expect(Set(cache.keys) == Set(9_950..<10_000))
    }

    @Test func removingAndEmptying() {
        var cache = BoundedCache<String, Int>(limit: 2)
        cache["a"] = 1
        cache["b"] = 2
        cache["a"] = nil
        let removed = cache.removeValue(forKey: "b")
        #expect(removed == 2)
        #expect(cache.isEmpty)
        cache["c"] = 3
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func aLimitBelowOneStillHoldsOne() {
        var cache = BoundedCache<String, Int>(limit: 0)
        cache["a"] = 1
        cache["b"] = 2
        #expect(cache.count == 1)
        #expect(cache.peek("b") == 2)
    }
}
