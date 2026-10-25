#if os(macOS)
import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// What the board's views draw: where each tile is, which is on top, and the zoom.
final class BoardModel: ObservableObject {
    /// The tiles in the window's tree, in the order they were added.
    @Published var surfaces: [Ghostty.SurfaceView] = []
    @Published var frames: [UUID: CGRect] = [:]
    /// Back to front.
    @Published var order: [UUID] = []
    /// The zoom once a pinch or zoom animation has settled (not every step of it).
    @Published var zoom: CGFloat = 1
    @Published var showComposer = false
    @Published var showOrchestratorComposer = false
    /// The Group composer, from the bar's Group chip (prefilled when editing a preset).
    @Published var showGroupComposer = false
    @Published var showMissionMap = false
    @Published var showDocuments = false
    @Published var showAccounts = false
    /// Which account profiles each tile's agents use (see BoardAccounts).
    @Published var tileAccounts: [UUID: [BoardAccount.Provider: UUID]] = [:]
    var groupComposerPreset: BoardPreset?
    @Published var showSidebar = true
    @Published var name = ""
    /// Bumped when an agent on this board changes, so the list and tiles refresh.
    @Published var agentTick = 0
    /// The tile with the cursor, or the last one that had it.
    @Published var focused: Weak<Ghostty.SurfaceView>?
    /// Names given to tiles, shown instead of the terminal's title.
    @Published var titles: [UUID: String] = [:]
    /// Each tile's project (see BoardProjects), and each project's color on this board.
    @Published var projects: [UUID: String] = [:]
    @Published var colors: [String: Int] = [:]
    /// Drawings on the board (see BoardSketch).
    @Published var sketches: [BoardSketch] = []
    /// Notes, checklists and kanban boards (see BoardCard).
    @Published var cards: [BoardCard] = []
    /// The sketch with the keyboard, if one has it.
    @Published var focusedSketch: UUID?
    /// Tiles whose processes are stopped (see BoardPause).
    @Published var paused: Set<UUID> = []
    /// Orchestrators and what's wired to them (see BoardTeams).
    @Published var teams: [BoardTeam] = []
    /// Groups you made (see BoardNamedGroups).
    @Published var groups: [BoardGroupNode] = []
    /// Big text on the board, and ink drawn on it.
    @Published var labels: [BoardLabelNode] = []
    @Published var ink: [BoardInkStroke] = []
    /// Tiles that moved to classic windows with the switch to Classic, and where they were. Not on
    /// the board until they come back; their ink, groups and wires wait for them (see releaseForClassic).
    var released: [BoardTile] = []
    /// The tiles on the board and those away in windows: what ink, groups and wires may refer to.
    var tileIDs: Set<UUID> { Set(surfaces.map(\.id)).union(released.map(\.id)) }
    /// What a click on the board does (see BoardPalettes).
    @Published var tool: BoardTool = .select
    @Published var inkColor = UserDefaults.standard.integer(forKey: "BoardInkColor") {
        didSet { UserDefaults.standard.set(inkColor, forKey: "BoardInkColor") }
    }
    @Published var inkWidth: CGFloat = UserDefaults.standard.object(forKey: "BoardInkWidth") as? CGFloat ?? 2.5 {
        didSet { UserDefaults.standard.set(inkWidth, forKey: "BoardInkWidth") }
    }
    /// The radial menu: where it opened in the window (SwiftUI points) and on the board.
    @Published var radial: (window: CGPoint, board: CGPoint)?
    /// The orchestrator that clicks on tiles and groups wire to, while connecting.
    @Published var wiring: UUID?
    /// The next change to `frames` slides the tiles there instead of jumping.
    var animateNextLayout = false

    /// The color of a tile's project, if it's in one.
    func color(of id: UUID) -> Int? { projects[id].flatMap { colors[$0] } }

    /// Every tile on the board: terminals and sketches.
    var nodeIDs: [UUID] { surfaces.map(\.id) + sketches.map(\.id) + cards.map(\.id) + labels.map(\.id) }

    var stacked: [Ghostty.SurfaceView] {
        surfaces.sorted { (order.firstIndex(of: $0.id) ?? -1) < (order.firstIndex(of: $1.id) ?? -1) }
    }
}

/// A board window: every terminal is a tile on a canvas you pan and zoom. The tiles are the
/// window's surface tree, so closing, splitting, new tabs, focus, hooks and agent status
/// work as in any terminal window; the tree's shape is ignored and the frames live here.
final class BoardController: BaseTerminalController {
    static let boardSize = CGSize(width: 24000, height: 16000)
    static let tileSize = CGSize(width: 720, height: 440)
    static let gap: CGFloat = 28

    static let boardsDidChange = Notification.Name("com.steventsvik.ghostty-extreme.boardsDidChange")

    /// The boards that are open, in front or out of sight. A closed board's window can still be
    /// around (it isn't released on close), so it's left out by its flag.
    static var all: [BoardController] {
        NSApp.windows.compactMap { $0.windowController as? BoardController }.filter { !$0.closed }
    }

    /// Set when the window closes; `all` and `front` never offer a closed board again.
    private(set) var closed = false

    /// The board in front: the main window's, else one on screen, else any (boards you
    /// switched away from stay open out of sight).
    static var front: BoardController? {
        all.first { $0.window?.isMainWindow == true }
            ?? all.filter { $0.window?.isVisible == true }.max { $0.lastShown < $1.lastShown }
            ?? all.max { $0.lastShown < $1.lastShown }
    }

    /// When this board was last in front, so closing one brings back the one before it.
    private(set) var lastShown = Date()
    /// Deleting the board: closing its window removes it instead of saving it.
    private var deleteOnClose = false
    /// Closing for the switch to Classic: the board stays open in its file for the switch back.
    private var leavingForClassic = false

    /// Quitting: windows closing now stay open in the saved board.
    private static var terminating = false

    let model: BoardModel
    private(set) var workspace: BoardWorkspace
    weak var canvas: BoardCanvasView?

