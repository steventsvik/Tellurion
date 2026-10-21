#if os(macOS)
import AppKit
import SwiftUI

/// Tiles working in the same project share a color: their borders and title bars, and a
/// tinted area behind tiles of one project that sit together, labelled with the project's
/// name. Dragging the label moves the whole group.
enum BoardProjects {
    /// Bright enough on the dark board, far enough apart to tell at a glance.
    static let palette: [UInt32] = [
        0x4AA8FF, 0xFF7A6B, 0x9BD35A, 0xB18CFF, 0xF5B83D,
        0x3CC9B4, 0xF06BBF, 0xFF9F43, 0x7C9CFF, 0x6EE7B7,
    ]

    static func nsColor(_ index: Int) -> NSColor {
        let rgb = palette[index % palette.count]
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }

    private static var roots: [String: String] = [:]

    /// The project a folder is in: the top of its git checkout, or the folder itself. None for
    /// the home folder and the top of the disk, which aren't projects.
    static func project(of pwd: String?) -> String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        let path = (pwd as NSString).standardizingPath
        let home = NSHomeDirectory()
        guard path != home, path != "/" else { return nil }
        if let root = roots[path] { return root }
        var root = path
        var folder = path
        let files = FileManager.default
        while folder != "/", folder != home, !folder.isEmpty {
            if files.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) {
                root = folder
                break
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        roots[path] = root
        return root
    }

    static func name(_ project: String) -> String { (project as NSString).lastPathComponent }

    /// Tiles of one project close enough to read as one group: each within a few gaps of
    /// another. Groups of one aren't returned.
    static func clusters(_ frames: [(id: UUID, frame: CGRect)]) -> [[UUID]] {
        let reach = BoardController.gap * 2.5
        var groups: [[Int]] = []
        var seen = Set<Int>()
        for start in frames.indices where !seen.contains(start) {
            var group = [start], queue = [start]
            seen.insert(start)
            while let index = queue.popLast() {
                let near = frames[index].frame.insetBy(dx: -reach, dy: -reach)
                for other in frames.indices where !seen.contains(other) && near.intersects(frames[other].frame) {
                    seen.insert(other)
                    group.append(other)
                    queue.append(other)
                }
            }
            groups.append(group)
        }
        return groups.filter { $0.count > 1 }.map { $0.map { frames[$0].id } }
    }
}

/// One group's area on the board.
struct BoardGroup: Equatable {
    let project: String
    let color: Int
    let tiles: [UUID]
    let frame: CGRect
}

/// Behind the tiles: each group's tinted area and label, the wires from orchestrators to what's
/// wired to them, and the lines a dragged tile snaps to. Layers only, sized to what they show;
/// the view itself draws nothing.
final class BoardGroupsView: NSView {
    weak var controller: BoardController?
    static let pad: CGFloat = 16
    static let labelHeight: CGFloat = 26

    private var areas: [CALayer] = []
    private let guideLayer = CAShapeLayer()
    /// One per wire: a soft glow under the line, the line with a dot at each end, and a dot
    /// that travels along it while something on the far end works.
    private var wireLayers: [(glow: CAShapeLayer, line: CAShapeLayer, ends: CAShapeLayer, runner: CAShapeLayer)] = []
    private var links: [BoardTeamLink] = []
    private var linkZoom: CGFloat = 1
    private var linkMotion = false
    private(set) var groups: [BoardGroup] = []
    private var labelRects: [CGRect] = []
    private var zoom: CGFloat = 1
    /// While an orchestrator is connecting: its color and the groups wired to it. Each group
    /// gets a pill on its border to wire it.
    private var wiring: (color: NSColor, groups: Set<String>)?
    private var pills: [CALayer] = []
    private var pillRects: [CGRect] = []
    /// Groups you made: a frame, a header and (collapsed) a strip of their tiles, each.
    private var named: [BoardNamedGroupDisplay] = []
    private var namedZoom: CGFloat = 1
    private var namedWiring: (color: NSColor, groups: Set<String>)?
    private var namedLayers: [(frame: CAShapeLayer, header: CATextLayer, strip: CATextLayer, pill: CATextLayer)] = []
    /// Per group: the header (drag, menu), its chevron, the collapsed strip and the wire pill.
    private var namedHits: [(id: UUID, header: CGRect, chevron: CGRect, strip: CGRect?, pill: CGRect?)] = []
    private var namedDrag: UUID?

