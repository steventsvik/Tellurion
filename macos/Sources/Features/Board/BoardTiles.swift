#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// The tiles on the board, as AppKit views placed in the board's document view. AppKit does
/// the hit-testing and the mouse (moving, resizing, the title bar's buttons): inside the
/// zoomable scroll view, SwiftUI gestures on the tiles don't receive clicks reliably. SwiftUI
/// only draws the title bar and the zoomed-out label, which take no clicks.
@MainActor
final class BoardTiles {
    private weak var controller: BoardController?
    private weak var document: NSView?
    private let groups: BoardGroupsView
    private var views: [UUID: BoardTileView] = [:]
    private var sketchViews: [UUID: BoardSketchView] = [:]
    private var cardViews: [UUID: BoardCardView] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(controller: BoardController, document: NSView) {
        self.controller = controller
        self.document = document
        groups = BoardGroupsView(frame: document.bounds)
        groups.controller = controller
        groups.autoresizingMask = [.width, .height]
        document.addSubview(groups, positioned: .below, relativeTo: nil)
        controller.groupsView = groups
        let model = controller.model
        // Batched to the next turn of the run loop: several of these change together.
        Publishers.Merge6(model.$surfaces.map { _ in () }, model.$frames.map { _ in () }, model.$order.map { _ in () },
                          model.$zoom.map { _ in () }, model.$agentTick.map { _ in () }, model.$focused.map { _ in () })
            .merge(with: model.$titles.map { _ in () }, model.$projects.map { _ in () }, model.$colors.map { _ in () })
            .merge(with: model.$sketches.map { _ in () }, model.$focusedSketch.map { _ in () }, model.$cards.map { _ in () })
            .merge(with: model.$paused.map { _ in () }, model.$teams.map { _ in () })
            .sink { [weak self] in self?.needsSync() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: ExtremeSettings.featuresDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
                .filter { [weak controller] note in (note.object as? NSWindow) === controller?.window })
            .sink { [weak self] _ in self?.needsSync() }
            .store(in: &cancellables)
        sync()
    }

    private var syncQueued = false