    /// The line each tile was opened with, started again after a relaunch.
    /// The line each tile was started with, to start it again after a relaunch.
    private(set) var commands: [UUID: String] = [:]
    /// Tiles where an agent has reported status. When its status goes away, the agent quit
    /// and isn't started again.
    private var agentSeen: Set<UUID> = []
    /// Tiles whose agent is being restarted: its status goes away for a moment, which isn't it
    /// quitting. Cleared when the agent reports again, or after a while.
    var restarting: Set<UUID> = []
    /// Which tiles were last told they're visible.
    private(set) var visible: [UUID: Bool] = [:]
    private var saveWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var restoreCamera: BoardWorkspace.Camera?
    private var firstResponderObservation: NSKeyValueObservation?
    /// Watches each tile's folder, to keep its project color.
    private var pwdWatchers: [UUID: AnyCancellable] = [:]
    /// The folder each tile was opened in, its folder until its shell reports one.
    private var launchFolders: [UUID: String] = [:]
    /// Draws the groups and the snapping lines (set by BoardTiles).
    weak var groupsView: BoardGroupsView?
    /// The board's own agent, in the bar at the bottom (see BoardAssistant).
    private(set) lazy var assistant = BoardAssistant(controller: self)
    /// The bar's text field, for ⌘L.
    weak var assistantField: NSTextField?
    /// What orchestrators have yet to hear from their agents (see BoardTeams).
    let teamRelay = BoardTeamRelay()
    /// The Documents panel (see StudioDocuments).
    lazy var documents = StudioDocuments()
    /// Diagrams drawn from the project (see StudioDiagrams).
    lazy var diagrams: StudioDiagrams = {
        let diagrams = StudioDiagrams()
        diagrams.board = self
        return diagrams
    }()
    /// Each orchestrator card's brain, made on first use.
    var orchestratorBrains: [UUID: OrchestratorBrain] = [:]
    /// Escape ends connecting (see startWiring).
    var wiringMonitor: Any?
    /// The tool keys (see installToolKeys).
    var toolKeyMonitor: Any?
    /// The board's cursor follows the tool, however it changed.
    var toolCursor: AnyCancellable?
    /// Tile labels, built once per run-loop turn (a redraw asks for them many times).
    var tileLabelCache: (key: [UUID], titles: [UUID: String], labels: [(id: UUID, label: String, surface: Ghostty.SurfaceView)])?
    /// What a closed tile belonged to, so undoing the close puts it back.
    private var closedTiles: [UUID: ClosedTile] = [:]

    private struct ClosedTile {
        var group: BoardGroupNode?
        var ink: [BoardInkStroke]
        var teams: [(team: UUID, member: BoardTeam.Member)]
    }

    // MARK: Opening

    /// Opens a board in place of the front one, which steps back out of sight and keeps
    /// running; the list of boards switches between them. `newWindow` opens it beside instead.
    @discardableResult
    static func open(_ ghostty: Ghostty.App, workspace: BoardWorkspace, restoring: Bool, newWindow: Bool = false) -> BoardController {
        let front = newWindow ? nil : Self.front
        let controller = BoardController(ghostty, workspace: workspace, restoring: restoring)
        controller.makeWindow(replacing: front?.window, offset: newWindow)
        controller.saveNow()
        NotificationCenter.default.post(name: boardsDidChange, object: nil)
        return controller
    }

