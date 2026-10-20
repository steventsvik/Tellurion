#if os(macOS)
import AppKit

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
    /// The command the tile was opened with, for agents that can't resume a session.
    var command: String?
    /// The name given to the tile (by a tool, or by renaming it).
    var title: String?
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
    /// Open when Tellurion last quit; reopened at launch.
    var open = true
    var updated = Date()

    init(name: String, folder: String?) {
        self.id = UUID()
        self.name = name
        self.folder = folder
    }
}

enum BoardStore {
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
        guard let data = try? encoder.encode(workspace) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(workspace.id), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// "Board", or "Board 2" when that's taken.
    static func newName(_ base: String = "Board") -> String {
        let taken = Set(all().map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
#endif