    /// One sync for everything that changed this turn of the run loop.
    private func needsSync() {
        guard !syncQueued else { return }
        syncQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.syncQueued = false
            self?.sync()
        }
    }

    func sync() {
        guard let controller, let document else { return }
        let model = controller.model
        let ids = Set(model.surfaces.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        let sketchIDs = Set(model.sketches.map(\.id))
        for (id, view) in sketchViews where !sketchIDs.contains(id) {
            view.removeFromSuperview()
            sketchViews[id] = nil
        }
        let cardIDs = Set(model.cards.map(\.id))
        for (id, view) in cardViews where !cardIDs.contains(id) {
            view.removeFromSuperview()
            cardViews[id] = nil
        }
        let motion = ExtremeSettings.motion == .full && (controller.window?.occlusionState.contains(.visible) ?? false)
        // Arranging slides the tiles; everything else (dragging, restoring) puts them straight there.
        let animate = model.animateNextLayout && motion
        model.animateNextLayout = false
        var moves: [(NSView, CGRect)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for surface in model.surfaces {
            guard let frame = model.frames[surface.id] else { continue }
            let view = views[surface.id] ?? {
                let view = BoardTileView(controller: controller, surface: surface)
                document.addSubview(view)
                views[surface.id] = view
                return view
            }()
            if view.frame != frame {
                if animate { moves.append((view, frame)) } else { view.frame = frame }
            }
            view.update(info: VerticalTabsAgents.shared.info(for: surface), name: model.titles[surface.id],
                        color: model.color(of: surface.id).map(BoardProjects.nsColor),
                        focused: model.focused, zoom: model.zoom, motion: motion)
            view.paused = model.paused.contains(surface.id)
            view.team = Self.badge(for: surface.id, in: model)
        }
        for sketch in model.sketches {
            guard let frame = model.frames[sketch.id] else { continue }
            let view = sketchViews[sketch.id] ?? {
                let view = BoardSketchView(controller: controller, sketch: sketch)
                document.addSubview(view)
                sketchViews[sketch.id] = view
                return view
            }()
            if view.frame != frame {
                if animate { moves.append((view, frame)) } else { view.frame = frame }
            }
            view.update(title: sketch.title, focused: model.focusedSketch == sketch.id, zoom: model.zoom)
        }
        for card in model.cards {
            guard let frame = model.frames[card.id] else { continue }
            let view = cardViews[card.id] ?? {
                let view = BoardCardView(controller: controller, card: card)
                document.addSubview(view)
                cardViews[card.id] = view
                return view
            }()
            if view.frame != frame {
                if animate { moves.append((view, frame)) } else { view.frame = frame }
            }
            view.update(card: card, zoom: model.zoom)
        }
        CATransaction.commit()
        if !moves.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                for (view, frame) in moves { view.animator().frame = frame }
            }
        }
        groups.update(groups: Self.groups(model), zoom: model.zoom)
        groups.update(links: controller.teamLinks(), zoom: model.zoom)
        // Back to front, without removing anything (that would take a terminal's focus).
        let order = Dictionary(model.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let nodes: [(UUID, NSView)] = views.map { ($0, $1) } + sketchViews.map { ($0, $1) } + cardViews.map { ($0, $1) }
        var rank: [ObjectIdentifier: Int] = Dictionary(nodes.map { (ObjectIdentifier($1), order[$0] ?? -1) },
                                                       uniquingKeysWith: { a, _ in a })
        rank[ObjectIdentifier(groups)] = Int.min
        let current = document.subviews.compactMap { $0 as? BoardNodeView }.map { rank[ObjectIdentifier($0)] ?? -1 }
        if current != current.sorted() || document.subviews.first !== groups {
            withUnsafePointer(to: rank) { pointer in
                document.sortSubviews({ a, b, context in
                    guard let ranks = context?.assumingMemoryBound(to: [ObjectIdentifier: Int].self).pointee else { return .orderedSame }
                    let ra = ranks[ObjectIdentifier(a)] ?? -1, rb = ranks[ObjectIdentifier(b)] ?? -1
                    return ra < rb ? .orderedAscending : ra > rb ? .orderedDescending : .orderedSame
                }, context: UnsafeMutableRawPointer(mutating: pointer))
            }
        }
    }

    /// Each project's tiles that sit together.
    static func badge(for id: UUID, in model: BoardModel) -> BoardTileTeam? {
        if let team = model.teams.first(where: { $0.lead == id }) {
            return BoardTileTeam(lead: true, text: "Lead · \(team.name)", color: team.color)
        }
        for team in model.teams {
            if let member = team.members.first(where: { $0.tile == id }) {
                return BoardTileTeam(lead: false, text: member.role, color: team.color)
            }
        }
        return nil
    }

    static func groups(_ model: BoardModel) -> [BoardGroup] {
        var byProject: [String: [(id: UUID, frame: CGRect)]] = [:]
        for surface in model.surfaces {
            guard let project = model.projects[surface.id], let frame = model.frames[surface.id] else { continue }
            byProject[project, default: []].append((surface.id, frame))
        }
        return byProject.keys.sorted().flatMap { project -> [BoardGroup] in
            let tiles = byProject[project] ?? []
            let frames = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0.frame) })
            return BoardProjects.clusters(tiles).compactMap { ids in
                guard let first = frames[ids[0]] else { return nil }
                let all = ids.dropFirst().compactMap { frames[$0] }.reduce(first) { $0.union($1) }
                return BoardGroup(project: project, color: model.colors[project] ?? 0, tiles: ids, frame: all)
            }
        }
    }
}

/// Lays its subviews out from the top, like the tile.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A hosting view that draws but never takes a click.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One terminal on the board: the title bar, the terminal and its status lights. Moving,
/// resizing and the title bar's buttons are BoardNodeView's.
final class BoardTileView: BoardNodeView {
    let surface: Ghostty.SurfaceView
    private let state = BoardTileState()
    private let focus = BoardTileFocus()
    private let clip = FlippedView()
    private let lights = FrameLights.View(frame: .zero)
    private var headerView: NSView!
    private var bodyView: NSView!
    private var overview: NSView!

