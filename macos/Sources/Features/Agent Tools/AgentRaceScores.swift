#if os(macOS)
import Foundation
import os

/// One decided race, as the scoreboard remembers it: who ran, how each one did, and whose
/// work was kept. It holds no prompt beyond a short title, no diffs and no file contents,
/// and it's only ever written to the app's own folder on this Mac.
struct AgentRaceRecord: Codable, Identifiable, Equatable {
    /// Where a contestant stood when the race was decided.
    enum Outcome: String, Codable {
        case finished
        /// Still going, or waiting on the user.
        case working
        case failed
        /// Its terminal was closed, or it never reported.
        case unknown
    }

    struct Entry: Codable, Identifiable, Equatable {
        /// The contestant's id in its race, e.g. "codex-2".
        let id: String
        let agent: String
        /// The model it ran on, when that could be told.
        var model: String?
        /// Whose service ran the model when it wasn't the agent's own ("venice", "ollama").
        var backend: String?
        var outcome: Outcome
        /// From the start of the race until it finished.
        var seconds: Double?
        var files: Int
        var added: Int
        var removed: Int
        /// Whether the project's check passed on its work; nil when there was no result.
        var checkPassed: Bool?

        var kind: VerticalTabAgentKind { VerticalTabAgentKind(id: agent) }
        var name: String {
            let number = id.split(separator: "-").last.map(String.init) ?? ""
            return "\(kind.displayName) \(number)"
        }
    }

    /// The race's id; deciding a race again replaces its record.
    let id: String
    var date: Date
    /// The repository's root folder and its name.
    var root: String
    var project: String
    /// The first line of the task, at most `titleLength` characters. The rest isn't kept.
    var title: String
    var category: AgentRaceCategory
    var entries: [Entry]
    /// The contestant whose changes were kept; nil when the race was cleaned up without one.
    var winner: String?

    static let titleLength = 80

    var winnerEntry: Entry? { entries.first { $0.id == winner } }

    /// A task's first line with its whitespace collapsed, cut to `titleLength`.
    static func title(of task: String) -> String {
        let line = task.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        return line.count > titleLength ? String(line.prefix(titleLength - 1)) + "…" : line
    }
}

/// What's known about one contestant at the moment a race is decided.
struct AgentRaceFacts: Equatable {
    var activity: VerticalTabAgentActivity?
    /// When `activity` last changed.
    var since: Date?
    var model: String?
    var backend: String?
    /// The session transcript, read only for the name of the model.
    var transcriptPath: String?
    var checkPassed: Bool?

    init(activity: VerticalTabAgentActivity? = nil, since: Date? = nil, model: String? = nil, backend: String? = nil,
         transcriptPath: String? = nil, checkPassed: Bool? = nil) {
        self.activity = activity
        self.since = since
        self.model = model
        self.backend = backend
        self.transcriptPath = transcriptPath
        self.checkPassed = checkPassed
    }

    init(info: VerticalTabAgentInfo?, checkPassed: Bool?) {
        self.init(activity: info?.activity, since: info?.since, transcriptPath: info?.transcriptPath, checkPassed: checkPassed)
        if let venice = info?.veniceModel {
            backend = "venice"
            model = AgentRaceScores.modelName(venice)
        } else if let local = info?.localCodex {
            backend = local.provider
            model = AgentRaceScores.modelName(local.model)
        }
    }

    /// With the model taken from the transcript when nothing else gave it. Reads a file.
    func resolvingModel() -> AgentRaceFacts {
        guard model == nil, let transcriptPath else { return self }
        var facts = self
        facts.model = AgentRaceScores.transcriptModel(at: transcriptPath)
        return facts
    }
}

