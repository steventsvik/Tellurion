#if os(macOS)
import AppKit
import OSLog

/// One terminal on a board: where it sits, and what to start in it again after a relaunch.
struct BoardTile: Codable, Identifiable, Equatable {
    /// The pane's surface id; a restored tile keeps it.
    let id: UUID
    var frame: CGRect
    var cwd: String?
    /// The agent that ran in it (`VerticalTabAgentKind` raw value), if any.
    var agent: String?
    /// The agent's session id, for `claude --resume` and `codex resume`.
    var session: String?
    /// The command the tile was opened with, kept for the record. A restored tile never
    /// types it: see `BoardAgent.resumeCommand`.
    var command: String?
    /// The name given to the tile (by a tool, or by renaming it).
    var title: String?
    /// The account profiles its agents use (provider → profile id; see BoardAccounts).
    var accounts: [String: UUID]?

    /// `accounts` by provider, leaving out any this build doesn't know.
    var chosenAccounts: [BoardAccount.Provider: UUID] {
        Dictionary(uniqueKeysWithValues: (accounts ?? [:]).compactMap { key, value in
            BoardAccount.Provider(rawValue: key).map { ($0, value) }
        })
    }
}

/// A board: its tiles, where you were looking, and its window. Saved as versioned JSON in
/// ~/.ghostty-extreme/boards/<id>.json on every change.
struct BoardWorkspace: Codable, Identifiable, Equatable {
    struct Camera: Codable, Equatable {
        /// The top-left corner of the visible part of the board, in board points.
        var origin: CGPoint
        var zoom: CGFloat
    }

    var version = 1
    let id: UUID
    var name: String
    /// The folder new terminals and agents start in.
    var folder: String?
    var tiles: [BoardTile] = []
    var camera: Camera?
    var windowFrame: CGRect?
    /// Each project's color on this board (an index into BoardProjects.palette).
    var colors: [String: Int]?
    var sketches: [BoardSketch]?
    var cards: [BoardCard]?
    /// Leads and the tiles they run (see BoardTeams).
    var teams: [BoardTeam]?
    /// Groups you made (see BoardNamedGroups).
    var groups: [BoardGroupNode]?
    /// Big text on the board (see BoardLabels).
    var labels: [BoardLabelNode]?
    /// Ink drawn on the board (see BoardInk).
    var ink: [BoardInkStroke]?
    /// Tiles that left for classic windows with the switch to Classic, and where they were. Their
    /// ink, groups and wires stay with the board until they come back (see BoardController.releaseForClassic).
    var released: [BoardTile]?
    /// Open when Tellurion last quit; reopened at launch.
    var open = true
    var updated = Date()

    init(name: String, folder: String?) {
        self.id = UUID()
        self.name = name
        self.folder = folder
    }

    /// The board with its released tiles forgotten, as BoardController.forgetReleased does for
    /// an open one: ink anchored to them, their group memberships and team wires go, and so do
    /// groups left empty. For a board that isn't open when every classic terminal has come back.
    func forgettingReleased() -> BoardWorkspace {
        guard let gone = released, !gone.isEmpty else { return self }
        var workspace = self
        workspace.released = nil
        let present = Set(tiles.map(\.id))
        let nodes = present.union((sketches ?? []).map(\.id)).union((cards ?? []).map(\.id)).union((labels ?? []).map(\.id))
        workspace.ink = ink.map { strokes in strokes.filter { $0.anchor.map(nodes.contains) ?? true } }
        var groups = self.groups ?? []
        for index in groups.indices { groups[index].tiles.removeAll { !present.contains($0) } }
        groups.removeAll { $0.tiles.isEmpty }
        workspace.groups = groups.isEmpty ? nil : groups
        let groupIDs = Set(groups.map(\.id))
        workspace.teams = teams.map { teams in
            teams.map { team in
                var team = team
                team.members.removeAll { !present.contains($0.tile) }
                team.groups.removeAll { key in BoardTeams.groupID(key).map { !groupIDs.contains($0) } ?? false }
                return team
            }
        }
        return workspace
    }
}

enum BoardStore {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Board")

    static var folder: URL { AgentTools.root.appendingPathComponent("boards", isDirectory: true) }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    /// Every saved board, most recently changed first.
    static func all() -> [BoardWorkspace] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(BoardWorkspace.self, from: Data(contentsOf: $0)) }
            .filter { $0.version == 1 }
            .sorted { $0.updated > $1.updated }
    }

    static func save(_ workspace: BoardWorkspace) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(workspace)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file(workspace.id), options: .atomic)
        } catch {
            // The board stays open with its last saved state on disk; the next change tries again.
            log.error("Couldn't save board \(workspace.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// "Board", or "Board 2" when that's taken.
    static func newName(_ base: String = "Board") -> String {
        uniqueName(base, taken: Set(all().map(\.name)))
    }

    /// `base`, or "base 2" (3, …) when that's taken.
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
#endif