    init(controller: BoardController, surface: Ghostty.SurfaceView) {
        self.surface = surface
        super.init(controller: controller, id: surface.id)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = 9
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1
        clip.layer?.backgroundColor = Extreme.chrome.ink.nsColor.cgColor
        addSubview(clip)

        let header = PassiveHostingView(rootView: BoardTileHeader(surface: surface, state: state))
        let body = NSHostingView(rootView: BoardTileTerminal(surface: surface, focus: focus)
            .environmentObject(controller.ghostty))
        let overview = PassiveHostingView(rootView: BoardTileOverview(surface: surface, state: state))
        // They take the size the tile gives them.
        header.sizingOptions = []
        body.sizingOptions = []
        overview.sizingOptions = []
        headerView = header
        bodyView = body
        self.overview = overview
        for view in [header, body, overview] as [NSView] { clip.addSubview(view) }
        overview.isHidden = true
        addSubview(lights)
        lights.isHidden = true
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.header)
        bodyView.frame = CGRect(x: 0, y: Self.header, width: bounds.width, height: max(0, bounds.height - Self.header))
        overview.frame = clip.bounds
        lights.frame = bounds.insetBy(dx: -3, dy: -3)
    }

    /// `focused` is the board's focused terminal (this one or another).
    func update(info: VerticalTabAgentInfo?, name: String?, color: NSColor?, focused board: Weak<Ghostty.SurfaceView>?,
                zoom: CGFloat, motion: Bool) {
        if focus.last?.value !== board?.value { focus.last = board }
        let focused = board?.value === surface
        if state.info != info { state.info = info }
        if state.name != name { state.name = name }
        if state.color != color { state.color = color }
        if state.focused != focused { state.focused = focused }
        if abs(state.zoom - zoom) > 0.001 { state.zoom = zoom }
        setZoom(zoom)
        overview.isHidden = zoom >= 0.45

        // The project's color; an agent that needs you, in its status color.
        let border: NSColor
        if let activity = info?.activity, AgentAlerts.isWaiting(activity) || activity == .failed {
            border = NSColor(AgentStatusPill.color(activity)).withAlphaComponent(focused ? 0.95 : 0.7)
        } else if let color {
            border = color.withAlphaComponent(focused ? 0.95 : 0.5)
        } else {
            border = focused ? Extreme.chrome.gold.nsColor.withAlphaComponent(0.8) : Extreme.chrome.lineStrong.nsColor
        }
        clip.layer?.borderColor = border.cgColor
        clip.layer?.borderWidth = focused ? 2 : 1.25

        // Corner lights: they pulse when the agent needs you and breathe while it works.
        let waiting = info.map { AgentAlerts.isWaiting($0.activity) } ?? false
        let working = info?.activity == .working
        lights.isHidden = !waiting && !working
        guard waiting || working else { return }
        let color = waiting ? Extreme.chrome.warn.nsColor.cgColor : Extreme.chrome.core.nsColor.withAlphaComponent(0.85).cgColor
        let length: CGFloat = waiting ? 22 : 18
        let pulse = waiting && motion, breathe = working && motion
        if let old = lights.config, old.0 == color, old.1 == length, old.2 == pulse, old.3 == breathe { return }
        lights.config = (color, length, pulse, breathe)
        lights.rebuild()
    }

    /// "Lead · Team" or the member's role, in its team's color.
    var team: BoardTileTeam? {
        get { state.team }
        set { if state.team != newValue { state.team = newValue } }
    }

    override var linkable: Bool { true }

    /// Its processes are stopped (see BoardPause).
    var paused: Bool {
        get { state.paused }
        set { if state.paused != newValue { state.paused = newValue } }
    }

    override func nodeMenu() -> NSMenu? {
        guard let controller else { return nil }
        return BoardTileMenu.menu(for: surface, in: controller)
    }

    override func nodeClose() { controller?.close(surface) }
    override func nodeFocus() { controller?.focusTile(surface) }
    override func nodeClick() { Ghostty.moveFocus(to: surface) }
}

/// What a tile's SwiftUI parts show.
/// The board's focused terminal, for a tile's terminal view: it changes far less often than
/// the board (which changes on every step of a drag).
final class BoardTileFocus: ObservableObject {
    @Published var last: Weak<Ghostty.SurfaceView>?
}

final class BoardTileState: ObservableObject {
    @Published var info: VerticalTabAgentInfo?
    /// The name given to the tile, if any.
    @Published var name: String?
    /// The tile's project color, if it's in a project.
    @Published var color: NSColor?
    @Published var focused = false
    @Published var zoom: CGFloat = 1
    @Published var paused = false
    @Published var team: BoardTileTeam?
}

/// A tile's place in a team, for its title bar.
struct BoardTileTeam: Equatable {
    let lead: Bool
    let text: String
    let color: Int
}