    private var dragStart: (point: CGPoint, window: CGPoint, frames: [UUID: CGRect])?
    private var dragMoved = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guideLayer.fillColor = nil
        guideLayer.lineDashPattern = [6, 4]
        guideLayer.zPosition = 10
        layer?.addSublayer(guideLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(groups: [BoardGroup], zoom: CGFloat, wiring: (color: NSColor, groups: Set<String>)? = nil) {
        let sameWiring = wiring?.color == self.wiring?.color && wiring?.groups == self.wiring?.groups
        guard groups != self.groups || abs(zoom - self.zoom) > 0.001 || !sameWiring else { return }
        self.groups = groups
        self.zoom = zoom
        self.wiring = wiring
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while areas.count > groups.count { areas.removeLast().removeFromSuperlayer() }
        while areas.count < groups.count {
            let area = CALayer()
            area.cornerCurve = .continuous
            let label = CATextLayer()
            label.alignmentMode = .left
            label.truncationMode = .end
            label.contentsScale = window?.backingScaleFactor ?? 2
            area.addSublayer(label)
            layer?.insertSublayer(area, below: guideLayer)
            areas.append(area)
        }
        // The label keeps about the same size on screen until the board is far out.
        let scale = min(1 / max(zoom, 0.08), 5)
        labelRects = []
        for (group, area) in zip(groups, areas) {
            let color = BoardProjects.nsColor(group.color)
            let rect = group.frame.insetBy(dx: -Self.pad, dy: -Self.pad)
            let labelHeight = Self.labelHeight * scale
            area.frame = CGRect(x: rect.minX, y: rect.minY - labelHeight, width: rect.width, height: rect.height + labelHeight)
            area.cornerRadius = 14
            area.backgroundColor = color.withAlphaComponent(0.07).cgColor
            area.borderColor = color.withAlphaComponent(0.4).cgColor
            area.borderWidth = 1.5 * min(scale, 2)
            guard let label = area.sublayers?.first as? CATextLayer else { continue }
            let text = "\(BoardProjects.name(group.project))  ·  \(group.tiles.count)"
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let width = min((text as NSString).size(withAttributes: [.font: font]).width + 4, rect.width / scale - 24)
            label.bounds = CGRect(x: 0, y: 0, width: max(width, 0), height: 16)
            label.anchorPoint = .zero
            label.transform = CATransform3DMakeScale(scale, scale, 1)
            label.position = CGPoint(x: 12 * scale, y: 6 * scale)
            label.contentsScale = (window?.backingScaleFactor ?? 2) * max(scale * zoom, 1)
            labelRects.append(CGRect(x: rect.minX, y: rect.minY - labelHeight, width: (width + 24) * scale, height: labelHeight))
        }
        updatePills(scale: scale)
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    /// Groups you made: a frame in the group's color around its tiles, the header
    /// "● BACKEND  12 · 11 running ⌄" above it, and (collapsed) a strip listing its tiles in
    /// place of them. While an orchestrator is connecting, a pill on the header wires it.
    func update(named groups: [BoardNamedGroupDisplay], zoom: CGFloat, wiring: (color: NSColor, groups: Set<String>)?) {
        let sameWiring = wiring?.color == namedWiring?.color && wiring?.groups == namedWiring?.groups
        guard groups != named || abs(zoom - namedZoom) > 0.001 || !sameWiring else { return }
        named = groups
        namedZoom = zoom
        namedWiring = wiring
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while namedLayers.count > groups.count {
            let last = namedLayers.removeLast()
            for layer in [last.frame, last.header, last.strip, last.pill] as [CALayer] { layer.removeFromSuperlayer() }
        }
        while namedLayers.count < groups.count {
            let frame = CAShapeLayer(), header = CATextLayer(), strip = CATextLayer(), pill = CATextLayer()
            frame.zPosition = 1
            for (layer, z) in [(header, 3), (strip, 3), (pill, 7)] as [(CATextLayer, CGFloat)] {
                layer.zPosition = z
                layer.alignmentMode = .left
                layer.truncationMode = .end
                layer.anchorPoint = .zero
            }
            pill.alignmentMode = .center
            for layer in [frame, header, strip, pill] as [CALayer] { self.layer?.insertSublayer(layer, below: guideLayer) }
            namedLayers.append((frame, header, strip, pill))
        }
        let scale = min(1 / max(zoom, 0.08), 5)
        let contents = (window?.backingScaleFactor ?? 2) * max(scale * zoom, 1)
        namedHits = []
        for (group, layers) in zip(groups, namedLayers) {
            let headerHeight = Self.labelHeight * scale
            let rect: CGRect
            var stripRect: CGRect?
            if group.collapsed {
                // A strip in place of the tiles: one line per tile.
                let size = CGSize(width: 300, height: 14 + CGFloat(max(group.rows.count, 1)) * 22)
                rect = CGRect(x: group.frame.minX, y: group.frame.minY, width: size.width * scale, height: size.height * scale)
                stripRect = rect
            } else {
                rect = group.frame.insetBy(dx: -Self.pad, dy: -Self.pad)
            }
            let outline = CGRect(x: rect.minX, y: rect.minY - headerHeight, width: rect.width, height: rect.height + headerHeight)
            layers.frame.path = CGPath(roundedRect: outline, cornerWidth: 16, cornerHeight: 16, transform: nil)
            layers.frame.fillColor = group.color.withAlphaComponent(group.collapsed ? 0.12 : 0.05).cgColor
            layers.frame.strokeColor = group.color.withAlphaComponent(0.55).cgColor
            layers.frame.lineWidth = 1.5 * min(scale, 3)
            layers.frame.lineDashPattern = nil

            // The header: ● NAME  count · running ⌄
            let bold = NSFont.systemFont(ofSize: 12, weight: .bold), plain = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            let muted = Extreme.chrome.muted.nsColor
            let text = NSMutableAttributedString(string: "● ", attributes: [.font: plain, .foregroundColor: group.color])
            text.append(NSAttributedString(string: group.name.uppercased(), attributes: [.font: bold, .foregroundColor: Extreme.chrome.text.nsColor, .kern: 0.6]))
            let counts = "  \(group.count)" + (group.running > 0 ? " · \(group.running) running" : " · idle") + "  "
            text.append(NSAttributedString(string: counts, attributes: [.font: plain, .foregroundColor: muted]))
            text.append(NSAttributedString(string: group.collapsed ? "›" : "⌄", attributes: [.font: bold, .foregroundColor: muted]))
            let width = min(text.size().width + 8, max(rect.width / scale - 20, 60))
            layers.header.string = text
            layers.header.bounds = CGRect(x: 0, y: 0, width: width, height: 18)
            layers.header.transform = CATransform3DMakeScale(scale, scale, 1)
            layers.header.position = CGPoint(x: outline.minX + 14 * scale, y: outline.minY + 5 * scale)
            layers.header.contentsScale = contents
            let header = CGRect(x: outline.minX, y: outline.minY, width: (width + 28) * scale, height: headerHeight)
            let chevronWidth = 22 * scale
            let chevron = CGRect(x: header.maxX - chevronWidth - 8 * scale, y: header.minY, width: chevronWidth + 8 * scale, height: header.height)

            // Collapsed: its tiles, one line each.
            layers.strip.isHidden = !group.collapsed
            if group.collapsed {
                let lines = NSMutableAttributedString()
                for (index, row) in group.rows.enumerated() {
                    if index > 0 { lines.append(NSAttributedString(string: "\n")) }
                    lines.append(NSAttributedString(string: "●  ", attributes: [.font: plain, .foregroundColor: row.color]))
                    lines.append(NSAttributedString(string: row.name, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                                                                                     .foregroundColor: Extreme.chrome.text.nsColor]))
                    lines.append(NSAttributedString(string: "   " + row.status, attributes: [.font: plain, .foregroundColor: muted]))
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = 22
                lines.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: lines.length))
                layers.strip.string = lines
                layers.strip.bounds = CGRect(x: 0, y: 0, width: 280, height: CGFloat(max(group.rows.count, 1)) * 22 + 4)
                layers.strip.transform = CATransform3DMakeScale(scale, scale, 1)
                layers.strip.position = CGPoint(x: rect.minX + 14 * scale, y: rect.minY + 6 * scale)
                layers.strip.contentsScale = contents
            }

            // Connecting: the pill that wires this group.
            var pillRect: CGRect?
            layers.pill.isHidden = wiring == nil
            if let wiring {
                let on = wiring.groups.contains(BoardTeams.groupKey(group.id))
                let title = on ? "✓  Wired" : "⊕  Click to wire group"
                let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                let size = (title as NSString).size(withAttributes: [.font: font])
                layers.pill.string = NSAttributedString(string: title, attributes: [
                    .font: font, .foregroundColor: on ? Extreme.chrome.ink.nsColor : wiring.color,
                ])
                layers.pill.bounds = CGRect(x: 0, y: 0, width: size.width + 22, height: 22)
                layers.pill.backgroundColor = (on ? wiring.color : Extreme.chrome.panel.nsColor).cgColor
                layers.pill.borderColor = wiring.color.withAlphaComponent(0.8).cgColor
                layers.pill.borderWidth = 1
                layers.pill.cornerRadius = 11
                layers.pill.transform = CATransform3DMakeScale(scale, scale, 1)
                let pillSize = CGSize(width: (size.width + 22) * scale, height: 22 * scale)
                let origin = CGPoint(x: outline.midX - pillSize.width / 2, y: outline.minY - pillSize.height / 2)
                layers.pill.position = origin
                layers.pill.contentsScale = contents
                pillRect = CGRect(origin: origin, size: pillSize)
            }
            namedHits.append((group.id, header, chevron, stripRect, pillRect))
        }
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    /// A click on a named group's header, chevron, strip or wire pill.
    private func namedMouseDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        let local = convert(event.locationInWindow, from: nil)
        if let id = controller.model.wiring, let hit = namedHits.first(where: { $0.pill?.contains(local) == true || $0.header.contains(local) }) {
            controller.toggleGroup(BoardTeams.groupKey(hit.id), in: id)
            return true
        }
        guard let hit = namedHits.first(where: { $0.header.contains(local) || $0.strip?.contains(local) == true }) else { return false }
        if hit.chevron.contains(local) || (hit.strip?.contains(local) == true && !hit.header.contains(local)) {
            controller.toggleCollapsed(hit.id)
            return true
        }
        if event.clickCount == 2 {
            controller.promptRenameGroup(hit.id)
            return true
        }
        guard let group = controller.namedGroup(hit.id) else { return true }
        dragMoved = false
        namedDrag = hit.id
        let frames = Dictionary(uniqueKeysWithValues: group.tiles.compactMap { id in controller.model.frames[id].map { (id, $0) } })
        dragStart = (local, event.locationInWindow, frames)
        for id in group.tiles { controller.raise(id: id) }
        return true
    }

