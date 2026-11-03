import Foundation

/// What today's Venice use has cost, from the balance Venice reports with each answer. It's the
/// account's real figure rather than an estimate, so it counts anything else using the same key
/// too, and it lags by one request: each answer reports the balance from before that request.
struct VeniceSpending: Codable, Equatable {
    let day: String
    var startBalance: Double
    var balance: Double

    var spent: Double { max(0, startBalance - balance) }

    /// A new reading. A balance that goes up is money added, which isn't spending less.
    static func updated(_ current: VeniceSpending?, balance: Double, day: String) -> VeniceSpending {
        guard var next = current, next.day == day else {
            return VeniceSpending(day: day, startBalance: balance, balance: balance)
        }
        if balance > next.balance { next.startBalance += balance - next.balance }
        next.balance = balance
        return next
    }
}

/// Keeps the day's spending and the limit, for the proxy to check before each model request.
final class VeniceSpendMeter: @unchecked Sendable {
    static let shared = VeniceSpendMeter()
    static let defaultLimit = 5.0

    private static let spendingKey = "VeniceSpending"
    private static let limitKey = "VeniceDailyLimit"

    private let lock = NSLock()
    private var stored: VeniceSpending?
    /// On any thread, with today's figures.
    var onChange: (@Sendable (VeniceSpending) -> Void)?

    private init() {
        stored = UserDefaults.standard.data(forKey: Self.spendingKey)
            .flatMap { try? JSONDecoder().decode(VeniceSpending.self, from: $0) }
    }

    /// Dollars a day. Zero means no limit.
    var limit: Double {
        get { UserDefaults.standard.object(forKey: Self.limitKey) as? Double ?? Self.defaultLimit }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Self.limitKey) }
    }

    /// Today's, or nil if nothing has been used yet today.
    var today: VeniceSpending? {
        lock.withLock { stored?.day == Self.dayNow ? stored : nil }
    }

    var overLimit: Bool { Self.isOver(today, limit: limit) }

    static func isOver(_ spending: VeniceSpending?, limit: Double) -> Bool {
        limit > 0 && (spending?.spent ?? 0) >= limit
    }

    func record(balance: Double) {
        let next = lock.withLock {
            stored = VeniceSpending.updated(stored, balance: balance, day: Self.dayNow)
            return stored
        }
        guard let next else { return }
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.spendingKey) }
        onChange?(next)
    }

    /// What an agent or chat is told when the day's limit stops a request.
    var limitMessage: String {
        "Today's Venice spending limit of $\(String(format: "%.2f", limit)) is reached. Raise it in Tools → Local models in Tellurion, or wait until tomorrow."
    }

    private static var dayNow: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
