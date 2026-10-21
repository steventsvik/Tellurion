#if os(macOS)
import AppIntents
import AppKit
import UniformTypeIdentifiers

// Boards and sketches for Shortcuts, Spotlight and Siri: open a board, start one in a
// folder, launch agents on it, start a sketch (from pictures, too), get a sketch as a
// picture, and arrange a board by project.

// MARK: - Entities

struct BoardEntity: AppEntity {
    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Folder")
    var folder: String?

    @Property(title: "Open")
    var isOpen: Bool

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Board") }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: folder.map { "\(($0 as NSString).abbreviatingWithTildeInPath)" },
                              image: .init(systemName: "square.grid.3x3.square"))
    }

    static var defaultQuery = BoardQuery()

    init(_ workspace: BoardWorkspace, open: Bool) {
        id = workspace.id
        name = workspace.name
        folder = workspace.folder
        isOpen = open
    }
}

struct BoardQuery: EntityStringQuery, EnumerableEntityQuery {
    @MainActor
    private func all() -> [BoardEntity] {
        let open = Set(BoardController.all.map(\.workspace.id))
        return BoardStore.all().map { BoardEntity($0, open: open.contains($0.id)) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BoardEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [BoardEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func allEntities() async throws -> [BoardEntity] { all() }

    @MainActor
    func suggestedEntities() async throws -> [BoardEntity] { all() }
}

struct SketchEntity: AppEntity {
    let id: UUID

    @Property(title: "Title")
    var title: String

    @Property(title: "Board")
    var board: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Sketch") }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(board)", image: .init(systemName: "scribble.variable"))
    }

    static var defaultQuery = SketchQuery()

    init(_ sketch: BoardSketch, board: String) {
        id = sketch.id
        title = sketch.title
        self.board = board
    }
}

struct SketchQuery: EntityStringQuery, EnumerableEntityQuery {
    /// Sketches on open boards (their drawings are live there).
    @MainActor
    static func open() -> [(sketch: BoardSketch, board: BoardController)] {
        BoardController.all.flatMap { board in board.model.sketches.map { ($0, board) } }
    }

    @MainActor
    private func all() -> [SketchEntity] {
        Self.open().map { SketchEntity($0.sketch, board: $0.board.model.name) }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SketchEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SketchEntity] {
        all().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func allEntities() async throws -> [SketchEntity] { all() }

    @MainActor
    func suggestedEntities() async throws -> [SketchEntity] { all() }
}

// MARK: - Helpers

enum BoardIntents {
    @MainActor
    static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// The board an intent works on: the one asked for (opened if needed), else the front
    /// board, else a new one.
    @MainActor
    static func board(_ entity: BoardEntity?) throws -> BoardController {
        guard let ghostty else { throw GhosttyIntentError.appUnavailable }
        if let entity {
            if let open = BoardController.all.first(where: { $0.workspace.id == entity.id }) { return open }
            guard let saved = BoardStore.all().first(where: { $0.id == entity.id }) else { throw GhosttyIntentError.boardNotFound }
            Board.reopen(ghostty, saved)
            if let open = BoardController.all.first(where: { $0.workspace.id == entity.id }) { return open }
            throw GhosttyIntentError.boardNotFound
        }
        return BoardController.front ?? Board.newBoard(ghostty)
    }

    @MainActor
    static func bringForward(_ board: BoardController) {
        NSApp.activate(ignoringOtherApps: true)
        board.show()
    }
}

// MARK: - Intents

struct OpenBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Board"
    static var description = IntentDescription("Opens a board, or brings it forward.")
    static var openAppWhenRun = true

    @Parameter(title: "Board")
    var board: BoardEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else { throw GhosttyIntentError.permissionDenied }
        BoardIntents.bringForward(try BoardIntents.board(board))
        return .result()
    }
}

@available(macOS 15.0, *)
struct NewBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "New Board"
    static var description = IntentDescription("Starts a new board, optionally for a project folder.")
    static var openAppWhenRun = true

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<BoardEntity> {
        guard await requestIntentPermission() else { throw GhosttyIntentError.permissionDenied }
        guard let ghostty = BoardIntents.ghostty else { throw GhosttyIntentError.appUnavailable }
        let board = Board.newBoard(ghostty, folder: folder?.fileURL?.path(percentEncoded: false))
        BoardIntents.bringForward(board)
        return .result(value: BoardEntity(board.workspace, open: true))
    }
}

@available(macOS 15.0, *)
struct LaunchAgentsIntent: AppIntent {
    static var title: LocalizedStringResource = "Launch Agents on a Board"
    static var description = IntentDescription("Starts coding agents side by side on a board, each in its own tile.")
    static var openAppWhenRun = true

