#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Window

/// A board window: the list of what's on the board, the board, and the panels a classic window
/// has (Visual Fix, command history, the command palette), and the board agent's bar at the
/// bottom. Boards have no code editor or Mission Control; an Agent Map tile shows where the
/// agents are working.
struct BoardWindowView: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel
    @StateObject private var motion = WindowMotion()
    @ObservedObject private var settings = ExtremeSettings.shared
    @ObservedObject private var visualFix = VisualFixPanel.shared
    @ObservedObject private var history = CommandBlocksPanel.shared
    @AppStorage(AgentAurora.enabledKey) private var aurora = false
    @AppStorage(VisualFixPanel.widthKey) private var fixWidth: Double = VisualFixPanel.defaultWidth

    static let sidebarWidth: CGFloat = 252

    var body: some View {
        GeometryReader { geometry in
            // The list and the panels are drawn over the canvas's edges rather than beside it:
            // SwiftUI content laid out before the AppKit canvas doesn't show, content after it does.
            let panels = panelWidth(in: geometry.size.width)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    if aurora { AgentAurora(controller: controller) }
                    BoardCanvasRepresentable(controller: controller)
                    BoardToolbar(controller: controller, model: model)
                        .padding(.top, 8)
                    VStack {
                        StudioDrawingPill(diagrams: controller.diagrams)
                        Spacer()
                    }
                    .padding(.top, 52)
                    if let wiring = model.wiring {
                        VStack {
                            OrchestratorWiringBanner(controller: controller, id: wiring)
                            Spacer()
                        }
                        .padding(.top, 52)
                    }
                    // Out of the way while drawing or placing things.
                    if model.surfaces.isEmpty && model.tool == .select && model.cards.isEmpty && model.sketches.isEmpty
                        && model.labels.isEmpty && model.ink.isEmpty {
                        BoardEmptyState(controller: controller)
                    }
                    // "Your app is live" when a localhost session starts listening.
                    if settings.isOn(.localhost) {
                        LocalhostToastLayer(controller: controller).padding(.top, 34)
                    }
                    BoardCornerOverlay(controller: controller)
                    VStack {
                        Spacer()
                        HStack {
                            BoardGitChip(controller: controller)
                            Spacer()
                        }
                        .padding(.leading, 14).padding(.bottom, 14)
                    }
                    HStack(alignment: .center) {
                        BoardToolPalette(controller: controller, model: model)
                        Spacer()
                        BoardSidePalette(controller: controller, model: model)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        BoardAssistantBar(controller: controller, assistant: controller.assistant, model: model)
                    }
                }
                .padding(.leading, model.showSidebar ? Self.sidebarWidth + 1 : 0)
                .padding(.trailing, panels.total)
                if model.showSidebar {
                    HStack(spacing: 0) {
                        BoardSidebar(controller: controller, model: model)
                            .frame(width: Self.sidebarWidth)
                        Rectangle().fill(Extreme.line).frame(width: 1)
                    }
                    .frame(maxHeight: .infinity)
                }
                if panels.total > 0 {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if panels.history { CommandBlocksColumn(controller: controller) }
                        if panels.visualFix { VisualFixColumn(controller: controller, maxWidth: panels.maxVisualFix) }
                    }
                    .padding(.top, 28)
                }
                // ⌘P / ⌘⇧P over the whole window, for the tile with the cursor.
                BoardPaletteLayer(controller: controller, model: model)
                BoardRadialMenu(controller: controller, model: model)
                if model.showDocuments {
                    StudioDocumentsView(controller: controller, model: model, docs: controller.documents)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                if model.showMissionMap {
                    MissionMapView(controller: controller, model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .ignoresSafeArea()
        .background(Extreme.ink)
        .environment(\.extremeMotion, motion.active && settings.motion == .full)
        .onAppear {
            motion.attach(controller.window)
            // What a classic window's sidebar starts: the ⌃⌘ shortcuts, setup, review and undo.
            VerticalTabsMenu.shared.installIfNeeded()
            ExtremeLaunch.start()
            ReviewInbox.start()
            TurnCheckpoints.start()
        }
        .sheet(isPresented: $model.showComposer) {
            BoardComposer(controller: controller, isPresented: $model.showComposer)
        }
        .sheet(isPresented: $model.showAccounts) {
            BoardAccountsView(controller: controller, isPresented: $model.showAccounts)
        }
        .sheet(isPresented: $model.showOrchestratorComposer) {
            BoardOrchestratorComposer(controller: controller, isPresented: $model.showOrchestratorComposer)
        }
    }

    /// Which side panels are open on this board, and how wide they can be.
    private struct Panels {
        var visualFix: Bool
        var history: Bool
        var total: CGFloat
        var maxVisualFix: CGFloat
    }

    /// The board keeps at least 420 points.
    private func panelWidth(in total: CGFloat) -> Panels {
        let showFix = visualFix.isVisible(controller)
        let showHistory = history.isVisible(controller)
        let room = max(0, total - (model.showSidebar ? Self.sidebarWidth + 1 : 0) - 420 - (showHistory ? 400 : 0))
        // The Visual Fix column adds its 5-point resize handle.
        let used = (showHistory ? 400 : 0) + (showFix ? min(CGFloat(fixWidth), room) + 5 : 0)
        return Panels(visualFix: showFix, history: showHistory, total: used, maxVisualFix: room)
    }
}

/// The command palette over the board, for the tile with the cursor.
private struct BoardPaletteLayer: View {
    @ObservedObject var controller: BoardController
    @ObservedObject var model: BoardModel

    var body: some View {
        if let surface = controller.focusedSurface ?? model.focused?.value {
            TerminalCommandPaletteView(
                surfaceView: surface,
                isPresented: $controller.commandPaletteIsShowing,
                ghosttyConfig: controller.ghostty.config,
                updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                controller.performAction(action, on: surface)
            }
        }
    }
}

/// Bottom right: phone access, and update information, as in a classic window.
private struct BoardCornerOverlay: View {
    @ObservedObject var controller: BoardController
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        let phone = settings.isOn(.phone)
        let update = controller.updateOverlayIsVisible
        if phone || update {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    if phone { PhoneCornerBadge() }
                    if update, let appDelegate = NSApp.delegate as? AppDelegate {
                        UpdatePill(model: appDelegate.updateViewModel)
                    }
                }
                .padding(.bottom, 9)
                .padding(.trailing, 9)
            }
        }
    }
}