extension AgentRaceRecord {
    /// The record of a race decided at `date`. `facts` and `diffs` are by contestant id; a
    /// contestant missing from either is recorded with what's known.
    init(race: AgentRace, category: AgentRaceCategory, winner: String?, facts: [String: AgentRaceFacts],
         diffs: [String: AgentRaceDiff], date: Date = Date()) {
        let entries = race.contestants.map { contestant -> Entry in
            let known = facts[contestant.id]
            let diff = diffs[contestant.id]
            let outcome: Outcome
            switch known?.activity {
            case .done: outcome = .finished
            case .failed: outcome = .failed
            case .working, .needsPermission, .needsInput: outcome = .working
            case .ready, .none: outcome = .unknown
            }
            let seconds = outcome == .finished ? known?.since.map { max(0, $0.timeIntervalSince(race.created)) } : nil
            return Entry(id: contestant.id, agent: contestant.agent, model: known?.model, backend: known?.backend,
                         outcome: outcome, seconds: seconds, files: diff?.files.count ?? 0,
                         added: diff?.added ?? 0, removed: diff?.removed ?? 0, checkPassed: known?.checkPassed)
        }
        self.init(id: race.id, date: date, root: race.repoRoot, project: race.repoName,
                  title: Self.title(of: race.task), category: category, entries: entries,
                  winner: race.contestants.contains { $0.id == winner } ? winner : nil)
    }

    /// Whether a race cleaned up without a winner is worth remembering: only when someone
    /// finished, since then every result was turned down rather than never looked at.
    var countsWithoutWinner: Bool {
        entries.contains { $0.outcome == .finished }
    }
}

/// The history of decided races, and what it says about which agent wins what.
///
/// The history is one JSON file in the app's folder, newest first, at most `limit` records.
/// The numbers are worked out from it on demand by the static functions below, which take
/// the records as a parameter. Main thread only.
final class AgentRaceScores: ObservableObject {
    static let shared = AgentRaceScores(file: AgentTools.root.appendingPathComponent("race-scores.json"))

    /// How many decided races are remembered.
    static let limit = 500
    static let log = StoredFile.logger("RaceScores")

    @Published private(set) var records: [AgentRaceRecord]
    private let file: URL

    /// A file that's there but can't be read is moved aside by `StoredFile`, never
    /// overwritten; the history then starts empty.
    init(file: URL) {
        self.file = file
        records = StoredFile.loadList(AgentRaceRecord.self, from: file, what: "the race scoreboard", log: Self.log).value ?? []
    }

    func isDecided(_ raceID: String) -> Bool {
        records.contains { $0.id == raceID }
    }

    func record(_ record: AgentRaceRecord) {
        records = Self.adding(record, to: records)
        save()
    }

    /// Forgets one project's races, or all of them when `root` is nil.
    func forget(root: String?) {
        if let root {
            records.removeAll { $0.root == root }
        } else {
            records = []
        }
        save()
    }

    private func save() {
        StoredFile.write(json: records, to: file, what: "the race scoreboard", log: Self.log)
    }

    /// `records` with `record` in it: in place of an older record of the same race, newest
    /// first, and cut to the newest `limit`.
    static func adding(_ record: AgentRaceRecord, to records: [AgentRaceRecord], limit: Int = AgentRaceScores.limit) -> [AgentRaceRecord] {
        var all = records.filter { $0.id != record.id }
        all.append(record)
        all.sort { $0.date > $1.date }
        return Array(all.prefix(max(limit, 0)))
    }

    // MARK: Standings

    /// One agent's (or one agent-and-model's) results over a set of races.
    struct Standing: Identifiable, Equatable {
        let agent: String
        /// nil for the agent as a whole.
        let model: String?
        /// Races it was in against someone different, and how many of those it won.
        var races = 0
        var wins = 0
        /// The median time its finished contestants took, over every race in the set.
        var medianSeconds: Double?

        var id: String { agent + "/" + (model ?? "") }
        var kind: VerticalTabAgentKind { VerticalTabAgentKind(id: agent) }
        var rate: Double { races > 0 ? Double(wins) / Double(races) : 0 }
    }

    /// The records in a project (every project when `root` is nil) and a category (every
    /// category when nil).
    static func filter(_ records: [AgentRaceRecord], root: String?, category: AgentRaceCategory?) -> [AgentRaceRecord] {
        records.filter { (root == nil || $0.root == root) && (category == nil || $0.category == category) }
    }

