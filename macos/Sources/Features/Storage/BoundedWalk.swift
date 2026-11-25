#if os(macOS)
import Foundation

/// A walk through every file under a folder that stops when it has seen enough or taken
/// long enough. The folders these walks read (agents' session histories, a project) are as
/// big as the user's habits make them, and the app doesn't get to wait on that.
enum BoundedWalk {
    struct Limits {
        /// Files and folders looked at.
        var entries: Int
        var seconds: TimeInterval

        /// A user's whole history of agent sessions, read in the background for a window
        /// that's waiting for it: generous, but an end.
        static let history = Limits(entries: 400_000, seconds: 20)
        /// Looking for one file by its name, for something that asks again soon.
        static let lookup = Limits(entries: 100_000, seconds: 2)
    }

    private static let log = StoredFile.logger("walk")

    /// Calls `visit` with each file and folder under `root` until it returns false, the walk
    /// ends, or a limit is reached. Returns whether the walk got to its end or was told to
    /// stop; false means it was cut short by a limit, which is logged as `what`.
    @discardableResult
    static func each(under root: URL, keys: [URLResourceKey] = [], options: FileManager.DirectoryEnumerationOptions = [],
                     limits: Limits, what: StaticString, now: () -> Date = Date.init, _ visit: (URL) -> Bool) -> Bool {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else { return true }
        let deadline = now().addingTimeInterval(limits.seconds)
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            // The clock is only read now and then: asking it for every file would cost more
            // than the walk.
            if seen > limits.entries || (seen % 256 == 0 && now() >= deadline) {
                log.error("Stopped \(what, privacy: .public) after \(seen, privacy: .public) entries: too many, or too slow")
                return false
            }
            if !visit(url) { return true }
        }
        return true
    }
}
#endif