// MARK: - Toolbar

private struct BoardToolbar: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel

    var body: some View {
        HStack(spacing: 6) {
            if !model.showSidebar {
                // Room for the window's buttons.
                Spacer().frame(width: 70)
                button("sidebar.left", "Show the list") { model.showSidebar = true }
            }
            // Home, the project and its boards, live agents and usage, as far as there's room.
            ViewThatFits(in: .horizontal) {
                BoardTopBar(controller: controller, model: model)
                Color.clear.frame(width: 0, height: 0)
            }
            .padding(.leading, 12)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                button("plus", "New terminal (⌘T)") { controller.addTile() }
                button("sparkles", "Launch agents…") { model.showComposer = true }
                Menu {
                    Button { controller.addSketch() } label: { Label("Sketch", systemImage: "scribble.variable") }
                    Button { controller.addCard(.note) } label: { Label("Note", systemImage: "note.text") }
                    Button { controller.addCard(.checklist) } label: { Label("Checklist", systemImage: "checklist") }
                    Button { controller.addCard(.kanban) } label: { Label("Kanban", systemImage: "rectangle.split.3x1") }
                    Divider()
                    Button { controller.showAgentMap() } label: { Label("Agent Map", systemImage: "map") }
                    Button { model.showOrchestratorComposer = true } label: {
                        Label("Orchestrator…", systemImage: BoardCard.Kind.orchestrator.symbol)
                    }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 12, weight: .medium))
                        .foregroundColor(Extreme.text.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 26, height: 22)
                .help("Add a sketch, note, checklist, kanban board, Agent Map or orchestrator")
                button("rectangle.3.group", "Arrange by project") { controller.arrangeByProject() }
                divider
                button("minus.magnifyingglass", "Zoom out (⌥⌘-)") { controller.zoom(by: 1 / 1.4) }
                    .keyboardShortcut("-", modifiers: [.command, .option])
                Button { controller.zoomToActualSize() } label: {
                    Text("\(Int((model.zoom * 100).rounded()))%")
                        .font(Extreme.font(11, weight: .semibold)).monospacedDigit()
                        .foregroundColor(Extreme.muted).frame(width: 42)
                }
                .buttonStyle(.plain)
                .help("Actual size (⌥⌘0)")
                .keyboardShortcut("0", modifiers: [.command, .option])
                button("plus.magnifyingglass", "Zoom in (⌥⌘=)") { controller.zoom(by: 1.4) }
                    .keyboardShortcut("=", modifiers: [.command, .option])
                button("rectangle.dashed", "Show everything (⌥⌘9)") { controller.fitAll() }
                    .keyboardShortcut("9", modifiers: [.command, .option])
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Extreme.panel.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Extreme.line))
            .padding(.trailing, 10)
        }
    }

    private var divider: some View {
        Rectangle().fill(Extreme.line).frame(width: 1, height: 16).padding(.horizontal, 3)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundColor(Extreme.text.opacity(0.85))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct BoardEmptyState: View {
    let controller: BoardController

    var body: some View {
        VStack(spacing: 12) {
            Text("An empty board").font(Extreme.font(15, weight: .semibold)).foregroundColor(Extreme.text)
            Text("Add terminals and agents as tiles. Drag a tile by its title bar (it snaps beside others; hold ⌘ not to), resize it from its corner, pinch to zoom, and drag empty space to move around. Tiles in the same project share a color.")
                .font(Extreme.font(12)).foregroundColor(Extreme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button("New terminal") { controller.addTile() }
                    .buttonStyle(ExtremeButtonStyle())
                Button("New orchestrator…") { controller.model.showOrchestratorComposer = true }
                    .buttonStyle(ExtremeButtonStyle())
                Button("Launch agents…") { controller.model.showComposer = true }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: Extreme.radius, style: .continuous).fill(Extreme.panel))
        .overlay(RoundedRectangle(cornerRadius: Extreme.radius, style: .continuous).strokeBorder(Extreme.line))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The list

/// Beside the board: what's on it, those that need you first. Click one to go to it.
private struct BoardSidebar: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel
    @State private var name = ""
    @State private var boards: [BoardWorkspace] = []
    @State private var condensed = false
    @ObservedObject private var settings = ExtremeSettings.shared
    @ObservedObject private var localhost = LocalhostSessions.shared

    private struct Row: Identifiable {
        let surface: Ghostty.SurfaceView
        let info: VerticalTabAgentInfo?
        /// In a group or wired to an orchestrator: listed under it, with a line in its color.
        var wireColor: Color?
        /// The first of a group's or an orchestrator's: its name above the row.
        var heading: String?
        var headingSymbol = BoardCard.Kind.orchestrator.symbol
        var id: UUID { surface.id }
    }

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { model.showSidebar = false } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 12)).foregroundColor(Extreme.muted)
                }
                .buttonStyle(.plain).help("Hide the list").accessibilityLabel("Hide the list")
            }
            .frame(height: 28)
            .padding(.horizontal, 12).padding(.top, 6)

            TextField("Board name", text: $name, onCommit: { controller.rename(name) })
                .textFieldStyle(.plain)
                .font(Extreme.font(15, weight: .semibold))
                .foregroundColor(Extreme.text)
                .padding(.horizontal, 14)
            summary(rows).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)

            HStack(spacing: 6) {
                Button("New terminal") { controller.addTile() }.buttonStyle(ExtremeButtonStyle())
                Button("Agents…") { model.showComposer = true }.buttonStyle(ExtremeButtonStyle(prominent: true))
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
            // The classic sidebar's tools: as many icons as fit, and all of them under Tools.
            ViewThatFits(in: .horizontal) {
                toolRow(all: true)
                toolRow(all: false)
            }
            .padding(.horizontal, 12).padding(.bottom, 10)

            Rectangle().fill(Extreme.line).frame(height: 1)
            if let updates = (NSApp.delegate as? AppDelegate)?.updateViewModel {
                UpdateCard(model: updates)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.cards) { card in
                        BoardSketchRow(title: card.title,
                                       count: card.kind == .orchestrator ? controller.orchestrator(card.id).map { controller.wiredAgents($0).count } ?? 0
                                           : card.items.count,
                                       focused: false, symbol: card.kind.symbol,
                                       empty: card.kind == .orchestrator ? "Nothing wired"
                                           : card.kind == .checklist || card.kind == .kanban ? "Empty" : card.kind.title)
                            .onTapGesture {
                                controller.raise(id: card.id)
                                controller.zoom(toNode: card.id)
                                controller.cardView(card.id)?.beginTyping()
                            }
                            .contextMenu {
                                Button("Rename…") { controller.promptCardTitle(card.id) }
                                Divider()
                                Button("Close \(card.kind.title)") { controller.removeCard(card.id) }
                            }
                    }
                    ForEach(model.sketches) { sketch in
                        BoardSketchRow(title: sketch.title, count: sketch.elements.count,
                                       focused: model.focusedSketch == sketch.id)
                            .onTapGesture { controller.focusSketch(sketch.id) }
                            .contextMenu {
                                Button("Send to Agent…") { controller.sendSketch(sketch.id) }
                                Button("Copy as Picture") { controller.copySketch(sketch.id) }
                                Button("Rename…") { controller.promptSketchTitle(sketch.id) }
                                Divider()
                                Button("Close Sketch") { controller.removeSketch(sketch.id) }
                            }
                    }
                    ForEach(rows) { row in
                        if let heading = row.heading {
                            HStack(spacing: 6) {
                                Image(systemName: row.headingSymbol).font(.system(size: 9.5, weight: .semibold))
                                Text(heading.uppercased()).font(Extreme.font(10, weight: .bold)).tracking(0.6).lineLimit(1)
                            }
                            .foregroundColor(row.wireColor ?? Extreme.muted)
                            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
                        }
                        BoardSidebarRow(board: controller, surface: row.surface, info: row.info, name: model.titles[row.surface.id],
                                        color: model.color(of: row.surface.id).map(BoardProjects.color))
                            .padding(.leading, row.wireColor == nil ? 0 : 16)
                            .overlay(alignment: .leading) {
                                if let wire = row.wireColor {
                                    Rectangle().fill(wire.opacity(0.7)).frame(width: 2).padding(.leading, 6)
                                }
                            }
                            .onTapGesture { controller.focusTile(row.surface) }
                            .contextMenu { BoardTileContextMenu(surface: row.surface, board: controller) }
                    }
                }
                .padding(8)
            }
            sections
            Rectangle().fill(Extreme.line).frame(height: 1)
            boardList.padding(10)
        }
        .background(Extreme.panel)
        .onAppear {
            name = model.name
            reloadBoards()
        }
        .onChange(of: model.name) { name = $0 }
        .onReceive(NotificationCenter.default.publisher(for: BoardController.boardsDidChange)) { _ in
            // Each board's list reads every saved board; boards out of sight catch up when shown.
            if controller.window?.isVisible == true { reloadBoards() }
        }
    }

    private func toolRow(all: Bool) -> some View {
        HStack(spacing: 4) {
            NewSessionMenu(owner: controller, compact: true)
            Spacer(minLength: 0)
            if all, settings.isOn(.localhost) { LocalhostHeaderButton() }
            if all, settings.isOn(.review) { ReviewHeaderButton() }
            ToolsButton(owner: controller, condensed: $condensed)
        }
    }

    /// What the classic sidebar shows below its tabs, each only when it has something.
    @ViewBuilder
    private var sections: some View {
        let palette = VerticalTabsPalette(config: controller.ghostty.config)
        if settings.isOn(.ports) { PortsSidebarSection(owner: controller) }
        if settings.isOn(.localModels) { LocalModelsSidebarSection(owner: controller) }
        // This board's localhost servers.
        let servers = localhost.sessions.filter { session in
            localhost.surface(for: session).map { controller.surfaceTree.contains($0) } ?? false
        }
        if settings.isOn(.localhost), !servers.isEmpty {
            Rectangle().fill(Extreme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ExtremeSectionLabel("Localhost")
                    Spacer()
                    Button("Manage") { LocalhostManager.show() }
                        .buttonStyle(.plain).font(Extreme.font(10.5)).foregroundColor(.accentColor)
                        .help("Localhost manager (⌃⌘L)")
                }
                .padding(.horizontal, 6)
                ForEach(servers) { session in
                    LocalhostTabCard(session: session, controller: controller, owner: controller,
                                     isSelected: localhost.surface(for: session) === model.focused?.value)
                        .onTapGesture { localhost.focus(session) }
                }
            }
            .padding(8)
        }
        SetupSidebarChip().padding(.horizontal, 8).padding(.bottom, 6)
        if settings.isOn(.background) { HousekeepingChip().padding(.horizontal, 8).padding(.bottom, 6) }
        if settings.isOn(.usage) {
            Rectangle().fill(Extreme.line).frame(height: 1)
            UsagePanel(palette: palette)
        }
    }

    private var rows: [Row] {
        _ = model.agentTick
        // Those that need you first; within that, a project's tiles together.
        let index = Dictionary(model.surfaces.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ row: Row) -> (Int, Int, Int) {
            (rank(row.info), model.color(of: row.id) ?? .max, index[row.id] ?? 0)
        }
        let sorted = model.surfaces.map { Row(surface: $0, info: VerticalTabsAgents.shared.info(for: $0)) }
            .sorted { key($0) < key($1) }
        guard !model.teams.isEmpty || !model.groups.isEmpty else { return sorted }
        // Each group's tiles under its name, then each orchestrator's agents under its name,
        // after the rest (a tile once, under the first).
        let byID = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var placed = Set<UUID>()
        var wired: [Row] = []
        for group in model.groups {
            let tiles = group.tiles.filter { byID[$0] != nil && placed.insert($0).inserted }
            for (index, id) in tiles.enumerated() {
                guard var row = byID[id] else { continue }
                row.wireColor = Color(nsColor: group.nsColor)
                row.heading = index == 0 ? group.name : nil
                row.headingSymbol = "square.grid.2x2.fill"
                wired.append(row)
            }
        }
        for team in model.teams {
            let agents = controller.wiredAgents(team).filter { placed.insert($0.surface.id).inserted }
            for (index, agent) in agents.enumerated() {
                guard var row = byID[agent.surface.id] else { continue }
                row.wireColor = BoardProjects.color(team.color)
                row.heading = index == 0 ? controller.orchestratorName(team.id) : nil
                wired.append(row)
            }
        }
        return sorted.filter { !placed.contains($0.id) } + wired
    }

    private func rank(_ info: VerticalTabAgentInfo?) -> Int {
        switch info?.activity {
        case .needsPermission, .needsInput: return 0
        case .working: return 1
        case .failed: return 2
        case .done: return 3
        case .ready: return 4
        case .none: return 5
        }
    }

    private func summary(_ rows: [Row]) -> some View {
        let waiting = rows.filter { $0.info.map { AgentAlerts.isWaiting($0.activity) } ?? false }.count
        let working = rows.filter { $0.info?.activity == .working }.count
        let parts = [waiting > 0 ? "\(waiting) need you" : nil, working > 0 ? "\(working) working" : nil,
                     "\(rows.count) \(rows.count == 1 ? "terminal" : "terminals")"].compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(Extreme.font(11)).foregroundColor(waiting > 0 ? Extreme.warn : Extreme.muted)
    }

    // MARK: Boards

    private var boardList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ExtremeSectionLabel("Boards")
                Spacer()
                Button { Board.newBoard(controller.ghostty) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundColor(Extreme.muted)
                }
                .buttonStyle(.plain).help("New board").accessibilityLabel("New board")
            }
            ForEach(boards.prefix(8)) { board in
                let isOpen = BoardController.all.contains { $0.workspace.id == board.id }
                Button { Board.reopen(controller.ghostty, board) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(isOpen ? Extreme.live : Extreme.dim).frame(width: 5, height: 5)
                        Text(board.name).font(Extreme.font(11.5, weight: board.id == controller.workspace.id ? .semibold : .regular))
                            .foregroundColor(board.id == controller.workspace.id ? Extreme.text : Extreme.muted)
                            .lineLimit(1)
                        Spacer()
                        Text("\(board.id == controller.workspace.id ? model.surfaces.count : board.tiles.count)")
                            .font(Extreme.font(10)).foregroundColor(Extreme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in New Window") { Board.reopen(controller.ghostty, board, newWindow: true) }
                    Divider()
                    Button("Delete Board…") { Board.delete(board, from: controller) }
                }
            }
        }
    }

    private func reloadBoards() {
        boards = BoardStore.all()
    }
}

