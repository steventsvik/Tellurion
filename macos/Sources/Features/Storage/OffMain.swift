#if os(macOS)
import Foundation
import os

/// The rule that running a program, or reading through folders, never happens on the main
/// thread: there it freezes every window for as long as it takes, and a slow disk or a
/// stuck `git` makes that minutes. Work that must stay off the main thread starts with
/// `OffMain.require()`.
///
/// A call from the main thread is counted by where it came from and logged a few times, and
/// the counts go in the health report (`AppHealth`), so the places still to fix are listed
/// by the app itself. With `traps` on, it stops the app there instead, for tests.
enum OffMain {
    /// Stop at the first call from the main thread instead of counting it.
    static var traps = false

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let log = StoredFile.logger("main thread")

    private struct State {
        var counts: [String: Int] = [:]
        var budget = LogBudget(limit: 5, window: 300)
    }

    /// Call first thing in work that blocks. `what` names the work, as it reads in a report.
    static func require(_ what: StaticString, file: StaticString = #fileID, line: UInt = #line) {
        guard Thread.isMainThread else { return }
        let site = "\(what) (\(file):\(line))"
        if traps { preconditionFailure("On the main thread: \(site)") }
        let skipped = state.withLock { state -> Int? in
            state.counts[site, default: 0] += 1
            return state.budget.take()
        }
        AppHealth.breadcrumb(what)
        if let skipped {
            log.error("On the main thread: \(site, privacy: .public)\(skipped > 0 ? " (and \(skipped) more)" : "", privacy: .public)")
        }
    }

    /// How often each place was reached from the main thread, this launch.
    static var counts: [String: Int] { state.withLock(\.counts) }

    /// Forgets the counts (tests).
    static func reset() {
        state.withLock { $0 = State() }
    }
}
#endif
