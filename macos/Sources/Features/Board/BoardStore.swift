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

    /// `chosenAccounts` the way it's saved, by the provider's name; nil for none.
    static func savedAccounts(_ chosen: [BoardAccount.Provider: UUID]?) -> [String: UUID]? {
        chosen.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
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

    var version = BoardStore.currentVersion
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
    /// The boards' logger, shared by the board files that save things.
    static let log = StoredFile.logger("Board")

    static var folder: URL { AgentTools.root.appendingPathComponent("boards", isDirectory: true) }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    /// The newest board file this build writes and fully understands.
    static let currentVersion = 1

    /// A board as it came from its file. `readOnly`: the file is from a newer build, or has
    /// things this build doesn't know, so saving the board would lose them.
    struct Decoded: Equatable {
        var workspace: BoardWorkspace
        var readOnly: Bool
    }

    /// Reads a board file's contents. A card of a kind this build doesn't know is left out and
    /// a group with an unknown role shows as General, rather than the whole board failing to
    /// load; either makes the board read-only, as does a newer `version`.
    static func decode(_ data: Data) throws -> Decoded {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var data = data
        var readOnly = false
        if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var changed = false
            if let cards = object["cards"] as? [[String: Any]] {
                let known = cards.filter { ($0["kind"] as? String).flatMap(BoardCard.Kind.init(rawValue:)) != nil }
                if known.count != cards.count {
                    object["cards"] = known
                    changed = true
                }
            }
            if var groups = object["groups"] as? [[String: Any]] {
                for index in groups.indices where (groups[index]["role"] as? String).flatMap(BoardRole.init(rawValue:)) == nil {
                    groups[index]["role"] = BoardRole.general.rawValue
                    object["groups"] = groups
                    changed = true
                }
            }
            if changed {
                data = try JSONSerialization.data(withJSONObject: object)
                readOnly = true
            }
        }
        let workspace = try decoder.decode(BoardWorkspace.self, from: data)
        return Decoded(workspace: workspace, readOnly: readOnly || workspace.version > currentVersion)
    }

    private static let lock = NSLock()
    private static var readOnlyBoards: Set<UUID> = []
    /// Files already logged as unreadable, by name and size, so listing the boards again
    /// doesn't log them again.
    private static var reported: Set<String> = []

    /// Whether the board is never saved: its file has more in it than this build understands.
    static func isReadOnly(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readOnlyBoards.contains(id)
    }

    /// Every saved board, most recently changed first. A file that can't be decoded is
    /// logged and left where it is.
    static func all() -> [BoardWorkspace] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap(load)
            .sorted { $0.updated > $1.updated }
    }

    private static func load(_ file: URL) -> BoardWorkspace? {
        do {
            let data = try Data(contentsOf: file)
            let decoded = try decode(data)
            guard decoded.workspace.version >= 1 else { return nil }
            lock.lock()
            var isNew = false
            if decoded.readOnly {
                isNew = readOnlyBoards.insert(decoded.workspace.id).inserted
            } else {
                readOnlyBoards.remove(decoded.workspace.id)
            }
            lock.unlock()
            if isNew {
                log.error("Board \(file.lastPathComponent, privacy: .public) has things from a newer Tellurion (version \(decoded.workspace.version)); it opens but isn't saved here")
            }
            return decoded.workspace
        } catch {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            lock.lock()
            let isNew = reported.insert("\(file.lastPathComponent):\(size)").inserted
            lock.unlock()
            if isNew {
                log.error("Couldn't load board \(file.lastPathComponent, privacy: .public): \(StoredFile.summary(of: error), privacy: .public)")
            }
            return nil
        }
    }

    static func save(_ workspace: BoardWorkspace) {
        // A board from a newer build keeps its file as that build wrote it.
        guard !isReadOnly(workspace.id) else { return }
        let encoder = StoredFile.encoder
        encoder.dateEncodingStrategy = .iso8601
        // If this fails the board stays open with its last saved state on disk; the next change tries again.
        StoredFile.write(json: workspace, to: file(workspace.id), what: "board \(workspace.id.uuidString)", log: log, encoder: encoder)
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