    /// "⊕ Click to wire group" on each group's top edge while an orchestrator is connecting
    /// (✓ Wired once it is), and the group's border in the orchestrator's color.
    private func updatePills(scale: CGFloat) {
        let shown = wiring == nil ? 0 : groups.count
        while pills.count > shown { pills.removeLast().removeFromSuperlayer() }
        while pills.count < shown {
            let pill = CALayer()
            pill.cornerCurve = .continuous
            pill.zPosition = 7
            let text = CATextLayer()
            text.alignmentMode = .center
            pill.addSublayer(text)
            layer?.insertSublayer(pill, below: guideLayer)
            pills.append(pill)
        }
        pillRects = []
        guard let wiring else { return }
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for (index, (group, pill)) in zip(groups, pills).enumerated() {
            let wired = wiring.groups.contains(group.project)
            let rect = group.frame.insetBy(dx: -Self.pad, dy: -Self.pad)
            let title = wired ? "✓  Wired" : "⊕  Click to wire group"
            let size = (title as NSString).size(withAttributes: [.font: font])
            let bounds = CGRect(x: 0, y: 0, width: size.width + 22, height: 24)
            pill.bounds = bounds
            pill.cornerRadius = 12
            pill.backgroundColor = (wired ? wiring.color : Extreme.chrome.panel.nsColor).cgColor
            pill.borderColor = wiring.color.withAlphaComponent(0.8).cgColor
            pill.borderWidth = 1
            pill.transform = CATransform3DMakeScale(scale, scale, 1)
            let labelHeight = Self.labelHeight * scale
            pill.position = CGPoint(x: rect.midX, y: rect.minY - labelHeight)
            if let text = pill.sublayers?.first as? CATextLayer {
                text.string = NSAttributedString(string: title, attributes: [
                    .font: font, .foregroundColor: wired ? Extreme.chrome.ink.nsColor : wiring.color,
                ])
                text.frame = bounds.insetBy(dx: 0, dy: (bounds.height - 16) / 2)
                text.contentsScale = (window?.backingScaleFactor ?? 2) * max(scale * zoom, 1)
            }
            pillRects.append(CGRect(x: rect.midX - bounds.width * scale / 2, y: rect.minY - labelHeight - bounds.height * scale / 2,
                                    width: bounds.width * scale, height: bounds.height * scale))
            if index < areas.count {
                areas[index].borderColor = wiring.color.withAlphaComponent(wired ? 0.9 : 0.45).cgColor
            }
        }
    }