    init(_ ghostty: Ghostty.App, workspace: BoardWorkspace, restoring: Bool) {
        let model = BoardModel()
        var commands: [UUID: String] = [:]
        var tree = SplitTree<Ghostty.SurfaceView>()
        if let app = ghostty.app {
            for tile in workspace.tiles {
                var config = Ghostty.SurfaceConfiguration()
                config.workingDirectory = tile.cwd ?? workspace.folder
                if restoring, let line = BoardAgent.resumeCommand(for: tile) { config.initialInput = line }
                // The same account profiles as before.
                let chosen = Dictionary(uniqueKeysWithValues: (tile.accounts ?? [:]).compactMap { key, value in
                    BoardAccount.Provider(rawValue: key).map { ($0, value) }
                })
                for (key, value) in BoardAccounts.shared.environment(chosen) { config.environmentVariables[key] = value }
                if !chosen.isEmpty { model.tileAccounts[tile.id] = chosen }
                let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: tile.id)
                if let last = tree.root?.leftmostLeaf(), let next = try? tree.inserting(view: view, at: last, direction: .right) {
                    tree = next
                } else if tree.isEmpty {
                    tree = SplitTree(view: view)
                } else {
                    continue
                }
                model.frames[view.id] = tile.frame
                model.order.append(view.id)
                if let command = tile.command { commands[view.id] = command }
                if let title = tile.title { model.titles[view.id] = title }
            }
        }
        for sketch in workspace.sketches ?? [] {
            model.sketches.append(sketch)
            model.frames[sketch.id] = sketch.frame
            model.order.append(sketch.id)
        }
        for card in (workspace.cards ?? []).map(BoardController.migrated) {
            model.cards.append(card)
            model.frames[card.id] = card.frame
            model.order.append(card.id)
        }
        model.groups = workspace.groups ?? []
        model.labels = workspace.labels ?? []
        for label in model.labels {
            model.frames[label.id] = label.frame
            model.order.append(label.id)
        }
        model.ink = workspace.ink ?? []
        model.released = (workspace.released ?? []).filter { tile in !workspace.tiles.contains { $0.id == tile.id } }
        model.teams = (workspace.teams ?? []).filter { team in model.cards.contains { $0.id == team.id } }
        model.name = workspace.name
        model.colors = workspace.colors ?? [:]
        self.model = model
        self.commands = commands
        self.workspace = workspace
        self.restoreCamera = workspace.camera
        super.init(ghostty, surfaceTree: tree)
        titleOverride = workspace.name

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: VerticalTabsAgents.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let surface = note.object as? Ghostty.SurfaceView, self.surfaceTree.contains(surface) else { return }
            if VerticalTabsAgents.shared.info(for: surface) != nil {
                self.agentSeen.insert(surface.id)
                self.restarting.remove(surface.id)
                self.nameAgentIfNeeded(surface)
            }
            self.model.agentTick &+= 1
            self.cardsAgentChanged(surface)
            self.teamMemberChanged(surface)
            self.scheduleSave()
        })
        observers.append(center.addObserver(forName: Ghostty.Notification.ghosttyNewTab, object: nil, queue: .main) { [weak self] note in
            guard let self, let surface = note.object as? Ghostty.SurfaceView, self.surfaceTree.contains(surface) else { return }
            let config = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey] as? Ghostty.SurfaceConfiguration
            self.addTile(config: config, near: surface)
        })
        observers.append(center.addObserver(forName: Ghostty.Notification.ghosttyPresentTerminal, object: nil, queue: .main) { [weak self] note in
            // Another tool showing a tile (Mission Control, a notification, the palette):
            // the board moves to it too.
            guard let self, let surface = note.object as? Ghostty.SurfaceView, self.surfaceTree.contains(surface) else { return }
            self.expandGroup(containing: surface.id)
            self.raise(surface)
            self.reveal(surface)
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            Self.terminating = true
            self?.saveNow()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func makeWindow(replacing front: NSWindow?, offset: Bool) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1480, screen.width - 80), height: min(940, screen.height - 60))
        var frame = workspace.windowFrame ?? NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                                    width: size.width, height: size.height)
        let replaced = front.flatMap { Self.canReplace($0) ? $0 : nil }
        if let replaced { frame = replaced.frame }
        // Its own window, a step down and right of the front one so both show.
        if offset, let main = Self.front?.window, !main.styleMask.contains(.fullScreen) {
            frame = main.frame.offsetBy(dx: 30, dy: -30)
        }
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        // Boards switch from their list, not with tabs: a tab bar would cover the board's top.
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 640, height: 420)
        window.appearance = NSAppearance(named: Extreme.chrome.isLight ? .aqua : .darkAqua)
        window.backgroundColor = Extreme.chrome.ink.nsColor
        window.setFrame(frame, display: false)
        window.delegate = self
        self.window = window
        windowDidLoad()
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderDidChange(window.firstResponder) }
        }

        window.contentView = NSHostingView(rootView: BoardWindowView(controller: self, model: model).environmentObject(ghostty))
        window.title = workspace.name

        window.makeKeyAndOrderFront(nil)
        replaced?.orderOut(nil)
        if let first = surfaceTree.root?.leftmostLeaf() {
            Ghostty.moveFocus(to: first)
        }
        installToolKeys()
        BoardTest.startIfRequested(self)
    }

    /// The canvas is in the window: put the camera where it was, or on the tiles.
    func canvasDidAttach(_ canvas: BoardCanvasView) {
        self.canvas = canvas
        if let camera = restoreCamera {
            restoreCamera = nil
            canvas.magnification = camera.zoom
            // After the first layout: before it, the clip view scales the origin by the zoom.
            DispatchQueue.main.async { [weak self] in
                canvas.contentView.scroll(to: camera.origin)
                canvas.reflectScrolledClipView(canvas.contentView)
                self?.updateVisibility()
            }
        } else if model.frames.isEmpty {
            let size = canvas.contentView.bounds.size
            canvas.contentView.scroll(to: CGPoint(x: Self.boardSize.width / 2 - size.width / 2,
                                                  y: Self.boardSize.height / 2 - size.height / 2))
            canvas.reflectScrolledClipView(canvas.contentView)
        } else {
            DispatchQueue.main.async { self.fitAll(animated: false) }
        }
        model.zoom = canvas.magnification
        updateVisibility()
        scheduleSave()
    }

    /// A terminal took the cursor: it's the focused tile, and comes to the front.
    private func firstResponderDidChange(_ responder: NSResponder?) {
        // A sketch (its drawing, or a label being typed) has the keyboard.
        var view = responder as? NSView
        while let current = view, !(current is BoardSketchView) { view = current.superview }
        let sketch = (view as? BoardSketchView)?.nodeID
        if model.focusedSketch != sketch { model.focusedSketch = sketch }
        if let sketch { raise(id: sketch) }
        guard let surface = responder as? Ghostty.SurfaceView, surfaceTree.contains(surface),
              model.focused?.value !== surface else { return }
        model.focused = .init(surface)
        focusedSurfaceDidChange(to: surface)
        raise(surface)
    }

    // MARK: The tree

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)
        let surfaces = Array(to)
        // Undo keeps a closed terminal alive; it isn't the board's focused tile any more.
        if let focused = model.focused?.value, !to.contains(focused) { model.focused = nil }
        // A paused tile that closes is continued, so it can quit.
        let gone = model.paused.subtracting(surfaces.map(\.id))
        if !gone.isEmpty {
            model.paused.subtract(gone)
            BoardPause.queue.async { BoardPause.set(false, surfaces: gone) }
        }
        let anchor = focusedSurface.flatMap { model.frames[$0.id] }
        for view in surfaces where model.frames[view.id] == nil && !placeIfReturning(view) {
            // A split, a new tab from a keybinding, or an undone close.
            model.frames[view.id] = freeSpot(size: Self.tileSize, near: anchor)
        }
        for view in surfaces where !model.order.contains(view.id) { model.order.append(view.id) }
        let before = Set(from.map(\.id)), after = Set(surfaces.map(\.id))
        if !model.released.isEmpty { model.released.removeAll { after.contains($0.id) } }
        for id in before.subtracting(after) {
            closedTiles[id] = ClosedTile(
                group: model.groups.first { $0.tiles.contains(id) },
                ink: model.ink.filter { $0.anchor == id },
                teams: model.teams.compactMap { team in team.members.first { $0.tile == id }.map { (team.id, $0) } })
        }
        model.surfaces = surfaces
        for id in after.subtracting(before) {
            if let closed = closedTiles.removeValue(forKey: id) { restore(closed, tile: id) }
        }
        // Closed tiles come unwired.
        if !model.teams.isEmpty { pruneTeams() }
        if !model.groups.isEmpty { pruneGroups() }
        if !model.ink.isEmpty { pruneInk() }
        watchProjects()
        updateVisibility()
        scheduleSave()
    }

    /// An undone close: back into its group (made again if it had gone), with its ink and wires.
    private func restore(_ closed: ClosedTile, tile id: UUID) {
        if let group = closed.group {
            if let index = model.groups.firstIndex(where: { $0.id == group.id }) {
                if !model.groups[index].tiles.contains(id) { model.groups[index].tiles.append(id) }
            } else if model.groups.allSatisfy({ !$0.tiles.contains(id) }) {
                var group = group
                group.tiles = [id]
                model.groups.append(group)
            }
        }
        let inked = Set(model.ink.map(\.id))
        model.ink += closed.ink.filter { !inked.contains($0.id) }
        for (team, member) in closed.teams {
            guard let index = model.teams.firstIndex(where: { $0.id == team }),
                  !model.teams[index].members.contains(where: { $0.tile == id }) else { continue }
            model.teams[index].members.append(member)
        }
    }

    // MARK: Switching editions

    /// Switching to Classic: the tiles leave for windows, and the board closes after. They stay
    /// with the board as released tiles, so their ink, groups and wires are kept and each comes
    /// back to its place when its terminal is moved onto this board again. The board stays open
    /// in its file, so switching back to Board reopens it. Returns the terminals.
    func releaseForClassic() -> [Ghostty.SurfaceView] {
        leavingForClassic = true
        let views = Array(surfaceTree)
        guard !views.isEmpty else { return [] }
        let old = Dictionary(workspace.tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        model.released.removeAll { tile in views.contains { $0.id == tile.id } }
        model.released += views.map { view in
            BoardTile(id: view.id, frame: model.frames[view.id] ?? .zero, cwd: view.pwd ?? old[view.id]?.cwd, title: model.titles[view.id])
        }
        surfaceTree = .init()
        return views
    }

    /// Once every classic terminal has come back to a board, the tiles still away were closed in
    /// their windows: they're forgotten, and the ink, groups and wires that waited for them go.
    func forgetReleased() {
        guard !model.released.isEmpty else { return }
        model.released = []
        if !model.teams.isEmpty { pruneTeams() }
        if !model.groups.isEmpty { pruneGroups() }
        if !model.ink.isEmpty { pruneInk() }
        scheduleSave()
    }

    /// A tile back from a classic window takes the place it left (see releaseForClassic).
    private func placeIfReturning(_ view: Ghostty.SurfaceView) -> Bool {
        guard let index = model.released.firstIndex(where: { $0.id == view.id }) else { return false }
        let tile = model.released.remove(at: index)
        model.frames[view.id] = tile.frame
        if let title = tile.title, model.titles[view.id] == nil { model.titles[view.id] = title }
        return true
    }

    // MARK: Projects

    /// Follows every tile's folder; a tile that changes project changes color.
    private func watchProjects() {
        let ids = Set(model.surfaces.map(\.id))
        for id in pwdWatchers.keys where !ids.contains(id) { pwdWatchers[id] = nil }
        for id in launchFolders.keys where !ids.contains(id) { launchFolders[id] = nil }
        for view in model.surfaces where pwdWatchers[view.id] == nil {
            pwdWatchers[view.id] = view.$pwd.removeDuplicates().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateProjects() }
        }
        updateProjects()
    }

    private func updateProjects() {
        var projects: [UUID: String] = [:]
        for view in model.surfaces {
            if let project = BoardProjects.project(of: folder(of: view)) { projects[view.id] = project }
        }
        // A project keeps its color for as long as the board does, unless a project on the board
        // now has it (it left, and the color was given away): then, like a new project, it takes
        // the first color no project on the board has.
        var colors = model.colors
        var present: [String] = []
        for project in model.surfaces.compactMap({ projects[$0.id] }) where !present.contains(project) { present.append(project) }
        var taken: [Int: String] = [:]
        var needColor: [String] = []
        for project in present {
            if let color = colors[project], taken[color] == nil {
                taken[color] = project
            } else {
                needColor.append(project)
            }
        }
        for project in needColor {
            let color = BoardProjects.palette.indices.first { taken[$0] == nil } ?? (taken.count % BoardProjects.palette.count)
            colors[project] = color
            taken[color] = project
        }
        if model.projects != projects { model.projects = projects }
        if model.colors != colors {
            model.colors = colors
            scheduleSave()
        }
    }

    /// A tile's folder: where its shell is, or where it was opened until the shell says.
    func folder(of view: Ghostty.SurfaceView) -> String? {
        view.pwd ?? launchFolders[view.id]
    }

    // MARK: Tiles

    /// A new terminal tile beside the other tiles of its project, next to `near` or in the
    /// middle of the view.
    /// `focus` false leaves the keyboard where it is (tiles an orchestrator opens).
    @discardableResult
    func addTile(config: Ghostty.SurfaceConfiguration? = nil, command: String? = nil,
                 near: Ghostty.SurfaceView? = nil, frame: CGRect? = nil, focus: Bool = true) -> Ghostty.SurfaceView? {
        guard let app = ghostty.app else { return nil }
        var config = config ?? Ghostty.SurfaceConfiguration()
        // A tile opened a moment ago may not know its folder yet; the one it was opened in counts.
        if config.workingDirectory == nil {
            config.workingDirectory = (near ?? focusedSurface).flatMap(folder(of:)) ?? workspace.folder
        }
        if let command { config.initialInput = command }
        // The active account profiles, unless it was given its own.
        let own = BoardAccount.Provider.allCases.contains { config.environmentVariables[$0.variable] != nil }
        let accounts = own ? [:] : applyAccounts(&config)
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        if !accounts.isEmpty { model.tileAccounts[view.id] = accounts }
        if let folder = config.workingDirectory { launchFolders[view.id] = folder }
        let anchor = (near ?? focusedSurface).flatMap { model.frames[$0.id] }
        model.frames[view.id] = frame ?? freeSpot(size: Self.tileSize, project: BoardProjects.project(of: config.workingDirectory), near: anchor)
        if let command { commands[view.id] = command }
        insert([view], undoAction: "New Terminal", focus: focus)
        if focus { reveal(view) }
        return view
    }

    /// A split on a board is a new tile beside the terminal (a handoff, a review loop, Ghostty's
    /// split keys).
    @discardableResult
    override func newSplit(at oldView: Ghostty.SurfaceView, direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
                           baseConfig config: Ghostty.SurfaceConfiguration? = nil) -> Ghostty.SurfaceView? {
        guard surfaceTree.contains(oldView) else { return nil }
        return addTile(config: config, near: oldView)
    }

    func insert(_ views: [Ghostty.SurfaceView], undoAction: String, focus: Bool = true) {
        var tree = surfaceTree
        for view in views {
            if let last = tree.root?.leftmostLeaf(), let next = try? tree.inserting(view: view, at: last, direction: .right) {
                tree = next
            } else {
                tree = SplitTree(view: view)
            }
        }
        replaceSurfaceTree(tree, moveFocusTo: focus ? views.first : nil, moveFocusFrom: focus ? focusedSurface : nil, undoAction: undoAction)
    }

    /// Starts agents and shells from the composer as a block of tiles, then shows them all.
    /// `skip`: the agents were started without permission prompts (kept for their restarts).
    /// `adopt`: the folder becomes the board's (the composer); off, it's only these tiles'.
    @discardableResult
    func launch(_ lines: [(agent: BoardAgent?, command: String)], folder: String?, skip: Bool = false,
                adopt: Bool = true) -> [Ghostty.SurfaceView] {
        guard let app = ghostty.app, !lines.isEmpty else { return [] }
        if let folder, adopt { workspace.folder = folder }
        let n = lines.count
        let columns = n <= 3 ? n : Int(ceil(Double(n).squareRoot()))
        let rows = Int(ceil(Double(n) / Double(columns)))
        let size = n > 4 ? CGSize(width: 640, height: 400) : Self.tileSize
        let block = CGSize(width: CGFloat(columns) * size.width + CGFloat(columns - 1) * Self.gap,
                           height: CGFloat(rows) * size.height + CGFloat(rows - 1) * Self.gap)
        // Beside what's already on the board, or in the middle of the view on an empty one.
        let existing = model.surfaces.compactMap { model.frames[$0.id] }
        let all = existing.first.map { first in existing.dropFirst().reduce(first) { $0.union($1) } }
        let area = freeSpot(size: block, near: all)
        var views: [Ghostty.SurfaceView] = []
        for (index, line) in lines.enumerated() {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = folder ?? workspace.folder
            config.initialInput = line.command.isEmpty ? nil : line.command
            let accounts = applyAccounts(&config)
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            if !accounts.isEmpty { model.tileAccounts[view.id] = accounts }
            let col = index % columns, row = index / columns
            model.frames[view.id] = CGRect(x: area.minX + CGFloat(col) * (size.width + Self.gap),
                                           y: area.minY + CGFloat(row) * (size.height + Self.gap),
                                           width: size.width, height: size.height)
            // Started again plainly after a relaunch (Claude Code and Codex resume instead).
            commands[view.id] = line.agent.map { agent in
                agent.binary + (skip ? agent.skipFlag.map { " " + $0 } ?? "" : "") + "\n"
            } ?? nil
            views.append(view)
        }
        insert(views, undoAction: n == 1 ? "Launch Agent" : "Launch Agents")
        zoom(toFit: area, animated: true)
        return views
    }

    /// Terminals from classic windows become tiles: a grid beside what's on the board, each
    /// project's terminals together. The windows they leave close (they're empty then). The
    /// terminals themselves aren't touched, so their agents keep running.
    func adopt(_ views: [Ghostty.SurfaceView], from controllers: [TerminalController]) {
        guard !views.isEmpty else { return }
        // Taken out of their windows first; the empty tree closes each window. A closed window
        // with no terminals leaves nothing to undo, so these moves aren't undoable there.
        for controller in controllers { controller.surfaceTree = .init() }
        let folders = Dictionary(uniqueKeysWithValues: views.map { ($0.id, $0.pwd) })
        for view in views { if let folder = folders[view.id] ?? nil { launchFolders[view.id] = folder } }
        // Tiles that left with the switch to Classic go back where they were; the rest form a grid.
        let returning = views.filter(placeIfReturning)
        var fit = returning.compactMap { model.frames[$0.id] }.reduce(nil as CGRect?) { fit, frame in fit.map { $0.union(frame) } ?? frame }
        let fresh = views.filter { view in !returning.contains { $0 === view } }
        let keyed = fresh.enumerated().map { (index: $0.offset, view: $0.element, project: BoardProjects.project(of: folders[$0.element.id] ?? nil) ?? "") }
        let sorted = keyed.sorted { $0.project == $1.project ? $0.index < $1.index : $0.project < $1.project }.map(\.view)
        let n = sorted.count
        if n > 0 {
            let columns = n <= 3 ? n : Int(ceil(Double(n).squareRoot()))
            let rows = Int(ceil(Double(n) / Double(columns)))
            let size = n > 4 ? CGSize(width: 640, height: 400) : Self.tileSize
            let block = CGSize(width: CGFloat(columns) * size.width + CGFloat(columns - 1) * Self.gap,
                               height: CGFloat(rows) * size.height + CGFloat(rows - 1) * Self.gap)
            let existing = model.surfaces.compactMap { model.frames[$0.id] } + (fit.map { [$0] } ?? [])
            let all = existing.first.map { first in existing.dropFirst().reduce(first) { $0.union($1) } }
            let area = freeSpot(size: block, near: all)
            for (index, view) in sorted.enumerated() {
                let col = index % columns, row = index / columns
                model.frames[view.id] = CGRect(x: area.minX + CGFloat(col) * (size.width + Self.gap),
                                               y: area.minY + CGFloat(row) * (size.height + Self.gap),
                                               width: size.width, height: size.height)
            }
            fit = fit.map { $0.union(area) } ?? area
        }
        insert(returning + sorted, undoAction: views.count == 1 ? "Move Terminal to Board" : "Move Terminals to Board")
        if let fit { zoom(toFit: fit, animated: true) }
    }

    /// The folder new tiles start in, from now on.
    func setFolder(_ folder: String) { workspace.folder = folder }

    /// The line a tile is started with again after a relaunch.
    func setCommand(_ line: String, for id: UUID) { commands[id] = line }

    func close(_ view: Ghostty.SurfaceView) {
        closeSurface(view, withConfirmation: view.needsConfirmQuit)
    }

    func raise(_ view: Ghostty.SurfaceView) {
        raise(id: view.id)
    }

    func raise(id: UUID) {
        guard model.order.last != id else { return }
        model.order.removeAll { $0 == id }
        model.order.append(id)
    }

    static let minTileSize = CGSize(width: 280, height: 160)

    func move(id: UUID, to frame: CGRect) {
        model.frames[id] = clamp(frame)
    }

    func resize(id: UUID, to frame: CGRect) {
        var frame = frame
        frame.size.width = max(frame.width, Self.minTileSize.width)
        frame.size.height = max(frame.height, Self.minTileSize.height)
        model.frames[id] = clamp(frame)
    }

    /// Moves a group's tiles together, from where they were when the drag began.
    func moveGroup(_ start: [UUID: CGRect], by delta: CGSize) {
        guard let first = start.values.first else { return }
        let all = start.values.dropFirst().reduce(first) { $0.union($1) }
        // The group stops at the board's edge as one piece.
        let moved = clamp(all.offsetBy(dx: delta.width, dy: delta.height))
        let dx = moved.minX - all.minX, dy = moved.minY - all.minY
        var frames = model.frames
        for (id, frame) in start { frames[id] = frame.offsetBy(dx: dx, dy: dy) }
        model.frames = frames
    }

    // MARK: Snapping

    /// Where a dragged tile lands: its edges line up with nearby tiles' edges, or sit one gap
    /// beside them, when they come within a few points on screen. Returns the lines to show.
    func snap(_ rect: CGRect, for id: UUID, resizing: Bool) -> (rect: CGRect, guides: [(CGPoint, CGPoint)]) {
        let zoom = max(canvas?.magnification ?? 1, 0.08)
        let reach = 9 / zoom
        let others = model.nodeIDs.filter { $0 != id }.compactMap { model.frames[$0] }
            .filter { $0.insetBy(dx: -500, dy: -500).intersects(rect) }
        guard !others.isEmpty else { return (rect, []) }
        let gap = Self.gap

        // The best shift along one axis: (shift, the other tile, the snapped line).
        func best(_ edges: [CGFloat], _ targets: [(CGFloat, CGRect)]) -> (CGFloat, CGRect, CGFloat)? {
            var found: (CGFloat, CGRect, CGFloat)?
            for edge in edges {
                for (target, other) in targets {
                    let shift = target - edge
                    if abs(shift) <= reach, abs(shift) < abs(found?.0 ?? .infinity) { found = (shift, other, target) }
                }
            }
            return found
        }
        let xTargets = others.flatMap { o in [(o.minX, o), (o.maxX, o), (o.maxX + gap, o), (o.minX - gap, o)] }
        let yTargets = others.flatMap { o in [(o.minY, o), (o.maxY, o), (o.maxY + gap, o), (o.minY - gap, o)] }
        var result = rect
        var guides: [(CGPoint, CGPoint)] = []
        if let (shift, other, line) = best(resizing ? [rect.maxX] : [rect.minX, rect.maxX], xTargets) {
            if resizing { result.size.width += shift } else { result.origin.x += shift }
            let top = min(result.minY, other.minY) - 12, bottom = max(result.maxY, other.maxY) + 12
            guides.append((CGPoint(x: line, y: top), CGPoint(x: line, y: bottom)))
        }
        if let (shift, other, line) = best(resizing ? [rect.maxY] : [rect.minY, rect.maxY], yTargets) {
            if resizing { result.size.height += shift } else { result.origin.y += shift }
            let left = min(result.minX, other.minX) - 12, right = max(result.maxX, other.maxX) + 12
            guides.append((CGPoint(x: left, y: line), CGPoint(x: right, y: line)))
        }
        if resizing, result.width < Self.minTileSize.width || result.height < Self.minTileSize.height { return (rect, []) }
        return (result, guides)
    }

    /// A tile dropped mostly over another slides to the nearest free spot.
    /// `from`: where the drag began, so ⌘Z after a drop that changed its group puts it back.
    func settleDrop(id: UUID, from: CGRect? = nil) {
        defer { tileDidSettle() }
        if !model.groups.isEmpty { regroup(after: id, from: from) }
        guard let frame = model.frames[id] else { return }
        let others = model.nodeIDs.filter { $0 != id }.compactMap { model.frames[$0] }
        let covers = others.contains { other in
            let overlap = other.intersection(frame)
            guard !overlap.isNull else { return false }
            let smaller = min(other.width * other.height, frame.width * frame.height)
            return overlap.width * overlap.height > smaller * 0.25
        }
        guard covers else { return }
        let spot = nearestFree(frame, among: others)
        guard spot != frame else { return }
        setFrames([id: spot], animated: true, undoAction: nil)
    }

    /// The free place for `rect` closest to where it is.
    private func nearestFree(_ rect: CGRect, among others: [CGRect]) -> CGRect {
        let padded = others.map { $0.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2) }
        let step: CGFloat = 40
        var best: CGRect?
        var bestDistance = CGFloat.infinity
        for ring in 1...60 {
            // Rings are checked whole, so the nearest spot wins over the first one found.
            if best != nil, CGFloat(ring - 1) * step > bestDistance { break }
            for dy in -ring...ring {
                for dx in -ring...ring where max(abs(dx), abs(dy)) == ring {
                    let candidate = clamp(rect.offsetBy(dx: CGFloat(dx) * step, dy: CGFloat(dy) * step))
                    guard !padded.contains(where: { $0.intersects(candidate) }) else { continue }
                    let distance = hypot(candidate.minX - rect.minX, candidate.minY - rect.minY)
                    if distance < bestDistance { best = candidate; bestDistance = distance }
                }
            }
        }
        return best ?? freeSpot(size: rect.size, near: rect)
    }

    // MARK: Arranging

    /// Moves tiles, sliding them there when `animated`; undoable when `undoAction` is given.
    func setFrames(_ frames: [UUID: CGRect], animated: Bool, undoAction: String?) {
        let old = model.frames.filter { frames[$0.key] != nil }
        if let undoAction, let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.setFrames(old, animated: true, undoAction: undoAction)
            }
            undoManager.setActionName(undoAction)
        }
        model.animateNextLayout = animated
        var all = model.frames
        for (id, frame) in frames { all[id] = clamp(frame) }
        model.frames = all
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.35 : 0)) { [weak self] in self?.tileDidSettle() }
    }

    /// Puts each project's tiles together in a block, the blocks side by side (tiles not in a
    /// project last), where the board's tiles were. Sizes don't change.
    func arrangeByProject() {
        arrange(only: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in self?.fitAll() }
    }

    /// Arranges `only` those tiles (a group's), or every tile, by project.
    func arrange(only: Set<UUID>?) {
        let views = model.surfaces.filter { only?.contains($0.id) ?? true }
        let placed = views.compactMap { view in model.frames[view.id].map { (view.id, $0) } }
        guard let first = placed.first?.1 else { return }
        let origin = placed.dropFirst().reduce(first) { $0.union($1.1) }.origin
        // Groups in the order their projects got colors; within one, reading order.
        var byProject: [String: [(UUID, CGRect)]] = [:]
        for (id, frame) in placed { byProject[model.projects[id] ?? "", default: []].append((id, frame)) }
        let keys = byProject.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return (model.colors[a] ?? .max, a) < (model.colors[b] ?? .max, b)
        }
        var frames: [UUID: CGRect] = [:]
        let groupGap = Self.gap * 4 + BoardGroupsView.labelHeight * 4
        var x = origin.x, y = origin.y + BoardGroupsView.labelHeight, rowHeight: CGFloat = 0
        let rowLimit: CGFloat = 4200
        for key in keys {
            let tiles = byProject[key, default: []].sorted { a, b in
                abs(a.1.minY - b.1.minY) > 60 ? a.1.minY < b.1.minY : a.1.minX < b.1.minX
            }
            let columns = tiles.count <= 3 ? tiles.count : Int(ceil(Double(tiles.count).squareRoot()))
            // Lay the block out at 0,0 first, to know its size.
            var block: [(UUID, CGRect)] = []
            var cx: CGFloat = 0, cy: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
            for (index, tile) in tiles.enumerated() {
                if index > 0, index % columns == 0 {
                    cx = 0
                    cy += lineHeight + Self.gap
                    lineHeight = 0
                }
                block.append((tile.0, CGRect(x: cx, y: cy, width: tile.1.width, height: tile.1.height)))
                cx += tile.1.width + Self.gap
                width = max(width, cx - Self.gap)
                lineHeight = max(lineHeight, tile.1.height)
            }
            let height = cy + lineHeight
            if x > origin.x, x + width - origin.x > rowLimit {
                x = origin.x
                y += rowHeight + groupGap
                rowHeight = 0
            }
            for (id, rect) in block { frames[id] = rect.offsetBy(dx: x, dy: y) }
            x += width + groupGap
            rowHeight = max(rowHeight, height)
        }
        setFrames(frames, animated: true, undoAction: only == nil ? "Arrange by Project" : "Tidy Group")
    }

    /// Names a tile; nil or empty goes back to the terminal's own title.
    func setTitle(_ title: String?, for view: Ghostty.SurfaceView) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        model.titles[view.id] = title?.isEmpty == false ? title : nil
        scheduleSave()
    }

    /// Asks for a tile's name.
    func promptTitle(for view: Ghostty.SurfaceView) {
        promptRename("Rename Tile", info: "Leave blank to show the terminal's own title.", current: model.titles[view.id] ?? "") { [weak self] text in
            self?.setTitle(text, for: view)
        }
    }

    /// A sheet with one field to rename a tile, sketch or card.
    func promptRename(_ title: String, info: String? = nil, current: String, button: String = "Rename",
                      done: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        if let info { alert.informativeText = info }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            done(field.stringValue)
        }
    }

    /// "Change tab title" on a board names the tile with the cursor (the board is renamed in
    /// its list).
    override func promptTabTitle() {
        guard let view = focusedSurface ?? model.focused?.value else { return }
        promptTitle(for: view)
    }

    func tileDidSettle() {
        updateVisibility()
        scheduleSave()
    }

    func rename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != workspace.name else { return }
        workspace.name = name
        model.name = name
        titleOverride = name
        window?.title = name
        saveNow()
        NotificationCenter.default.post(name: Self.boardsDidChange, object: nil)
    }

    /// The first place a tile of `size` fits without covering another, searching outward from
    /// the right of `anchor`, or from the middle of the view.
    func freeSpot(size: CGSize, near anchor: CGRect?, around point: CGPoint? = nil) -> CGRect {
        let start: CGPoint
        if let point {
            start = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        } else if let anchor {
            start = CGPoint(x: anchor.maxX + Self.gap, y: anchor.minY)
        } else {
            let view = canvas?.documentVisibleRect
                ?? CGRect(x: Self.boardSize.width / 2 - 600, y: Self.boardSize.height / 2 - 400, width: 1200, height: 800)
            start = CGPoint(x: view.midX - size.width / 2, y: view.midY - size.height / 2)
        }
        // Only tiles still on the board (closed ones keep their last frame for undo).
        let ids = Set(model.nodeIDs)
        let others = model.frames.filter { ids.contains($0.key) }.values.map { $0.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2) }
        // Half a tile at a time, so a free spot close by isn't stepped over.
        let stepX = (size.width + Self.gap) / 2, stepY = (size.height + Self.gap) / 2
        for ring in 0...32 {
            for dy in -ring...ring {
                for dx in -ring...ring where max(abs(dx), abs(dy)) == ring {
                    let rect = clamp(CGRect(x: start.x + CGFloat(dx) * stepX, y: start.y + CGFloat(dy) * stepY,
                                            width: size.width, height: size.height))
                    if !others.contains(where: { $0.intersects(rect) }) { return rect }
                }
            }
        }
        return clamp(CGRect(origin: start, size: size))
    }

    /// A free spot beside a tile of `project`, so a new tile joins its group, as close to
    /// `anchor` (or the group's middle) as there's room. Anywhere free when the project has no
    /// tiles yet or no room beside them.
    func freeSpot(size: CGSize, project: String?, near anchor: CGRect?) -> CGRect {
        let mates = model.surfaces.filter { project != nil && model.projects[$0.id] == project }.compactMap { model.frames[$0.id] }
        guard !mates.isEmpty else { return freeSpot(size: size, near: anchor) }
        let ids = Set(model.nodeIDs)
        let others = model.frames.filter { ids.contains($0.key) }.values.map { $0.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2) }
        let target = anchor ?? mates.dropFirst().reduce(mates[0]) { $0.union($1) }
        var best: (rect: CGRect, distance: CGFloat)?
        for mate in mates {
            // Right, below, left and above, lined up with the tile.
            let origins = [
                CGPoint(x: mate.maxX + Self.gap, y: mate.minY),
                CGPoint(x: mate.minX, y: mate.maxY + Self.gap),
                CGPoint(x: mate.minX - Self.gap - size.width, y: mate.minY),
                CGPoint(x: mate.minX, y: mate.minY - Self.gap - size.height),
            ]
            for origin in origins {
                let rect = clamp(CGRect(origin: origin, size: size))
                guard !others.contains(where: { $0.intersects(rect) }) else { continue }
                // Rows read better than columns: going down costs a little more.
                let distance = hypot(rect.midX - target.midX, (rect.midY - target.midY) * 1.3)
                if distance < best?.distance ?? .infinity { best = (rect, distance) }
            }
        }
        return best?.rect ?? freeSpot(size: size, near: anchor)
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = min(max(rect.origin.x, 0), Self.boardSize.width - rect.width)
        rect.origin.y = min(max(rect.origin.y, 0), Self.boardSize.height - rect.height)
        return rect
    }

    // MARK: Camera

    /// Scrolls just enough to show the tile, keeping the zoom.
    func reveal(_ view: Ghostty.SurfaceView) {
        if let frame = model.frames[view.id] { revealRect(frame) }
    }

    /// Scrolls just enough to show a rect, keeping the zoom.
    func revealRect(_ frame: CGRect) {
        guard let canvas else { return }
        let visible = canvas.documentVisibleRect
        guard !visible.contains(frame) else { return }
        // Kept on the board, as a drag is: a tile near its edge would otherwise leave the view
        // off it, and the next pan would snap.
        let origin = CGPoint(x: min(max(frame.midX - visible.width / 2, 0), Self.boardSize.width - visible.width),
                             y: min(max(frame.midY - visible.height / 2, 0), Self.boardSize.height - visible.height))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            canvas.contentView.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self] in
            canvas.reflectScrolledClipView(canvas.contentView)
            self?.updateVisibility()
        }
    }

    /// Zooms in on a tile, sketch or card with a little room around it.
    func zoom(toNode id: UUID) {
        if let frame = model.frames[id] { zoom(toFit: frame.insetBy(dx: -40, dy: -40), animated: true) }
    }

    /// Shortcuts' "Focus Terminal", and others: the board moves to the tile too.
    override func focusSurface(_ view: Ghostty.SurfaceView) {
        super.focusSurface(view)
        guard surfaceTree.contains(view) else { return }
        raise(view)
        reveal(view)
    }

    /// Zooms in on the tile at full size and puts the cursor in it.
    func focusTile(_ view: Ghostty.SurfaceView) {
        expandGroup(containing: view.id)
        raise(view)
        zoom(toNode: view.id)
        Ghostty.moveFocus(to: view)
    }

    func fitAll(animated: Bool = true) {
        let ids = Set(model.nodeIDs)
        let frames = Array(model.frames.filter { ids.contains($0.key) }.values)
        guard let first = frames.first else { return }
        let all = frames.dropFirst().reduce(first) { $0.union($1) }
        zoom(toFit: all.insetBy(dx: -60, dy: -60), animated: animated)
    }

    func zoom(by factor: CGFloat) {
        guard let canvas else { return }
        let target = min(max(canvas.magnification * factor, canvas.minMagnification), canvas.maxMagnification)
        let visible = canvas.documentVisibleRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            canvas.animator().setMagnification(target, centeredAt: center)
        } completionHandler: { [weak self] in
            self?.zoomDidSettle()
        }
    }

    func zoomToActualSize() {
        guard let canvas else { return }
        if let view = focusedSurface, model.frames[view.id] != nil {
            zoom(toNode: view.id)
        } else {
            let visible = canvas.documentVisibleRect
            canvas.setMagnification(1, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
            zoomDidSettle()
        }
    }

    func zoom(toFit rect: CGRect, animated: Bool) {
        guard let canvas else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                canvas.animator().magnify(toFit: rect)
            } completionHandler: { [weak self] in
                self?.zoomDidSettle()
            }
        } else {
            canvas.magnify(toFit: rect)
            zoomDidSettle()
        }
    }

    /// A pinch or zoom ended.
    func zoomDidSettle() {
        guard let canvas else { return }
        if abs(model.zoom - canvas.magnification) > 0.001 { model.zoom = canvas.magnification }
        updateVisibility()
        scheduleSave()
    }

    /// Where the pointer is for the drag being handled, in window points (which don't move
    /// while the board scrolls under them).
    static var pointer: CGPoint? { NSApp.currentEvent?.locationInWindow }

    /// Dragging the empty board moves it under the pointer. `start` is from `pointer`.
    func pan(from start: CGPoint, origin: CGPoint) {
        guard let canvas, let now = Self.pointer else { return }
        let zoom = canvas.magnification
        let visible = canvas.contentView.bounds.size
        var next = CGPoint(x: origin.x - (now.x - start.x) / zoom, y: origin.y + (now.y - start.y) / zoom)
        next.x = min(max(next.x, 0), Self.boardSize.width - visible.width)
        next.y = min(max(next.y, 0), Self.boardSize.height - visible.height)
        canvas.contentView.scroll(to: next)
        canvas.reflectScrolledClipView(canvas.contentView)
    }

    var cameraOrigin: CGPoint { canvas?.contentView.bounds.origin ?? .zero }

    // MARK: Hidden tiles do no work

    /// Tiles scrolled out of view, and all of them when the window is hidden, stop drawing.
    func updateVisibility() {
        guard let canvas else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        let view = canvas.documentVisibleRect.insetBy(dx: -80, dy: -80)
        let collapsed = collapsedTiles
        for surfaceView in surfaceTree {
            guard let surface = surfaceView.surface, let frame = model.frames[surfaceView.id] else { continue }
            let on = windowVisible && frame.intersects(view) && !collapsed.contains(surfaceView.id)
            if visible[surfaceView.id] != on {
                visible[surfaceView.id] = on
                ghostty_surface_set_occlusion(surface, on)
            }
        }
    }

    override func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    // MARK: Saving

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let old = Dictionary(workspace.tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        workspace.tiles = surfaceTree.map { view in
            let info = VerticalTabsAgents.shared.info(for: view)
            if info == nil, agentSeen.contains(view.id), !restarting.contains(view.id) {
                // The agent quit: start a plain shell next time.
                agentSeen.remove(view.id)
                commands[view.id] = nil
            }
            let kind = info?.kind
            return BoardTile(id: view.id,
                             frame: model.frames[view.id] ?? .zero,
                             cwd: view.pwd ?? old[view.id]?.cwd,
                             agent: kind.flatMap { $0 == .unknown ? nil : $0.rawValue },
                             session: info.flatMap(ResumeAfterUpdate.session(for:)),
                             command: commands[view.id],
                             title: model.titles[view.id],
                             accounts: model.tileAccounts[view.id].map { chosen in
                                 Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.rawValue, $0.value) })
                             })
        }
        workspace.colors = model.colors.isEmpty ? nil : model.colors
        workspace.teams = model.teams.isEmpty ? nil : model.teams
        workspace.groups = model.groups.isEmpty ? nil : model.groups
        workspace.labels = model.labels.isEmpty ? nil : model.labels.map { label in
            var label = label
            label.frame = model.frames[label.id] ?? label.frame
            return label
        }
        workspace.ink = model.ink.isEmpty ? nil : model.ink
        workspace.released = model.released.isEmpty ? nil : model.released
        workspace.cards = model.cards.isEmpty ? nil : model.cards.map { card in
            var card = card
            card.frame = model.frames[card.id] ?? card.frame
            return card
        }
        workspace.sketches = model.sketches.isEmpty ? nil : model.sketches.map { sketch in
            var sketch = sketch
            sketch.frame = model.frames[sketch.id] ?? sketch.frame
            return sketch
        }
        if let canvas {
            workspace.camera = .init(origin: canvas.contentView.bounds.origin, zoom: canvas.magnification)
        }
        if let window, !window.styleMask.contains(.fullScreen) { workspace.windowFrame = window.frame }
        workspace.updated = Date()
        BoardStore.save(workspace)
    }

    // MARK: Window

    /// Whether a board can take `window`'s place: not in full screen (it has its own space).
    private static func canReplace(_ window: NSWindow) -> Bool {
        window.isVisible && !window.styleMask.contains(.fullScreen)
    }

    override func bringForward() { show() }

    /// Brings this board forward in place of the front one, which steps back out of sight.
    func show() {
        guard let window else { return }
        if !window.isVisible, let front = Self.front, front !== self, let frontWindow = front.window, Self.canReplace(frontWindow) {
            window.setFrame(frontWindow.frame, display: false)
            window.makeKeyAndOrderFront(nil)
            frontWindow.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        // Hidden boards' lists don't reload; this one may be behind.
        NotificationCenter.default.post(name: Self.boardsDidChange, object: nil)
    }

    /// Asks (over the board you're on, without switching), then closes this board, terminals
    /// and all, and deletes it for good.
    func confirmDelete() {
        guard let sheet = window?.isVisible == true ? window : Self.front?.window ?? window else { return }
        Board.confirmDelete(workspace.name, closingTerminals: !model.surfaces.isEmpty, in: sheet) { [weak self] in
            guard let self else { return }
            self.deleteOnClose = true
            // The question said the terminals close, so no second one.
            self.window?.close()
        }
    }

    /// Each board undoes its own changes: ⌘Z never reaches into a board out of sight.
    private let boardUndo = ExpiringUndoManager()

    override func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { boardUndo }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        lastShown = Date()
    }

    override func windowWillClose(_ notification: Notification) {
        closed = true
        setPaused(false)
        for brain in orchestratorBrains.values { brain.stop(quietly: true) }
        // Headless runs end with the board.
        assistant.stop()
        documents.stop()
        diagrams.cancel()
        endWiring()
        if let toolKeyMonitor { NSEvent.removeMonitor(toolKeyMonitor) }
        toolKeyMonitor = nil
        if deleteOnClose {
            BoardStore.delete(workspace.id)
        } else {
            if !Self.terminating, !leavingForClassic { workspace.open = false }
            saveNow()
        }
        // The board you were on before comes back in its place.
        if !Self.terminating, let window, window.isVisible,
           let next = Self.all.filter({ $0 !== self && $0.window?.isVisible == false && $0.window?.isMiniaturized == false })
               .max(by: { $0.lastShown < $1.lastShown }), let nextWindow = next.window {
            // A full-screen board leaves its space; the next one comes back where it was.
            if !window.styleMask.contains(.fullScreen) { nextWindow.setFrame(window.frame, display: false) }
            nextWindow.makeKeyAndOrderFront(nil)
        }
        super.windowWillClose(notification)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.boardsDidChange, object: nil)
        }
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)
        updateVisibility()
        scheduleSave()
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        scheduleSave()
    }

    // MARK: Menu and keys

    @IBAction func newTab(_ sender: Any?) {
        addTile()
    }

    @IBAction func newBoardTab(_ sender: Any?) {
        Board.newBoard(ghostty)
    }

    @IBAction func showComposer(_ sender: Any?) {
        model.showComposer = true
    }
}
#endif
