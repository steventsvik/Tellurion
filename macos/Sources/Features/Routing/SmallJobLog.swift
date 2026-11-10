#if os(macOS)
import Combine
import Foundation

/// The last few small jobs and where each ran: the kind, the model, how long it took and why
/// it was sent on. Never the prompt or the answer.
@MainActor
final class SmallJobLog: ObservableObject {
    static let shared = SmallJobLog()
    /// How many it keeps.
    nonisolated static let limit = 50

    /// Newest last.
    @Published private(set) var entries: [SmallJobOutcome] = []

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "SmallJobs.log") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([SmallJobOutcome].self, from: data) {
            entries = Array(saved.suffix(Self.limit))
        }
    }

    func record(_ outcome: SmallJobOutcome) {
        entries = Array((entries + [outcome]).suffix(Self.limit))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: key)
    }

    /// "Last 20: 17 on this Mac, 3 sent on to Claude Code". Nil before the first job.
    nonisolated static func summary(_ entries: [SmallJobOutcome], last: Int = 20) -> String? {
        let recent = entries.suffix(last)
        guard !recent.isEmpty else { return nil }
        var parts: [String] = []
        let local = recent.filter(\.isLocal).count
        if local > 0 { parts.append("\(local) on this Mac") }
        // Who the others went to, in the order they first did.
        var names: [String] = []
        var sent: [String: Int] = [:]
        for outcome in recent where !outcome.isLocal {
            if sent[outcome.fallbackName] == nil { names.append(outcome.fallbackName) }
            sent[outcome.fallbackName, default: 0] += 1
        }
        parts += names.map { "\(sent[$0] ?? 0) sent on to \($0)" }
        return "Last \(recent.count): " + parts.joined(separator: ", ")
    }

    /// Why the latest job that was sent on was: "it took too long (qwen3:4b)".
    nonisolated static func lastReason(_ entries: [SmallJobOutcome], last: Int = 20) -> String? {
        guard let outcome = entries.suffix(last).last(where: { !$0.isLocal }), let reason = outcome.reason else { return nil }
        return outcome.model.map { "\(reason) (\($0))" } ?? reason
    }
}
#endif