    /// Wins, races and median time per agent, or per agent and model with `byModel` (then
    /// only for contestants whose model is known).
    ///
    /// A race counts for an agent only when it ran against a different one: three of the same
    /// agent racing each other say nothing about which agent is better. A race without a
    /// winner counts as a race nobody won. Best win rate first.
    static func standings(_ records: [AgentRaceRecord], root: String? = nil, category: AgentRaceCategory? = nil,
                          byModel: Bool = false) -> [Standing] {
        func key(_ entry: AgentRaceRecord.Entry) -> String {
            byModel ? entry.agent + "/" + (entry.model ?? "") : entry.agent
        }
        var standings: [String: Standing] = [:]
        var times: [String: [Double]] = [:]
        for record in filter(records, root: root, category: category) {
            let keys = Set(record.entries.map(key))
            let winner = record.winnerEntry.map(key)
            var seen = Set<String>()
            for entry in record.entries where !byModel || entry.model != nil {
                let key = key(entry)
                var standing = standings[key] ?? Standing(agent: entry.agent, model: byModel ? entry.model : nil)
                if seen.insert(key).inserted, keys.count > 1 {
                    standing.races += 1
                    if winner == key { standing.wins += 1 }
                }
                standings[key] = standing
                if entry.outcome == .finished, let seconds = entry.seconds { times[key, default: []].append(seconds) }
            }
        }
        return standings.map { key, standing in
            var standing = standing
            standing.medianSeconds = median(times[key] ?? [])
            return standing
        }
        .filter { $0.races > 0 }
        .sorted(by: ahead)
    }

