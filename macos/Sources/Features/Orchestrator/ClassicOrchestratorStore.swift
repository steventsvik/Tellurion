#if os(macOS)
import Foundation

/// What's kept about a project's orchestrator between launches: its goal, turn limit, engine
/// and which panes were wired with which roles. Its log and whether it was running aren't
/// kept: an orchestrator always comes back stopped.
struct ClassicOrchestratorRecord: Codable, Equatable {
    struct Member: Codable, Equatable {
        /// The pane's terminal id; restored windows keep their panes' ids.
        var pane: String
        var role: String?
    }

    var goal: String?
    var turns: Int?
    /// `HeadlessAgent.Engine`'s name.
    var engine: String?
    var members: [Member]?

    /// The turn limits on offer, as on a board.
    static let turnChoices = [4, 8, 12, 20, 40]

    /// The record as it's safe to use: the file is plain JSON that any program running as
    /// you can write, so texts are cut to size, the limit is one of ours and the engine and
    /// pane ids must be real.
    var checked: ClassicOrchestratorRecord {
        var record = self
        record.goal = goal.map { BoardTeams.clip($0.trimmingCharacters(in: .whitespacesAndNewlines), 4000) }
        if record.goal?.isEmpty == true { record.goal = nil }
        record.turns = turns.flatMap { Self.turnChoices.contains($0) ? $0 : nil }
        record.engine = engine.flatMap { HeadlessAgent.Engine(rawValue: $0)?.rawValue }
        var seen = Set<String>()
        record.members = members?.prefix(BoardTeams.maxAgents).compactMap { member in
            guard let id = UUID(uuidString: member.pane), seen.insert(id.uuidString).inserted else { return nil }
            let role = member.role.map { BoardTeams.clip($0.trimmingCharacters(in: .whitespacesAndNewlines), 60) }
            return Member(pane: id.uuidString, role: role?.isEmpty == false ? role : nil)
        }
        if record.members?.isEmpty == true { record.members = nil }
        return record
    }

    var isEmpty: Bool { goal == nil && turns == nil && engine == nil && members == nil }
}

/// The file the records are in, keyed by project root.
struct ClassicOrchestratorStore {
    private struct File: Codable {
        var projects: [String: ClassicOrchestratorRecord]
    }

    let file: URL
    private static let log = StoredFile.logger("Orchestrator")

    static var standard: ClassicOrchestratorStore {
        ClassicOrchestratorStore(file: AgentTools.root.appendingPathComponent("orchestrators.json"))
    }

    /// Every project's record. A file that can't be read is set aside (see StoredFile.load)
    /// and this starts empty.
    func load() -> [String: ClassicOrchestratorRecord] {
        let loaded = StoredFile.load(File.self, from: file, what: "the orchestrators", log: Self.log)
        return (loaded.value?.projects ?? [:]).mapValues(\.checked).filter { !$0.value.isEmpty }
    }

    @discardableResult
    func save(_ records: [String: ClassicOrchestratorRecord]) -> Bool {
        StoredFile.write(json: File(projects: records.filter { !$0.value.isEmpty }), to: file, what: "the orchestrators", log: Self.log)
    }
}
#endif
