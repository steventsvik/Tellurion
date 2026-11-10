import Foundation
import Testing
@testable import Ghostty

/// Rate-limited logging (LogBudget): a few lines per window, the rest counted.
struct LogBudgetTests {
    @Test func letsAFewThroughThenCountsTheRest() {
        var budget = LogBudget(limit: 2, window: 60)
        let start = Date()
        #expect(budget.take(now: start) == 0)
        #expect(budget.take(now: start.addingTimeInterval(1)) == 0)
        #expect(budget.take(now: start.addingTimeInterval(2)) == nil)
        #expect(budget.take(now: start.addingTimeInterval(3)) == nil)
        // A new window: logging again, and saying how many were skipped.
        #expect(budget.take(now: start.addingTimeInterval(61)) == 2)
        #expect(budget.take(now: start.addingTimeInterval(62)) == 0)
    }
}
