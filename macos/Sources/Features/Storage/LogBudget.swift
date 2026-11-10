#if os(macOS)
import Foundation

/// Lets a few log lines through per stretch of time and counts the rest, for things that
/// text printed in a terminal can set off as often as it likes.
struct LogBudget {
    let limit: Int
    let window: TimeInterval
    private var windowStart = Date.distantPast
    private var used = 0
    private var skipped = 0

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// Nil when this one shouldn't be logged; otherwise how many were skipped since the
    /// last one that was.
    mutating func take(now: Date = Date()) -> Int? {
        if now.timeIntervalSince(windowStart) >= window {
            windowStart = now
            used = 0
        }
        guard used < limit else {
            skipped += 1
            return nil
        }
        used += 1
        defer { skipped = 0 }
        return skipped
    }
}
#endif