    /// The order of a standings list: win rate, then wins, then name, so it never shuffles.
    private static func ahead(_ a: Standing, _ b: Standing) -> Bool {
        if a.rate != b.rate { return a.rate > b.rate }
        if a.wins != b.wins { return a.wins > b.wins }
        return a.id < b.id
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The low end of the Wilson score interval for `wins` out of `races` (95% with the
    /// default `z`): the win rate you can still count on after allowing for how few races
    /// there were. 7 of 9 is about 0.45; 4 of 5 about 0.38; 3 of 5 about 0.23.
    static func wilsonLowerBound(wins: Int, of races: Int, z: Double = 1.96) -> Double {
        guard races > 0 else { return 0 }
        let n = Double(races)
        let p = Double(wins) / n
        let center = p + z * z / (2 * n)
        let margin = z * (p * (1 - p) / n + z * z / (4 * n * n)).squareRoot()
        return max(0, (center - margin) / (1 + z * z / n))
    }

    // MARK: Advice

    /// Who to give a kind of task to, when the history is clear enough to say.
    struct Advice: Equatable {
        let category: AgentRaceCategory
        /// The project the evidence is from; nil when it's from every project.
        let project: String?
        /// The agent that wins this kind of task, and its record.
        let leader: String
        let wins: Int
        let races: Int
        /// A lineup to race: two of the leader and one of the next best, by agent.
        let lineup: [String: Int]

        func count(_ kind: VerticalTabAgentKind) -> Int { lineup[kind.rawValue] ?? 0 }

        /// "For bug fixes in this project, Codex has won 7 of 9."
        var evidence: String {
            let name = VerticalTabAgentKind(id: leader).displayName
            return project != nil
                ? "For \(category.plural) in this project, \(name) has won \(wins) of \(races)."
                : "For \(category.plural) across your projects, \(name) has won \(wins) of \(races)."
        }

        /// "Race 2 Codex + 1 Claude Code?"
        var proposal: String {
            let parts = lineup.filter { $0.value > 0 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.value) \(VerticalTabAgentKind(id: $0.key).displayName)" }
            return "Race \(parts.joined(separator: " + "))?"
        }

        var text: String { evidence + " " + proposal }
    }

    /// Races needed in a category before advice is given: in the project itself, or failing
    /// that across every project.
    static let projectEvidence = 5
    static let overallEvidence = 10
    /// The leader's Wilson lower bound has to reach this as well as beat the others.
    static let leaderFloor = 1.0 / 3

    /// Which agent should get `task` in the repository at `root`, going by the decided races
    /// so far; nil when there isn't enough evidence. Other features can ask this too.
    static func advice(forTask task: String, root: String?) -> Advice? {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return advice(for: AgentRaceCategory.classify(text), root: root, in: shared.records)
    }

    /// The rule, kept conservative so a suggestion means something:
    ///
    /// 1. Only races between different agents in this category count. With `projectEvidence`
    ///    or more of them in this project, the project's races are the evidence, and nothing
    ///    else is consulted even if they're inconclusive. Otherwise it takes
    ///    `overallEvidence` or more across every project.
    /// 2. The leader is the agent with the highest Wilson lower bound on its win rate.
    /// 3. Advice is given only when that lower bound is above the upper median of the other
    ///    agents' plain win rates, and at least `leaderFloor`.
    ///
    /// So 4 of 5 against 1 of 5 is enough, 3 of 5 against 2 of 5 isn't, and across projects
    /// 7 of 10 is enough where 6 of 10 isn't. `racers` are the agents a race can be started
    /// with; a leader that isn't one of them gives no advice.
    static func advice(for category: AgentRaceCategory, root: String?, in records: [AgentRaceRecord],
                       racers: [String] = AgentHandoff.targets.map(\.rawValue)) -> Advice? {
        func contested(_ root: String?) -> [AgentRaceRecord] {
            filter(records, root: root, category: category).filter { Set($0.entries.map(\.agent)).count > 1 }
        }
        var evidence = root.map { contested($0) } ?? []
        var project = evidence.first?.project
        if evidence.count < projectEvidence {
            evidence = contested(nil)
            project = nil
            guard evidence.count >= overallEvidence else { return nil }
        }
        let table = Self.standings(evidence)
        func bound(_ standing: Standing) -> Double { wilsonLowerBound(wins: standing.wins, of: standing.races) }
        let ranked = table.sorted {
            let a = bound($0), b = bound($1)
            return a != b ? a > b : ahead($0, $1)
        }
        guard let leader = ranked.first, racers.contains(leader.agent) else { return nil }
        let rest = ranked.dropFirst()
        let rates = rest.map(\.rate).sorted()
        guard !rates.isEmpty else { return nil }
        let upperMedian = rates[rates.count / 2]
        let lower = bound(leader)
        guard lower > upperMedian, lower >= leaderFloor else { return nil }
        var lineup = [leader.agent: 2]
        if let next = rest.sorted(by: ahead).first(where: { racers.contains($0.agent) }) {
            lineup[next.agent] = 1
        }
        return Advice(category: category, project: project, leader: leader.agent, wins: leader.wins,
                      races: leader.races, lineup: lineup)
    }

    // MARK: Models

    /// How much of the end of a transcript is read to find the model.
    static let transcriptTail = 256 * 1024

    /// The model a session last ran on, from the end of its transcript; nil when the file
    /// can't be read or doesn't say.
    static func transcriptModel(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(transcriptTail) ? size - UInt64(transcriptTail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return model(inTranscript: data)
    }

    /// The latest model named in transcript lines: Claude Code puts it on each reply
    /// (`message.model`), Codex on each turn (`turn_context`'s `payload.model`). A line cut
    /// off at the start of the data is skipped.
    static func model(inTranscript data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = record["type"] as? String
            if type == "assistant", let name = (record["message"] as? [String: Any])?["model"] as? String,
               let model = modelName(name) {
                return model
            }
            if type == "turn_context", let name = (record["payload"] as? [String: Any])?["model"] as? String,
               let model = modelName(name) {
                return model
            }
        }
        return nil
    }

    /// A model's name as it's stored: trimmed, one line, not a placeholder such as
    /// "<synthetic>", and of a sensible length.
    static func modelName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("<"), name.count <= 80,
              !name.contains(where: { $0.isNewline }) else { return nil }
        return name
    }

    // MARK: Checks

    /// Whether the project's check passed on what's in this terminal: true or false once it
    /// has finished, nil while it's running or when there's no result.
    static func checkPassed(_ surface: Ghostty.SurfaceView) -> Bool? {
        MainActor.assumeIsolated {
            guard let state = ProjectChecks.shared.result(for: surface)?.state else { return nil }
            if state == .passed { return true }
            if state == .failed || state == .timedOut { return false }
            return nil
        }
    }

    /// "45s", "4m", "1h 5m".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
    }
}
#endif