/// The title bar's picture. Its buttons sit where `BoardTileView` expects clicks.
private struct BoardTileHeader: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject var state: BoardTileState

    var body: some View {
        HStack(spacing: 8) {
            if let info = state.info {
                VerticalTabAgentLogo(kind: info.kind, tint: Extreme.text).frame(width: 14, height: 14)
            } else {
                Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).foregroundColor(Extreme.muted)
            }
            Text(BoardTileTitle.title(surface, state.info, name: state.name)).font(Extreme.font(12, weight: .semibold))
                .foregroundColor(Extreme.text).lineLimit(1)
            if let team = state.team { BoardTeamBadge(team: team) }
            if let folder = BoardTileTitle.folder(surface) {
                Text(folder).font(Extreme.font(11, weight: state.color == nil ? .medium : .semibold))
                    .foregroundColor(state.color.map(Color.init(nsColor:)) ?? Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.paused {
                BoardPausedPill()
            } else if let info = state.info {
                AgentStatusPill(activity: info.activity)
            }
            glyph("link")
            glyph("ellipsis")
            glyph("arrow.up.left.and.arrow.down.right")
            glyph("xmark")
        }
        .padding(.leading, 10).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZStack {
            state.focused ? Extreme.raised : Extreme.panel
            if let color = state.color { Color(nsColor: color).opacity(state.focused ? 0.16 : 0.09) }
        })
        .overlay(Rectangle().fill(state.color.map { Color(nsColor: $0) } ?? .clear).frame(height: 3), alignment: .top)
        .overlay(Rectangle().fill(Extreme.line).frame(height: 1), alignment: .bottom)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            .foregroundColor(Extreme.muted)
            .frame(width: 18, height: 18)
    }
}

/// The terminal itself, dimmed when another tile has focus. A Hermes tile shows Hermes's own
/// app over its (idle) terminal.
private struct BoardTileTerminal: View {
    let surface: Ghostty.SurfaceView
    @ObservedObject var focus: BoardTileFocus
    @ObservedObject private var hermes = HermesSessions.shared

    var body: some View {
        ZStack {
            Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: true)
                .ghosttyLastFocusedSurface(focus.last)
            if let view = hermes.view(for: surface) {
                HermesSessionContent(webView: view)
            }
        }
    }
}

/// Zoomed out, the title is too small to read: a large label sits over the tile.
private struct BoardTileOverview: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject var state: BoardTileState

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 6) {
                if let info = state.info {
                    VerticalTabAgentLogo(kind: info.kind, tint: Extreme.text).frame(width: 22, height: 22)
                }
                Text(BoardTileTitle.title(surface, state.info, name: state.name)).font(Extreme.font(13, weight: .semibold))
                    .foregroundColor(Extreme.text).lineLimit(1).truncationMode(.head)
                if let folder = BoardTileTitle.folder(surface) {
                    Text(folder).font(Extreme.font(11, weight: .semibold))
                        .foregroundColor(state.color.map(Color.init(nsColor:)) ?? Extreme.dim).lineLimit(1)
                }
                if state.paused {
                    BoardPausedPill()
                } else if let info = state.info {
                    Text(info.activity.label).font(Extreme.font(11, weight: .semibold))
                        .foregroundColor(AgentStatusPill.color(info.activity))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Extreme.panel.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(state.color.map { Color(nsColor: $0) } ?? .clear, lineWidth: 2))
            .scaleEffect(min(1 / max(state.zoom, 0.08), geo.size.width / 220))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// "Lead · Team 2" with a crown, or a member's role, in the team's color.
struct BoardTeamBadge: View {
    let team: BoardTileTeam

    var body: some View {
        let color = BoardProjects.color(team.color)
        Label(team.text, systemImage: team.lead ? "crown.fill" : "person.fill")
            .font(Extreme.font(10.5, weight: .semibold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize()
    }
}

/// A paused tile's badge, in place of its agent's status.
struct BoardPausedPill: View {
    var body: some View {
        Label("Paused", systemImage: "pause.fill")
            .font(Extreme.font(10.5, weight: .semibold))
            .foregroundColor(Extreme.warn)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Extreme.warn.opacity(0.14)))
    }
}

enum BoardTileTitle {
    static func title(_ surface: Ghostty.SurfaceView, _ info: VerticalTabAgentInfo?, name: String? = nil) -> String {
        if let name, !name.isEmpty { return name }
        if let info { return info.name }
        return surface.title.isEmpty ? "Terminal" : surface.title
    }

    static func folder(_ surface: Ghostty.SurfaceView) -> String? {
        guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
        let name = pwd == NSHomeDirectory() ? "~" : (pwd as NSString).lastPathComponent
        return name == surface.title ? nil : name
    }
}
#endif