/// A sketch in the list beside the board.
private struct BoardSketchRow: View {
    let title: String
    let count: Int
    let focused: Bool
    var symbol = "scribble.variable"
    var empty = "Empty"
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundColor(Extreme.muted).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                Text(count == 0 ? empty : count == 1 ? "1 item" : "\(count) items")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(hovering || focused ? Extreme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct BoardSidebarRow: View {
    let board: BoardController
    @ObservedObject var surface: Ghostty.SurfaceView
    let info: VerticalTabAgentInfo?
    /// The name given to the tile, if any.
    let name: String?
    /// Its project's color.
    let color: Color?
    @State private var hovering = false
    @State private var showGit = false
    @State private var trackedPwd: String?
    @ObservedObject private var inbox = ReviewInbox.shared
    @ObservedObject private var git = VerticalTabsGit.shared
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if let info {
                    VerticalTabAgentLogo(kind: info.kind, tint: Extreme.text)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(Extreme.muted)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(BoardTileTitle.title(surface, info, name: name))
                    .font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                if let task = info?.detail ?? info?.task, !task.isEmpty {
                    Text(task).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(2)
                } else if let pwd = surface.pwd, (pwd as NSString).abbreviatingWithTildeInPath != surface.title {
                    Text((pwd as NSString).abbreviatingWithTildeInPath).font(Extreme.font(10.5)).foregroundColor(Extreme.dim).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let info { AgentStatusPill(activity: info.activity) }
                    Spacer(minLength: 0)
                    if inbox.item(for: surface)?.stage == .ready { ReviewPaneChip(surface: surface) }
                }
                // Answer a permission prompt without going to the tile.
                if info?.activity == .needsPermission, let prompt = AgentPermissions.prompt(on: surface) {
                    AgentPermissionButtons(surface: surface, prompt: prompt, compact: true).padding(.top, 3)
                }
                // A review loop it's in, and messages waiting to be typed into it.
                AgentMessagesLine(surface: surface, compact: true)
                branch
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .padding(.leading, color == nil ? 0 : 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Extreme.raised : .clear))
        .overlay(alignment: .leading) {
            if let color { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 7) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { track(surface.pwd) }
        .onChange(of: surface.pwd) { track($0) }
        .onDisappear { git.untrack(trackedPwd); trackedPwd = nil }
    }

    /// The tile's branch; clicking it opens the Git panel, as on a classic tab.
    @ViewBuilder
    private var branch: some View {
        if let pwd = surface.pwd, let info = git.info(for: pwd) {
            let label = HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                Text(info.branch).lineLimit(1).truncationMode(.middle)
                AheadBehindLabel(info: info)
            }
            .font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
            if settings.isOn(.git), let root = git.root(for: pwd) {
                Button { showGit = true } label: { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help("Branches, stashes, commits and pull request")
                    .popover(isPresented: $showGit, arrowEdge: .trailing) {
                        GitPanelView(controller: board, pwd: pwd, root: root) { showGit = false }
                    }
            } else {
                label
            }
        }
    }

    private func track(_ pwd: String?) {
        guard pwd != trackedPwd else { return }
        git.untrack(trackedPwd)
        git.track(pwd)
        trackedPwd = pwd
    }
}

// MARK: - Composer

/// Starts several agents (up to 12) in one folder at once, each in its own tile, with an
/// optional first task.
private struct BoardComposer: View {
    let controller: BoardController
    @Binding var isPresented: Bool
    @State private var folder: String = ""
    @State private var task = ""
    @State private var installed: [BoardAgent]?
    @State private var counts: [String: Int] = [:]
    @State private var shells = 0

    private static let limit = 12
    private var total: Int { counts.values.reduce(0, +) + shells }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Launch agents").font(Extreme.font(15, weight: .semibold)).foregroundColor(Extreme.text)

            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("Folder")
                HStack {
                    Text(folder.isEmpty ? "Home" : (folder as NSString).abbreviatingWithTildeInPath)
                        .font(Extreme.mono(11.5)).foregroundColor(Extreme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("Agents")
                if let installed {
                    if installed.isEmpty {
                        Text("No agent CLIs found on your PATH. Install Claude Code, Codex, Gemini or another, then try again.")
                            .font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                    }
                    ForEach(installed) { agent in
                        countRow(agent.kind.displayName, kind: agent.kind, value: binding(agent.binary))
                    }
                    countRow("Shell", kind: nil, value: $shells)
                } else {
                    Text("Looking for agents…").font(Extreme.font(11.5)).foregroundColor(Extreme.dim)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("First task (optional)")
                TextEditor(text: $task)
                    .font(Extreme.font(12))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
                Text("Sent as the first message to Claude Code, Codex, Gemini and Qwen Code. Other agents start without it.")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            }

            HStack {
                Text("\(total) of \(Self.limit)").font(Extreme.font(11)).foregroundColor(Extreme.muted)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(total <= 1 ? "Launch" : "Launch \(total)") { launch() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(total == 0)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Extreme.panel)
        .onAppear {
            folder = controller.workspace.folder ?? controller.focusedSurface?.pwd ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let found = BoardAgent.installed()
                DispatchQueue.main.async {
                    installed = found
                    if total == 0, let first = found.first { counts[first.binary] = 1 }
                }
            }
        }
    }

    private func binding(_ binary: String) -> Binding<Int> {
        Binding(get: { counts[binary] ?? 0 }, set: { counts[binary] = $0 })
    }

    private func countRow(_ title: String, kind: VerticalTabAgentKind?, value: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Group {
                if let kind {
                    VerticalTabAgentLogo(kind: kind, tint: Extreme.text)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(Extreme.muted)
                }
            }
            .frame(width: 16, height: 16)
            Text(title).font(Extreme.font(12)).foregroundColor(Extreme.text)
            Spacer()
            Text("\(value.wrappedValue)").font(Extreme.font(12, weight: .semibold)).monospacedDigit()
                .foregroundColor(value.wrappedValue > 0 ? Extreme.gold : Extreme.dim).frame(width: 22)
            Stepper("", value: value, in: 0...max(value.wrappedValue, value.wrappedValue + Self.limit - total))
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func launch() {
        let prompt = task.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [(agent: BoardAgent?, command: String)] = []
        for agent in installed ?? [] {
            for _ in 0..<(counts[agent.binary] ?? 0) {
                lines.append((agent, agent.command(prompt: prompt.isEmpty ? nil : prompt)))
            }
        }
        for _ in 0..<shells { lines.append((nil, "")) }
        isPresented = false
        controller.launch(Array(lines.prefix(Self.limit)), folder: folder.isEmpty ? nil : folder)
    }
}
#endif
