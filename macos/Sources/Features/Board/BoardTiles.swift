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
    private var labelViews: [UUID: BoardLabelView] = [:]
    private let ink: BoardInkView
    private var cancellables: Set<AnyCancellable> = []

    init(controller: BoardController, document: NSView) {
        self.controller = controller
        self.document = document
        groups = BoardGroupsView(frame: document.bounds)
        groups.controller = controller
        groups.autoresizingMask = [.width, .height]
        document.addSubview(groups, positioned: .below, relativeTo: nil)
        controller.groupsView = groups
        ink = BoardInkView(frame: document.bounds)
        ink.controller = controller
        ink.autoresizingMask = [.width, .height]
        document.addSubview(ink)
        let model = controller.model
        // Batched to the next turn of the run loop: several of these change together.
        Publishers.Merge6(model.$surfaces.map { _ in () }, model.$frames.map { _ in () }, model.$order.map { _ in () },
                          model.$zoom.map { _ in () }, model.$agentTick.map { _ in () }, model.$focused.map { _ in () })
            .merge(with: model.$titles.map { _ in () }, model.$projects.map { _ in () }, model.$colors.map { _ in () })
            .merge(with: model.$sketches.map { _ in () }, model.$focusedSketch.map { _ in () }, model.$cards.map { _ in () })
            .merge(with: model.$paused.map { _ in () }, model.$teams.map { _ in () }, model.$wiring.map { _ in () })
            .merge(with: model.$groups.map { _ in () }, model.$labels.map { _ in () }, model.$ink.map { _ in () },
                   model.$tool.map { _ in () })
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
        // While an orchestrator is connecting: what's wired to it, in its color.
        let wiringTeam = model.wiring.flatMap { controller.orchestrator($0) }
        let wired = Set(wiringTeam.map { controller.wiredAgents($0).map(\.surface.id) } ?? [])
        let collapsed = controller.collapsedTiles
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
            view.skipsPermissions = controller.skipsPermissions(surface.id)
            view.account = controller.account(of: surface)?.initials
            if view.isHidden != collapsed.contains(surface.id) { view.isHidden = collapsed.contains(surface.id) }
            view.wire = wiringTeam.map { (BoardProjects.nsColor($0.color), wired.contains(surface.id)) }
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
        let labelIDs = Set(model.labels.map(\.id))
        for (id, view) in labelViews where !labelIDs.contains(id) {
            view.removeFromSuperview()
            labelViews[id] = nil
        }
        for label in model.labels {
            guard let frame = model.frames[label.id] else { continue }
            let view = labelViews[label.id] ?? {
                let view = BoardLabelView(controller: controller, label: label)
                document.addSubview(view)
                labelViews[label.id] = view
                return view
            }()
            if !view.isEditing, view.frame != frame { view.frame = frame }
            view.apply(label)
        }
        ink.update(model.ink)
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
        groups.update(groups: Self.groups(model), zoom: model.zoom,
                      wiring: wiringTeam.map { (BoardProjects.nsColor($0.color), Set($0.groups)) })
        groups.update(links: controller.teamLinks(), zoom: model.zoom, motion: motion)
        groups.update(named: controller.namedGroupDisplays(), zoom: model.zoom,
                      wiring: wiringTeam.map { (BoardProjects.nsColor($0.color), Set($0.groups)) })
        // Back to front, without removing anything (that would take a terminal's focus).
        let order = Dictionary(model.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let nodes: [(UUID, NSView)] = views.map { ($0, $1) } + sketchViews.map { ($0, $1) } + cardViews.map { ($0, $1) }
            + labelViews.map { ($0, $1) }
        var rank: [ObjectIdentifier: Int] = Dictionary(nodes.map { (ObjectIdentifier($1), order[$0] ?? -1) },
                                                       uniquingKeysWith: { a, _ in a })
        rank[ObjectIdentifier(groups)] = Int.min
        // Ink over everything.
        rank[ObjectIdentifier(ink)] = Int.max
        let current = document.subviews.filter { $0 is BoardNodeView || $0 is BoardLabelView }.map { rank[ObjectIdentifier($0)] ?? -1 }
        if current != current.sorted() || document.subviews.first !== groups || document.subviews.last !== ink {
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
    static func groups(_ model: BoardModel) -> [BoardGroup] {
        var byProject: [String: [(id: UUID, frame: CGRect)]] = [:]
        let grouped = Set(model.groups.flatMap(\.tiles))
        for surface in model.surfaces where !grouped.contains(surface.id) {
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

/// SwiftUI controls on the zoomed board. SwiftUI places a click by its distance from the
/// hosting view in window points, without the board's zoom, so its buttons and menus are hit
/// off target (and below about 90% miss). This keeps the hosting view in window points (the
/// container's bounds are scaled back up) and draws the content at the board's zoom with
/// SwiftUI's own scale effect, which hit-tests correctly. It looks the same as before.
protocol BoardZoomAware: AnyObject {
    func zoomChanged()
}

final class BoardZoomHost<Content: View>: NSView, BoardZoomAware {
    private final class Geometry: ObservableObject {
        @Published var size = CGSize.zero
        @Published var scale: CGFloat = 1
    }

    private struct Scaled: View {
        @ObservedObject var geometry: Geometry
        let content: Content

        var body: some View {
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(geometry.scale, anchor: .topLeading)
                .frame(width: geometry.size.width * geometry.scale, height: geometry.size.height * geometry.scale,
                       alignment: .topLeading)
        }
    }

    private let geometry = Geometry()
    private let host: NSHostingView<Scaled>
    private var pending: DispatchWorkItem?

    init(rootView: Content) {
        host = NSHostingView(rootView: Scaled(geometry: geometry, content: rootView))
        host.sizingOptions = []
        super.init(frame: .zero)
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        fit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fit()
    }

    /// Fits again once the zoom settles. Until then the content scales with the board like
    /// any view; only clicks need the new fit.
    func zoomChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fit() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func fit() {
        guard window != nil, let superview, frame.width > 0, frame.height > 0 else { return }
        // Window points per board point.
        let scale = max(superview.convert(NSSize(width: 1, height: 1), to: nil).width, 0.05)
        let size = frame.size
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        if bounds.size != scaled { bounds = CGRect(origin: .zero, size: scaled) }
        if host.frame != bounds { host.frame = bounds }
        if geometry.size != size { geometry.size = size }
        if abs(geometry.scale - scale) > 0.0001 { geometry.scale = scale }
    }
}

/// One terminal on the board: the title bar, the terminal and its status lights. Moving,
/// resizing and the title bar's buttons are BoardNodeView's.
final class BoardTileView: BoardNodeView {
    let surface: Ghostty.SurfaceView
    private let state = BoardTileState()
    private let focus = BoardTileFocus()
    private let clip = FlippedView()
    private let lights = FrameLights.View(frame: .zero)
    /// Around it while an orchestrator is connecting: solid when wired, faint when not.
    private let wireRing = CALayer()
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
        wireRing.isHidden = true
        wireRing.cornerRadius = 13
        wireRing.cornerCurve = .continuous
        layer?.addSublayer(wireRing)
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.header)
        bodyView.frame = CGRect(x: 0, y: Self.header, width: bounds.width, height: max(0, bounds.height - Self.header))
        overview.frame = clip.bounds
        lights.frame = bounds.insetBy(dx: -3, dy: -3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wireRing.frame = bounds.insetBy(dx: -5, dy: -5)
        CATransaction.commit()
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

    /// The connecting orchestrator's color, and whether this tile is wired to it.
    var wire: (color: NSColor, on: Bool)? {
        didSet {
            guard wire?.color != oldValue?.color || wire?.on != oldValue?.on else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            wireRing.isHidden = wire == nil
            if let wire {
                wireRing.borderColor = wire.color.withAlphaComponent(wire.on ? 0.95 : 0.3).cgColor
                wireRing.borderWidth = (wire.on ? 3 : 1.5) / max(zoom, 0.25)
                wireRing.backgroundColor = wire.color.withAlphaComponent(wire.on ? 0.08 : 0).cgColor
            }
            CATransaction.commit()
            window?.invalidateCursorRects(for: self)
        }
    }

    override var wirable: Bool { true }

    /// The ring stays the same width on screen at any zoom.
    override func setZoom(_ zoom: CGFloat) {
        super.setZoom(zoom)
        guard let wire, !wireRing.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wireRing.borderWidth = (wire.on ? 3 : 1.5) / max(self.zoom, 0.25)
        CATransaction.commit()
    }

    override var tileButtons: Bool { true }

    override func nodeRestart() { controller?.restartTile(surface) }

    override func nodeDuplicate() { controller?.duplicateTile(surface) }

    /// The initials of the account profile its agent uses (not shown for your usual one).
    var account: String? {
        get { state.account }
        set { if state.account != newValue { state.account = newValue } }
    }

    /// Started with permission prompts skipped: a red badge says so.
    var skipsPermissions: Bool {
        get { state.skipsPermissions }
        set { if state.skipsPermissions != newValue { state.skipsPermissions = newValue } }
    }

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
    @Published var skipsPermissions = false
    @Published var account: String?
}

/// A tile whose agent runs without asking permission.
struct BoardSkipPill: View {
    var body: some View {
        Label("NO PROMPTS", systemImage: "exclamationmark.shield.fill")
            .font(Extreme.font(9.5, weight: .bold))
            .foregroundColor(.red)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.14)))
            .fixedSize()
            .help("Started with permission prompts skipped: it runs commands and edits files without asking.")
    }
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
            if let folder = BoardTileTitle.folder(surface) {
                Text(folder).font(Extreme.font(11, weight: state.color == nil ? .medium : .semibold))
                    .foregroundColor(state.color.map(Color.init(nsColor:)) ?? Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.paused {
                BoardPausedPill()
            } else if let info = state.info {
                AgentStatusPill(activity: info.activity, caps: true)
            }
            if let account = state.account {
                Text(account).font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 5).frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Extreme.core))
                    .help("Signed in with another account")
            }
            if state.skipsPermissions { BoardSkipPill() }
            glyph("arrow.clockwise").help("Restart")
            glyph("plus.square.on.square").help("Duplicate")
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