    /// The wires from orchestrators, curving from the card to each tile or group. A dot runs
    /// along a wire while something on its far end works (Core Animation, and only with
    /// motion on and the window on screen).
    func update(links: [BoardTeamLink], zoom: CGFloat, motion: Bool? = nil) {
        let motion = motion ?? linkMotion
        guard links != self.links || abs(zoom - linkZoom) > 0.001 || motion != linkMotion else { return }
        self.links = links
        linkZoom = zoom
        linkMotion = motion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while wireLayers.count > links.count {
            let last = wireLayers.removeLast()
            for layer in [last.glow, last.line, last.ends, last.runner] { layer.removeFromSuperlayer() }
        }
        while wireLayers.count < links.count {
            let glow = CAShapeLayer(), line = CAShapeLayer(), ends = CAShapeLayer(), runner = CAShapeLayer()
            for (layer, z) in [(glow, 4), (line, 5), (ends, 5.5), (runner, 6)] as [(CAShapeLayer, CGFloat)] {
                layer.zPosition = z
                layer.lineCap = .round
                self.layer?.insertSublayer(layer, below: guideLayer)
            }
            // Strokes only: filling a curve would paint the area under it.
            glow.fillColor = nil
            line.fillColor = nil
            wireLayers.append((glow, line, ends, runner))
        }
        let scale = min(1 / max(zoom, 0.08), 4)
        for (link, layers) in zip(links, wireLayers) {
            let color = BoardProjects.nsColor(link.color)
            let wire = Self.wire(from: link.from, to: link.to)
            let dot = 3.5 * scale
            let ends = CGMutablePath()
            for point in [wire.start, wire.end] { ends.addEllipse(in: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)) }
            layers.line.path = wire.path
            layers.line.strokeColor = color.withAlphaComponent(0.8).cgColor
            layers.line.lineWidth = 1.6 * scale
            layers.ends.path = ends
            layers.ends.fillColor = color.cgColor
            layers.glow.path = wire.path
            layers.glow.strokeColor = color.withAlphaComponent(link.working ? 0.22 : 0.12).cgColor
            layers.glow.lineWidth = 7 * scale
            let size = 4.5 * scale
            layers.runner.path = CGPath(ellipseIn: CGRect(x: -size, y: -size, width: size * 2, height: size * 2), transform: nil)
            layers.runner.fillColor = NSColor.white.withAlphaComponent(0.95).cgColor
            layers.runner.shadowColor = color.cgColor
            layers.runner.shadowOpacity = 1
            layers.runner.shadowRadius = 4 * scale
            layers.runner.shadowOffset = .zero
            layers.runner.shadowPath = CGPath(ellipseIn: CGRect(x: -size * 1.6, y: -size * 1.6, width: size * 3.2, height: size * 3.2),
                                              transform: nil)
            let runs = link.working && motion
            layers.runner.isHidden = !runs
            if runs {
                let travel = CAKeyframeAnimation(keyPath: "position")
                travel.path = wire.path
                travel.calculationMode = .paced
                // About the same speed on screen whatever the length.
                travel.duration = max(1.2, min(4, wire.length / 260))
                travel.repeatCount = .infinity
                layers.runner.add(travel, forKey: "travel")
            } else {
                layers.runner.removeAnimation(forKey: "travel")
            }
        }
        CATransaction.commit()
    }

    /// A wire from one rect's edge to another's, leaning horizontal or vertical like the way
    /// they sit, so it leaves and arrives square to the edges.
    struct Wire {
        let path: CGPath
        let start: CGPoint
        let end: CGPoint
        let length: CGFloat
    }

    static func wire(from: CGRect, to: CGRect) -> Wire {
        let a = edge(of: from, toward: CGPoint(x: to.midX, y: to.midY))
        let b = edge(of: to, toward: CGPoint(x: from.midX, y: from.midY))
        let dx = b.x - a.x, dy = b.y - a.y
        let path = CGMutablePath()
        path.move(to: a)
        // Which side it leaves from: the one the edge point sits on.
        let sideways = abs(a.x - from.minX) < 1 || abs(a.x - from.maxX) < 1
        if sideways {
            path.addCurve(to: b, control1: CGPoint(x: a.x + dx * 0.55, y: a.y), control2: CGPoint(x: b.x - dx * 0.55, y: b.y))
        } else {
            path.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + dy * 0.55), control2: CGPoint(x: b.x, y: b.y - dy * 0.55))
        }
        return Wire(path: path, start: a, end: b, length: hypot(dx, dy) * 1.15)
    }

    /// Where a line from the middle of `rect` toward `point` leaves it.
    static func edge(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x, dy = point.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let t = 1 / max(abs(dx) / max(rect.width / 2, 1), abs(dy) / max(rect.height / 2, 1))
        return t >= 1 ? point : CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    /// The lines the dragged tile lines up with.
    func showGuides(_ lines: [(CGPoint, CGPoint)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        for (a, b) in lines {
            path.move(to: a)
            path.addLine(to: b)
        }
        guideLayer.path = lines.isEmpty ? nil : path
        guideLayer.strokeColor = Extreme.chrome.gold.nsColor.withAlphaComponent(0.9).cgColor
        guideLayer.lineWidth = 1.2 / max(zoom, 0.08)
        guideLayer.lineDashPattern = [NSNumber(value: 6 / max(zoom, 0.08)), NSNumber(value: 4 / max(zoom, 0.08))]
        CATransaction.commit()
    }

    /// Where a group's wire pill is, in board points (tests).
    func pillRect(of project: String) -> CGRect? {
        guard let index = groups.firstIndex(where: { $0.project == project }), index < pillRects.count else { return nil }
        return pillRects[index]
    }

    // MARK: Mouse: only the labels take clicks.

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        if namedHits.contains(where: { $0.header.contains(local) || $0.strip?.contains(local) == true || $0.pill?.contains(local) == true }) {
            return self
        }
        return (labelRects + pillRects).contains { $0.contains(local) } ? self : nil
    }

    override func resetCursorRects() {
        for rect in labelRects { addCursorRect(rect, cursor: wiring == nil ? .openHand : .pointingHand) }
        for rect in pillRects { addCursorRect(rect, cursor: .pointingHand) }
        for hit in namedHits {
            addCursorRect(hit.header, cursor: .openHand)
            addCursorRect(hit.chevron, cursor: .pointingHand)
            if let strip = hit.strip { addCursorRect(strip, cursor: .pointingHand) }
            if let pill = hit.pill { addCursorRect(pill, cursor: .pointingHand) }
        }
    }

    private func group(at event: NSEvent) -> BoardGroup? {
        let local = convert(event.locationInWindow, from: nil)
        let index = pillRects.firstIndex { $0.contains(local) } ?? labelRects.firstIndex { $0.contains(local) }
        guard let index, index < groups.count else { return nil }
        return groups[index]
    }

    override func mouseDown(with event: NSEvent) {
        if namedMouseDown(event) { return }
        guard let controller, let group = group(at: event) else { return }
        // Connecting: a click on the label or the pill wires the group.
        if let id = controller.model.wiring {
            controller.toggleGroup(group.project, in: id)
            return
        }
        if event.clickCount == 2 {
            controller.zoom(toFit: group.frame.insetBy(dx: -50, dy: -50), animated: true)
            return
        }
        dragMoved = false
        let frames = Dictionary(uniqueKeysWithValues: group.tiles.compactMap { id in controller.model.frames[id].map { (id, $0) } })
        dragStart = (convert(event.locationInWindow, from: nil), event.locationInWindow, frames)
        for id in group.tiles { controller.raise(id: id) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let start = dragStart else { return }
        if !dragMoved, hypot(event.locationInWindow.x - start.window.x, event.locationInWindow.y - start.window.y) < 3 { return }
        if !dragMoved { NSCursor.closedHand.push() }
        dragMoved = true
        let now = convert(event.locationInWindow, from: nil)
        controller.moveGroup(start.frames, by: CGSize(width: now.x - start.point.x, height: now.y - start.point.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; namedDrag = nil }
        guard dragMoved else { return }
        NSCursor.pop()
        controller?.tileDidSettle()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        if let controller, let hit = namedHits.first(where: { $0.header.contains(local) || $0.strip?.contains(local) == true }) {
            return controller.groupMenu(hit.id)
        }
        guard let controller, let group = group(at: event) else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show \(BoardProjects.name(group.project))", image: nil) { [weak controller] in
            controller?.zoom(toFit: group.frame.insetBy(dx: -50, dy: -50), animated: true)
        })
        menu.addItem(ClosureMenuItem("Tidy This Group", image: nil) { [weak controller] in
            controller?.arrange(only: Set(group.tiles))
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Arrange Board by Project", image: nil) { [weak controller] in
            controller?.arrangeByProject()
        })
        return menu
    }
}
#endif
