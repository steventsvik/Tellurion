#if os(macOS)
import Foundation

/// A dictionary that never holds more than `limit` entries: when it's full, the entry that
/// was read or written longest ago goes. For the app's lookups keyed by something the user
/// keeps making more of (folders, sessions, branches), which otherwise only ever grow.
///
/// Reading counts as use, so the getter is mutating; keep it in a `var`. Dropping the oldest
/// looks at every entry, which is fine for the few hundred these hold.
struct BoundedCache<Key: Hashable, Value> {
    let limit: Int
    private var entries: [Key: (value: Value, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var keys: [Key] { Array(entries.keys) }
    var values: [Value] { entries.values.map(\.value) }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let entry = entries[key] else { return nil }
            clock += 1
            entries[key] = (entry.value, clock)
            return entry.value
        }
        set {
            guard let newValue else {
                entries[key] = nil
                return
            }
            clock += 1
            entries[key] = (newValue, clock)
            if entries.count > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                entries[oldest] = nil
            }
        }
    }

    /// The value without counting it as use, for code that only looks (a `let`, a report).
    func peek(_ key: Key) -> Value? { entries[key]?.value }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        entries.removeValue(forKey: key)?.value
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
#endif
