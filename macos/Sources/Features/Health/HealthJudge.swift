#if os(macOS)
import Foundation

/// How much memory the app held at a moment.
struct HealthSample: Codable, Equatable {
    var time: Date
    var footprint: UInt64
}

/// What the app's memory use amounts to.
enum HealthVerdict: Equatable {
    case fine
    /// Not much yet, but it has gone up in every part of the last stretch: something is
    /// collecting without end.
    case climbing(by: UInt64, over: TimeInterval)
    /// More than an app like this should need.
    case high(UInt64)
    /// Enough that macOS will soon run out for everything else.
    case critical(UInt64)

    /// 0 fine, 1 worth a warning, 2 act now.
    var severity: Int {
        switch self {
        case .fine: return 0
        case .climbing, .high: return 1
        case .critical: return 2
        }
    }

    var name: String {
        switch self {
        case .fine: return "fine"
        case .climbing: return "climbing"
        case .high: return "high"
        case .critical: return "critical"
        }
    }
}

/// Judges the app's memory from its recent samples. The limits follow the Mac: a quarter of
/// its memory is a lot for a terminal, half leaves too little for the agents it's running.
struct HealthJudge {
    static let gigabyte: UInt64 = 1 << 30

    let warning: UInt64
    let critical: UInt64
    /// Growth that counts as climbing, and the stretch it's measured over.
    var climb: UInt64 = HealthJudge.gigabyte
    var climbWindow: TimeInterval = 300
    /// The stretch is cut into this many parts, each of which must hold more than the last.
    var climbParts = 5

    init(physicalMemory: UInt64) {
        warning = max(4 * Self.gigabyte, physicalMemory / 4)
        critical = max(8 * Self.gigabyte, physicalMemory / 2)
    }

    /// `samples` oldest first.
    func verdict(_ samples: [HealthSample]) -> HealthVerdict {
        guard let last = samples.last else { return .fine }
        if last.footprint >= critical { return .critical(last.footprint) }
        if last.footprint >= warning { return .high(last.footprint) }
        if let growth = climbing(samples) { return .climbing(by: growth, over: climbWindow) }
        return .fine
    }

    /// How much the app grew over the last stretch, if it grew through all of it.
    private func climbing(_ samples: [HealthSample]) -> UInt64? {
        guard let last = samples.last else { return nil }
        let start = last.time.addingTimeInterval(-climbWindow)
        let recent = samples.filter { $0.time >= start }
        // The samples have to cover the stretch: a minute of growth after launch is loading.
        guard let first = recent.first, last.time.timeIntervalSince(first.time) >= climbWindow * 0.9,
              last.footprint > first.footprint, last.footprint - first.footprint >= climb else { return nil }
        let part = climbWindow / Double(climbParts)
        var means: [Double] = []
        for index in 0..<climbParts {
            let from = start.addingTimeInterval(Double(index) * part)
            let to = index == climbParts - 1 ? Date.distantFuture : from.addingTimeInterval(part)
            let inside = recent.filter { $0.time >= from && $0.time < to }
            guard !inside.isEmpty else { return nil }
            means.append(inside.reduce(0) { $0 + Double($1.footprint) } / Double(inside.count))
        }
        for index in 1..<means.count where means[index] <= means[index - 1] { return nil }
        return last.footprint - first.footprint
    }

    /// "12.4 GB", as the app says it.
    static func size(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1000 { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f GB", megabytes / 1024)
    }
}

/// Notices the main thread not answering. A ping is sent to it on every tick; while one is
/// still unanswered, no other is sent, and how long it waited is the length of the stall.
struct StallWatch {
    /// Shorter waits than this aren't stalls: a busy moment, a window being laid out.
    var threshold: TimeInterval = 2
    private var sent: Date?

    /// Whether to send a ping now (none is waiting).
    mutating func tick(now: Date) -> Bool {
        guard sent == nil else { return false }
        sent = now
        return true
    }

    /// The main thread answered at `now`: how long it stalled, if it did.
    mutating func answered(now: Date) -> TimeInterval? {
        guard let sent else { return nil }
        self.sent = nil
        let waited = now.timeIntervalSince(sent)
        return waited >= threshold ? waited : nil
    }

    /// How long the main thread has been stalled as of `now`, if it is.
    func waiting(now: Date) -> TimeInterval? {
        guard let sent else { return nil }
        let waited = now.timeIntervalSince(sent)
        return waited >= threshold ? waited : nil
    }
}

/// A time the main thread didn't answer.
struct HealthStall: Codable, Equatable {
    var time: Date
    var seconds: Double
    /// The work the app had last said it was starting. Names of the app's own steps only.
    var during: String?
}

/// What a health report holds: numbers about the app, and nothing from the user's
/// terminals, files or folders.
struct HealthReport: Codable {
    var written: Date
    var reason: String
    var version: String
    var macOS: String
    var model: String
    var physicalMemory: UInt64
    var uptime: TimeInterval
    var verdict: String
    var footprint: UInt64
    var samples: [HealthSample]
    var stalls: [HealthStall]
    /// How many entries each of the app's caches holds.
    var caches: [String: Int]
    /// Blocking work that was reached from the main thread, and how often.
    var mainThreadWork: [String: Int]
}
#endif
