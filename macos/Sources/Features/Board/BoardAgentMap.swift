#if os(macOS)
import AppKit

/// The Agent Map: a project's files as a map, each a block sized by how much is in it and
/// grouped by folder, with the project's agents on it. Each agent is a dot that moves to the
/// file it's reading or changing, trailing the files it came through; files an agent changed
/// keep its color, fading over a few minutes. Hover a file to see who touched it,
/// double-click it to open it or a folder to go into it, and click an agent (on the map or in
/// the list under it) to go to its terminal.
final class AgentMapContent: CardContent {
    private static let barHeight: CGFloat = 28
    private static let legendHeight: CGFloat = 34
    private static let maxFiles = 6000
    /// How long a file stays lit after an agent touches it.
    private static let fade: TimeInterval = 10 * 60

    private var root: String?
    private var tree: MapNode?
    /// The folder shown, relative to the project ("" for all of it).
    private var focus = ""
    private var cells: [MapCell] = []
    private var cellIndex: [String: Int] = [:]
    private var heat: [String: MapHeat] = [:]
    private var tracks: [UUID: AgentTrack] = [:]
    private var order: [UUID] = []
    private var nextColor = 0
    private var mapRect = CGRect.zero
    private var hovered: Int?
    private var legendHits: [(rect: CGRect, id: UUID)] = []
    private var crumbHits: [(rect: CGRect, path: String)] = []
    /// The project with symlinks resolved, to match tool paths that came the other way.
    private var realRoot: String?
    private var scanning = false
    /// Asked for while a scan ran: scan again when it's done.
    private var scanAgain = false
    private var rescanWork: DispatchWorkItem?
    /// Files agents changed that a scan didn't find (ignored by git, or past the limit): they
    /// don't start another scan.
    private var unlisted: Set<String> = []
    private var waiting: Set<String> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refreshQueued = false
    private var lastDraw = Date()
    private var trackingArea: NSTrackingArea?