    @Parameter(title: "Agent", default: .claude)
    var agent: BoardAgentChoice

    @Parameter(title: "How Many", default: 1, inclusiveRange: (1, 12))
    var count: Int

    @Parameter(title: "Task", description: "What the agents should do. Leave empty to start them waiting.")
    var task: String?

    @Parameter(title: "Folder", supportedContentTypes: [.folder])
    var folder: IntentFile?

    @Parameter(title: "Board")
    var board: BoardEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else { throw GhosttyIntentError.permissionDenied }
        let controller = try BoardIntents.board(board)
        guard let entry = BoardAgent.catalog.first(where: { $0.binary == agent.rawValue }) else {
            throw GhosttyIntentError.appUnavailable
        }
        let prompt = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = entry.command(prompt: prompt?.isEmpty == false ? prompt : nil)
        controller.launch(Array(repeating: (agent: entry, command: line), count: count),
                          folder: folder?.fileURL?.path(percentEncoded: false))
        BoardIntents.bringForward(controller)
        return .result()
    }
}

enum BoardAgentChoice: String, AppEnum {
    case claude
    case codex
    case gemini

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .claude: .init(title: "Claude Code"),
        .codex: .init(title: "Codex"),
        .gemini: .init(title: "Gemini CLI"),
    ]
}

@available(macOS 15.0, *)
struct NewSketchIntent: AppIntent {
    static var title: LocalizedStringResource = "New Sketch"
    static var description = IntentDescription("Starts a sketch on a board, to draw the backend or mark up pictures.")
    static var openAppWhenRun = true

    @Parameter(title: "Pictures", supportedContentTypes: [.image])
    var pictures: [IntentFile]?

    @Parameter(title: "Board")
    var board: BoardEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SketchEntity> {
        guard await requestIntentPermission() else { throw GhosttyIntentError.permissionDenied }
        let controller = try BoardIntents.board(board)
        BoardIntents.bringForward(controller)
        let images = (pictures ?? []).compactMap { NSImage(data: $0.data) }
        let elements = BoardSketchImages.elements(for: images, largest: 520, at: CGPoint(x: 40, y: 40))
        let id = controller.addSketch(elements: elements)
        guard let sketch = controller.model.sketches.first(where: { $0.id == id }) else { throw GhosttyIntentError.boardNotFound }
        return .result(value: SketchEntity(sketch, board: controller.model.name))
    }
}

struct GetSketchPictureIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Sketch as Picture"
    static var description = IntentDescription("A sketch as a PNG, to share, save or send on.")

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background
#endif

    @Parameter(title: "Sketch")
    var sketch: SketchEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard await requestIntentPermission() else { throw GhosttyIntentError.permissionDenied }
        guard let pair = SketchQuery.open().first(where: { $0.sketch.id == sketch.id }),
              let url = pair.board.exportSketch(sketch.id) else { throw GhosttyIntentError.boardNotFound }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .png))
    }
}

struct ArrangeBoardIntent: AppIntent {
    static var title: LocalizedStringResource = "Arrange Board by Project"
    static var description = IntentDescription("Puts each project's tiles together on a board.")
    static var openAppWhenRun = true

    @Parameter(title: "Board")
    var board: BoardEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else { throw GhosttyIntentError.permissionDenied }
        let controller = try BoardIntents.board(board)
        BoardIntents.bringForward(controller)
        controller.arrangeByProject()
        return .result()
    }
}

// MARK: - Spotlight and Siri

@available(macOS 15.0, *)
struct TellurionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewSketchIntent(), phrases: [
            "New sketch in \(.applicationName)",
            "Sketch the backend in \(.applicationName)",
        ], shortTitle: "New Sketch", systemImageName: "scribble.variable")
        AppShortcut(intent: LaunchAgentsIntent(), phrases: [
            "Launch agents in \(.applicationName)",
            "Start agents in \(.applicationName)",
        ], shortTitle: "Launch Agents", systemImageName: "sparkles")
        AppShortcut(intent: OpenBoardIntent(), phrases: [
            "Open \(\.$board) in \(.applicationName)",
            "Open a board in \(.applicationName)",
        ], shortTitle: "Open Board", systemImageName: "square.grid.3x3.square")
        AppShortcut(intent: NewBoardIntent(), phrases: [
            "New board in \(.applicationName)",
        ], shortTitle: "New Board", systemImageName: "plus.square.on.square")
    }
}
#endif