    private let agentLayer = CALayer()
    private let hoverLayer = CAShapeLayer()
    private let tipBox = CALayer()
    private let tip = CATextLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        hoverLayer.fillColor = nil
        hoverLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        hoverLayer.lineWidth = 1.5
        tipBox.cornerRadius = 6
        tipBox.cornerCurve = .continuous
        tipBox.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        tipBox.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        tipBox.borderWidth = 1
        tipBox.isHidden = true
        tip.fontSize = 11
        tip.font = NSFont.systemFont(ofSize: 11)
        tip.foregroundColor = NSColor.white.cgColor
        tip.contentsScale = 4
        tip.isWrapped = true
        tipBox.addSublayer(tip)
        for sub in [agentLayer, hoverLayer, tipBox] { layer?.addSublayer(sub) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { stop() }

    // MARK: Card

    override func apply(_ card: BoardCard) {
        guard card.folder != root else { return }
        root = card.folder
        realRoot = card.folder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        focus = ""
        tree = nil
        heat = [:]
        unlisted = []
        waiting = []
        for track in tracks.values { track.remove() }
        tracks = [:]
        order = []
        relayout()
        rescan(now: true)
        refreshTracks()
    }

    private var occlusion: NSObjectProtocol?
    /// Whether the window has reported its occlusion since the map joined it. A window just
    /// shown says it's visible a moment later; until it says anything, being on screen counts.
    private var occlusionReported = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusionReported = false
        occlusion = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.occlusionReported = true
                self?.updateRunning()
            }
        }
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRunning()
    }

    /// Follows the agents only while the map can be seen: not in a board out of sight, a
    /// minimized window, or one covered up.
    private func updateRunning() {
        guard let window, window.isVisible, !window.isMiniaturized else {
            stop()
            return
        }
        if window.occlusionState.contains(.visible) || !occlusionReported { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: VerticalTabsAgents.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.queueRefresh()
        })
        // New agents, transcripts found on disk, and fading files.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshTracks()
            if !self.heat.isEmpty, Date().timeIntervalSince(self.lastDraw) > 30 { self.fadeHeat() }
        }
        refreshTracks()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        for track in tracks.values { track.feed.stop() }
    }

    /// Hook events from every agent in the app come in bursts: one refresh per turn of the run loop.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refreshTracks()
        }
    }

    /// Files fade; ones untouched for hours drop off the count.
    private func fadeHeat() {
        heat = heat.filter { Date().timeIntervalSince($0.value.date) < 4 * 3600 }
        needsDisplay = true
    }

    // MARK: Files

    private func rescan(now: Bool = false) {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 2), execute: work)
    }

    private func scan() {
        guard let root else { return }
        guard !scanning else {
            scanAgain = true
            return
        }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tree = MapNode.scan(root, limit: Self.maxFiles)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                // The project changed, or more files appeared, while this one ran.
                if self.scanAgain || self.root != root {
                    self.scanAgain = false
                    self.scan()
                    if self.root != root { return }
                }
                self.tree = tree
                self.unlisted.formUnion(self.waiting.filter { tree.find($0) == nil })
                self.waiting = []
                if tree.find(self.focus)?.isFolder != true { self.focus = "" }
                self.relayout()
            }
        }
    }

    override func layout() {
        super.layout()
        let rect = CGRect(x: 8, y: Self.barHeight, width: max(0, bounds.width - 16),
                          height: max(0, bounds.height - Self.barHeight - Self.legendHeight))
        if rect != mapRect {
            mapRect = rect
            relayout()
        }
        updateTrackingAreas()
    }

    private func relayout() {
        cells = []
        cellIndex = [:]
        hovered = nil
        hoverLayer.path = nil
        tipBox.isHidden = true
        if let top = tree?.find(focus), mapRect.width > 20, mapRect.height > 20 {
            place(top, in: mapRect, depth: 0)
            for (index, cell) in cells.enumerated() { cellIndex[cell.node.path] = index }
        }
        layoutLegend()
        needsDisplay = true
        moveAgents(animated: false)
    }

    private func place(_ node: MapNode, in rect: CGRect, depth: Int) {
        let header = depth > 0 && node.isFolder && rect.width > 60 && rect.height > 44
        cells.append(MapCell(node: node, rect: rect, depth: depth, header: header))
        guard node.isFolder, rect.width > 8, rect.height > 8 else { return }
        let inner = depth == 0 ? rect
            : CGRect(x: rect.minX + 2, y: rect.minY + (header ? 17 : 2), width: rect.width - 4, height: rect.height - (header ? 19 : 4))
        guard inner.width > 4, inner.height > 4 else { return }
        let rects = MapNode.squarify(node.children.map(\.weight), in: inner)
        for (child, childRect) in zip(node.children, rects) { place(child, in: childRect, depth: depth + 1) }
    }

    /// The block a path is drawn in: its own, or the nearest folder around it that's shown.
    private func cell(for path: String) -> MapCell? {
        var path = path
        while true {
            if let index = cellIndex[path] { return cells[index] }
            if path.isEmpty { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// A path from an agent's tool call, relative to the project, or nil when it's elsewhere.
    private func relative(_ path: String, cwd: String?) -> String? {
        guard let root, let realRoot else { return nil }
        var full = path
        if !path.hasPrefix("/") { full = ((cwd ?? root) as NSString).appendingPathComponent(path) }
        full = (full as NSString).standardizingPath
        if let inside = Self.path(full, in: root) { return inside }
        // Through a symlink, one side or the other.
        return Self.path(URL(fileURLWithPath: full).resolvingSymlinksInPath().path, in: realRoot)
    }

    private static func path(_ full: String, in root: String) -> String? {
        if full == root { return "" }
        guard full.hasPrefix(root + "/") else { return nil }
        return String(full.dropFirst(root.count + 1))
    }

    // MARK: Drawing

    private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func draw(_ dirtyRect: NSRect) {
        lastDraw = Date()
        // Being drawn means being seen: a map that missed its window's wake-up starts here.
        if timer == nil, window?.isVisible == true {
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
        let chrome = Extreme.chrome
        chrome.ink.nsColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        for cell in cells where cell.rect.intersects(dirtyRect) {
            if cell.node.isFolder {
                guard cell.depth > 0 else { continue }
                let path = NSBezierPath(roundedRect: cell.rect, xRadius: 4, yRadius: 4)
                NSColor.white.withAlphaComponent(0.035).setFill()
                path.fill()
                chrome.line.nsColor.setStroke()
                path.lineWidth = 1
                path.stroke()
                if cell.header {
                    Self.drawText(cell.node.name, in: CGRect(x: cell.rect.minX + 6, y: cell.rect.minY + 2, width: cell.rect.width - 12, height: 14),
                                  size: 10, weight: .semibold, color: chrome.muted.nsColor)
                }
                continue
            }
            let rect = cell.rect.insetBy(dx: min(0.75, cell.rect.width / 4), dy: min(0.75, cell.rect.height / 4))
            context.setFillColor(Self.tint(for: cell.node.name).cgColor)
            context.fill(rect)
            if let heat = heat[cell.node.path] {
                let age = now.timeIntervalSince(heat.date)
                let strength = max(0, 1 - age / Self.fade)
                let alpha = heat.changed ? 0.22 + 0.58 * strength : 0.1 + 0.3 * strength
                context.setFillColor(heat.color.withAlphaComponent(alpha).cgColor)
                context.fill(rect)
            }
            if rect.width > 54, rect.height > 15 {
                Self.drawText(cell.node.name, in: rect.insetBy(dx: 4, dy: 2), size: 9.5, weight: .regular,
                              color: chrome.text.nsColor.withAlphaComponent(0.78))
            }
        }
        drawBar(chrome)
        drawLegend(chrome)
        if tree == nil || tree?.children.isEmpty == true {
            let message = root == nil ? "No project. Choose one with Project in this map's menu."
                : tree == nil ? "Reading the project…" : "No files here. The folder may have moved."
            Self.drawText(message, in: mapRect.insetBy(dx: 12, dy: mapRect.height / 2 - 8),
                          size: 12, weight: .medium, color: chrome.muted.nsColor, center: true)
        }
    }

    /// The folder you're in, as a path you can click back up.
    private func drawBar(_ chrome: ChromeColors) {
        crumbHits = []
        guard let root else { return }
        var parts = [(name: (root as NSString).lastPathComponent, path: "")]
        var path = ""
        for part in focus.split(separator: "/") {
            path = path.isEmpty ? String(part) : path + "/" + part
            parts.append((String(part), path))
        }
        var x: CGFloat = 12
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            let width = Self.textWidth(part.name, size: 11.5, weight: .semibold) + 2
            let rect = CGRect(x: x, y: 7, width: width, height: 16)
            Self.drawText(part.name, in: rect, size: 11.5, weight: .semibold,
                          color: last ? chrome.text.nsColor : chrome.muted.nsColor)
            if !last { crumbHits.append((rect, part.path)) }
            x += width + 4
            if !last {
                Self.drawText("›", in: CGRect(x: x, y: 7, width: 10, height: 16), size: 11.5, weight: .regular, color: chrome.dim.nsColor)
                x += 12
            }
        }
        let touched = heat.keys.filter { $0 == focus || focus.isEmpty || $0.hasPrefix(focus + "/") }.count
        let count = tracks.count
        let summary = [count == 1 ? "1 agent" : "\(count) agents", touched == 0 ? nil : touched == 1 ? "1 file touched" : "\(touched) files touched"]
            .compactMap { $0 }.joined(separator: " · ")
        let width = Self.textWidth(summary, size: 11, weight: .regular)
        Self.drawText(summary, in: CGRect(x: bounds.width - width - 12, y: 7, width: width + 2, height: 16), size: 11,
                      weight: .regular, color: chrome.dim.nsColor)
    }

    private func drawLegend(_ chrome: ChromeColors) {
        let y = bounds.height - Self.legendHeight + 9
        if tracks.isEmpty {
            Self.drawText("Agents working in this project show up here, then move across the map as they work.",
                          in: CGRect(x: 12, y: y, width: bounds.width - 24, height: 16), size: 11, weight: .regular, color: chrome.dim.nsColor)
            return
        }
        for hit in legendHits {
            guard let track = tracks[hit.id] else { continue }
            let pill = NSBezierPath(roundedRect: hit.rect, xRadius: hit.rect.height / 2, yRadius: hit.rect.height / 2)
            chrome.raised.nsColor.setFill()
            pill.fill()
            // The agent's color, under its dot while it hasn't touched anything shown.
            track.color.setFill()
            NSBezierPath(ovalIn: CGRect(x: hit.rect.minX + 7, y: hit.rect.midY - 5, width: 10, height: 10)).fill()
            NSColor(AgentStatusPill.color(track.activity)).setFill()
            NSBezierPath(ovalIn: CGRect(x: hit.rect.maxX - 13, y: hit.rect.midY - 3, width: 6, height: 6)).fill()
            Self.drawText(track.legend, in: CGRect(x: hit.rect.minX + 26, y: hit.rect.minY + 4, width: hit.rect.width - 44, height: 14),
                          size: 10.5, weight: .medium, color: chrome.text.nsColor)
        }
    }

    private func layoutLegend() {
        legendHits = []
        var x: CGFloat = 10
        let y = bounds.height - Self.legendHeight + 6
        for id in order {
            guard let track = tracks[id] else { continue }
            let width = min(260, Self.textWidth(track.legend, size: 10.5, weight: .medium) + 48)
            guard x + width < bounds.width - 10 else { break }
            legendHits.append((CGRect(x: x, y: y, width: width, height: 22), id))
            x += width + 6
        }
    }

    private static func drawText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        style.alignment = center ? .center : .left
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    /// A quiet color per kind of file, so code, docs, styles and assets read apart.
    private static func tint(for name: String) -> NSColor {
        let ext = (name as NSString).pathExtension.lowercased()
        let hue: CGFloat
        switch ext {
        case "swift", "rs", "go", "zig", "c", "h", "m", "cpp", "java", "kt": hue = 0.58
        case "ts", "tsx", "js", "jsx", "mjs", "py", "rb", "php": hue = 0.12
        case "md", "txt", "rst", "adoc": hue = 0.33
        case "css", "scss", "html", "svelte", "vue": hue = 0.83
        case "json", "yml", "yaml", "toml", "plist", "xml", "lock": hue = 0.48
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns", "pdf": hue = 0.95
        default: return NSColor(white: 1, alpha: 0.07)
        }
        return NSColor(hue: hue, saturation: 0.35, brightness: 0.75, alpha: 0.13)
    }

    // MARK: Agents

    /// The agents whose terminals are in this project, each followed through its transcript.
    private func refreshTracks() {
        guard root != nil, timer != nil else { return }
        var seen = Set<UUID>()
        var changed = false
        for pair in TerminalWindows.surfaces {
            let surface = pair.surface
            guard let info = VerticalTabsAgents.shared.info(for: surface), info.kind != .hermes, info.kind != .unknown,
                  let pwd = surface.pwd, relative(pwd, cwd: nil) != nil else { continue }
            seen.insert(surface.id)
            let track: AgentTrack
            if let existing = tracks[surface.id] {
                track = existing
            } else {
                track = AgentTrack(surface: surface, color: AgentTrack.palette[nextColor % AgentTrack.palette.count])
                nextColor += 1
                tracks[surface.id] = track
                order.append(surface.id)
                changed = true
                agentLayer.addSublayer(track.trail)
                agentLayer.addSublayer(track.dot)
                track.feed.onItems = { [weak self, weak track] items, reset in
                    guard let self, let track else { return }
                    self.receive(items, reset: reset, for: track)
                }
            }
            let name = (pair.controller as? BoardController).flatMap { board in
                BoardTileTitle.title(surface, info, name: board.model.titles[surface.id])
            } ?? info.name
            if track.update(info: info, name: name) { changed = true }
            if let transcript = track.lookup.transcript(for: info, in: pwd), transcript != track.feed.path {
                track.feed.follow(path: transcript, kind: info.kind)
            }
        }
        for id in tracks.keys where !seen.contains(id) {
            tracks[id]?.remove()
            tracks[id] = nil
            order.removeAll { $0 == id }
            changed = true
        }
        // Most refreshes change nothing; redrawing thousands of files for them would cost.
        guard changed else { return }
        layoutLegend()
        moveAgents(animated: true)
        needsDisplay = true
    }

    private func receive(_ items: [AgentFeed.Item], reset: Bool, for track: AgentTrack) {
        if reset { track.trail.path = nil }
        var unknown = false
        let formatter = Self.dates
        for item in items where item["kind"] as? String == "tool" {
            let action = item["action"] as? String ?? "other"
            if action == "run", let command = item["command"] as? String {
                track.doing = "Running " + String(command.split(separator: "\n").first ?? "").prefix(40)
            }
            guard let raw = item["path"] as? String, let path = relative(raw, cwd: item["cwd"] as? String) else { continue }
            let date = (item["time"] as? String).flatMap { formatter.date(from: $0) } ?? Date()
            let changed = action == "edit" || action == "write"
            let name = (path as NSString).lastPathComponent
            track.doing = (changed ? "Editing " : action == "read" ? "Reading " : "Looking in ") + (name.isEmpty ? "the project" : name)
            track.visit(path)
            var spot = heat[path] ?? MapHeat(date: date, changed: changed, color: track.color, agent: track.name, action: action)
            spot.date = max(spot.date, date)
            if changed || !spot.changed {
                spot.changed = spot.changed || changed
                spot.color = track.color
                spot.agent = track.name
                spot.action = action
            }
            heat[path] = spot
            if changed, !reset {
                if tree?.find(path) == nil, !unlisted.contains(path) {
                    waiting.insert(path)
                    unknown = true
                }
                if let cell = cell(for: path) { track.ping(at: CGPoint(x: cell.rect.midX, y: cell.rect.midY)) }
            }
        }
        if unknown { rescan() }
        layoutLegend()
        moveAgents(animated: !reset)
        needsDisplay = true
    }

    /// Puts each agent on its file (agents on the same block side by side), or on its place in
    /// the list when it hasn't touched anything shown.
    private func moveAgents(animated: Bool) {
        var stacked: [String: Int] = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.7)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for id in order {
            guard let track = tracks[id] else { continue }
            let point: CGPoint
            if let path = track.path, let cell = cell(for: path) {
                let n = stacked[cell.node.path, default: 0]
                stacked[cell.node.path] = n + 1
                point = CGPoint(x: cell.rect.midX + CGFloat(n) * 14 - CGFloat(n > 0 ? 7 : 0), y: cell.rect.midY)
            } else if let hit = legendHits.first(where: { $0.id == id }) {
                point = CGPoint(x: hit.rect.minX + 12, y: hit.rect.midY)
            } else {
                point = CGPoint(x: -40, y: -40)
            }
            track.dot.position = point
            let trail = track.recent.compactMap { cell(for: $0).map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } }
            let path = CGMutablePath()
            if let first = trail.first, trail.count > 1 {
                path.move(to: first)
                for next in trail.dropFirst() { path.addLine(to: next) }
                track.trail.path = path
            } else {
                track.trail.path = nil
            }
        }
        CATransaction.commit()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func fileCell(at point: CGPoint) -> Int? {
        // The innermost block under the pointer: cells are listed outside in.
        cells.indices.last { cells[$0].depth > 0 && cells[$0].rect.contains(point) }
    }

    private func agent(at point: CGPoint) -> AgentTrack? {
        if let hit = legendHits.first(where: { $0.rect.contains(point) }) { return tracks[hit.id] }
        return order.reversed().compactMap { tracks[$0] }.first { track in
            hypot(track.dot.position.x - point.x, track.dot.position.y - point.y) < 12
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = agent(at: point) == nil ? fileCell(at: point) : nil
        guard index != hovered || index != nil else { return }
        hovered = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let index else {
            hoverLayer.path = nil
            tipBox.isHidden = true
            return
        }
        let cell = cells[index]
        hoverLayer.path = CGPath(roundedRect: cell.rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil)
        var lines = [cell.node.path.isEmpty ? cell.node.name : cell.node.path]
        if let spot = heat[cell.node.path] {
            let verb = spot.changed ? "Changed" : spot.action == "read" ? "Read" : "Looked at"
            lines.append("\(verb) by \(spot.agent) \(Self.ago(spot.date))")
        } else if cell.node.isFolder {
            let touched = heat.keys.filter { $0.hasPrefix(cell.node.path + "/") }.count
            if touched > 0 { lines.append(touched == 1 ? "1 file touched" : "\(touched) files touched") }
        }
        let text = lines.joined(separator: "\n")
        let width = min(320, lines.map { Self.textWidth($0, size: 11, weight: .regular) }.max() ?? 0) + 16
        let height = CGFloat(lines.count) * 15 + 10
        var origin = CGPoint(x: point.x + 14, y: point.y + 16)
        if origin.x + width > bounds.width - 4 { origin.x = point.x - width - 10 }
        if origin.y + height > bounds.height - 4 { origin.y = point.y - height - 10 }
        tipBox.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        tip.frame = CGRect(x: 8, y: 5, width: width - 16, height: height - 10)
        tip.string = text
        tipBox.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoverLayer.path = nil
        tipBox.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let crumb = crumbHits.first(where: { $0.rect.contains(point) }) {
            focus = crumb.path
            relayout()
            return
        }
        if let track = agent(at: point), let surface = track.surface {
            TerminalWindows.show(surface)
            return
        }
        guard event.clickCount == 2, let index = fileCell(at: point), let root else { return }
        let node = cells[index].node
        if node.isFolder {
            focus = node.path
            relayout()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (root as NSString).appendingPathComponent(node.path)))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let root, let index = fileCell(at: point) else { return super.menu(for: event) }
        let node = cells[index].node
        let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(node.path))
        let menu = NSMenu()
        if node.isFolder {
            menu.addItem(ClosureMenuItem("Show Only This Folder", image: nil) { [weak self] in
                self?.focus = node.path
                self?.relayout()
            })
        } else {
            menu.addItem(ClosureMenuItem("Open", image: nil) { NSWorkspace.shared.open(url) })
        }
        menu.addItem(ClosureMenuItem("Show in Finder", image: nil) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        menu.addItem(ClosureMenuItem("Copy Path", image: nil) { VerticalTabsActions.copy(url.path) })
        return menu
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    // MARK: Test support

    var testState: String {
        let agents = order.compactMap { tracks[$0] }.map { "\($0.name)@\($0.path ?? "-") [\($0.doing ?? "-")]" }
        let candidates = TerminalWindows.surfaces.map { pair -> String in
            let info = VerticalTabsAgents.shared.info(for: pair.surface)
            return "\(info?.kind.rawValue ?? "-")/\(pair.surface.pwd.map { relative($0, cwd: nil) ?? "outside" } ?? "nopwd")"
        }
        return "map root=\((root as NSString?)?.lastPathComponent ?? "-") focus=\(focus.isEmpty ? "/" : focus) cells=\(cells.count) "
            + "heat=\(heat.count) running=\(timer != nil) window=\(window != nil) "
            + "occluded=\(window.map { !$0.occlusionState.contains(.visible) }.map { "\($0)" } ?? "-") "
            + "layer=\(layer != nil) agentLayer=\(agentLayer.superlayer != nil) sublayers=\(agentLayer.sublayers?.count ?? 0) "
            + "candidates=\(candidates.joined(separator: " ")) agents=\(agents.joined(separator: ", "))"
    }
}

/// A file or folder on the map.
final class MapNode {
    let name: String
    /// Relative to the project; "" for the project itself.
    let path: String
    let isFolder: Bool
    var weight: Double = 0
    var children: [MapNode] = []

    init(name: String, path: String, isFolder: Bool) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
    }

    func find(_ path: String) -> MapNode? {
        guard !path.isEmpty else { return self }
        var node = self
        for part in path.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// The project's files: what git tracks plus new files it doesn't ignore, or else what's
    /// in the folder without hidden files and build output. A file's weight grows with the
    /// log of its size, so big files don't crowd out the rest.
    static func scan(_ root: String, limit: Int) -> MapNode {
        var files: [String] = []
        if FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) {
            let result = AgentTools.git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
            if result.ok { files = result.output.split(separator: "\0").map(String.init) }
        }
        if files.isEmpty { files = walk(root, limit: limit) }
        let top = MapNode(name: (root as NSString).lastPathComponent, path: "", isFolder: true)
        var folders: [String: MapNode] = ["": top]
        func folder(_ path: String) -> MapNode {
            if let node = folders[path] { return node }
            let parent = folder((path as NSString).deletingLastPathComponent)
            let node = MapNode(name: (path as NSString).lastPathComponent, path: path, isFolder: true)
            parent.children.append(node)
            folders[path] = node
            return node
        }
        for file in files.sorted().prefix(limit) {
            var info = stat()
            guard lstat((root as NSString).appendingPathComponent(file), &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let node = MapNode(name: (file as NSString).lastPathComponent, path: file, isFolder: false)
            node.weight = max(1, log2(Double(info.st_size) + 1))
            folder((file as NSString).deletingLastPathComponent).children.append(node)
        }
        top.total()
        return top
    }

    @discardableResult
    private func total() -> Double {
        guard isFolder else { return weight }
        children = children.filter { $0.total() > 0 }
        // A folder grows slower than its contents, so thousands of small files (test data,
        // assets) don't crowd out the code.
        weight = pow(children.reduce(0) { $0 + $1.weight }, 0.85)
        return weight
    }

    private static let skipped: Set<String> = [
        "node_modules", "build", "dist", "DerivedData", "Pods", "target", "vendor", "__pycache__", "venv", "zig-out",
    ]

    private static func walk(_ root: String, limit: Int) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var files: [String] = []
        while let path = walker.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            let isFolder = walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            if name.hasPrefix(".") || (isFolder && skipped.contains(name)) {
                if isFolder { walker.skipDescendants() }
                continue
            }
            if !isFolder { files.append(path) }
            if files.count >= limit { break }
        }
        return files
    }

    /// Squarified treemap: rectangles for `values` (in their order) filling `rect`, as close
    /// to square as the values allow.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var row: [Int] = []

        func worst(_ row: [Int], _ side: Double) -> Double {
            let areas = row.map { values[$0] * scale }
            let sum = areas.reduce(0, +)
            guard sum > 0, let largest = areas.max(), let smallest = areas.min(), smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
        }

        func lay(_ row: [Int]) {
            let area = row.reduce(0) { $0 + values[$1] * scale }
            if remaining.width >= remaining.height {
                let width = CGFloat(area) / remaining.height
                var y = remaining.minY
                for index in row {
                    let height = CGFloat(values[index] * scale) / width
                    result[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: remaining.width - width, height: remaining.height)
            } else {
                let height = CGFloat(area) / remaining.width
                var x = remaining.minX
                for index in row {
                    let width = CGFloat(values[index] * scale) / height
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: remaining.height - height)
            }
        }

        for index in values.indices.sorted(by: { values[$0] > values[$1] }) where values[index] > 0 {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [index], side) <= worst(row, side) {
                row.append(index)
            } else {
                lay(row)
                row = [index]
            }
        }
        if !row.isEmpty { lay(row) }
        return result
    }
}

private struct MapCell {
    let node: MapNode
    let rect: CGRect
    let depth: Int
    let header: Bool
}

/// The last time an agent touched a file, and whether it changed it.
private struct MapHeat {
    var date: Date
    var changed: Bool
    var color: NSColor
    var agent: String
    var action: String
}

/// One agent on the map: its dot, the trail of files it came through, and its transcript.
private final class AgentTrack {
    static let palette: [NSColor] = [
        .systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple,
        .systemTeal, .systemYellow, .systemRed, .systemIndigo, .systemMint,
    ]

    weak var surface: Ghostty.SurfaceView?
    let color: NSColor
    let feed = AgentFeed()
    let lookup = AgentTranscriptLookup()
    let dot = CALayer()
    let trail = CAShapeLayer()
    private let letter = CATextLayer()
    private(set) var name = "Agent"
    private(set) var activity = VerticalTabAgentActivity.ready
    /// The file it's on, relative to the project.
    private(set) var path: String?
    /// The files it came through, oldest first, ending with `path`.
    private(set) var recent: [String] = []
    /// What it's doing, for the list under the map.
    var doing: String?

    init(surface: Ghostty.SurfaceView, color: NSColor) {
        self.surface = surface
        self.color = color
        dot.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        dot.cornerRadius = 11
        dot.backgroundColor = color.cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        dot.borderWidth = 2
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.45
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
        letter.frame = CGRect(x: 0, y: 4, width: 22, height: 14)
        letter.alignmentMode = .center
        letter.fontSize = 11
        letter.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        letter.foregroundColor = NSColor.white.cgColor
        letter.contentsScale = 4
        dot.addSublayer(letter)
        trail.fillColor = nil
        trail.strokeColor = color.withAlphaComponent(0.5).cgColor
        trail.lineWidth = 2
        trail.lineCap = .round
        trail.lineJoin = .round
        trail.lineDashPattern = [1, 5]
    }

    var legend: String { [name, doing ?? activity.label].joined(separator: " · ") }

    /// Whether anything shown changed.
    func update(info: VerticalTabAgentInfo, name: String) -> Bool {
        guard name != self.name || info.activity != activity || letter.string == nil else { return false }
        self.name = name
        activity = info.activity
        letter.string = String(info.name.prefix(1)).uppercased()
        // A ring that says the agent is waiting for you.
        dot.borderColor = (AgentAlerts.isWaiting(info.activity) ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.92)).cgColor
        return true
    }

    func visit(_ path: String) {
        guard path != self.path else { return }
        self.path = path
        recent.removeAll { $0 == path }
        recent.append(path)
        if recent.count > 6 { recent.removeFirst(recent.count - 6) }
    }

    /// A ring that spreads from a file the agent just changed.
    func ping(at point: CGPoint) {
        guard let parent = dot.superlayer else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -12, y: -12, width: 24, height: 24), transform: nil)
        ring.position = point
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        parent.insertSublayer(ring, below: dot)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ping")
        CATransaction.commit()
    }

    func remove() {
        feed.stop()
        dot.removeFromSuperlayer()
        trail.removeFromSuperlayer()
    }
}
#endif
