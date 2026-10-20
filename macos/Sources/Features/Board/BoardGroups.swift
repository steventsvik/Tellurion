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

/// Behind the tiles: each group's tinted area and label, and the lines a dragged tile snaps
/// to. Layers only, sized to what they show; the view itself draws nothing.
final class BoardGroupsView: NSView {
    weak var controller: BoardController?
    static let pad: CGFloat = 16
    static let labelHeight: CGFloat = 26

    private var areas: [CALayer] = []
    private let guideLayer = CAShapeLayer()
    private(set) var groups: [BoardGroup] = []
    private var labelRects: [CGRect] = []
    private var zoom: CGFloat = 1

    private var dragGroup: BoardGroup?
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

    func update(groups: [BoardGroup], zoom: CGFloat) {
        guard groups != self.groups || abs(zoom - self.zoom) > 0.001 else { return }
        self.groups = groups
        self.zoom = zoom
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
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
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

    // MARK: Mouse: only the labels take clicks.

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return labelRects.contains { $0.contains(local) } ? self : nil
    }

    override func resetCursorRects() {
        for rect in labelRects { addCursorRect(rect, cursor: .openHand) }
    }

    private func group(at event: NSEvent) -> BoardGroup? {
        let local = convert(event.locationInWindow, from: nil)
        guard let index = labelRects.firstIndex(where: { $0.contains(local) }), index < groups.count else { return nil }
        return groups[index]
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let group = group(at: event) else { return }
        if event.clickCount == 2 {
            controller.zoom(toFit: group.frame.insetBy(dx: -50, dy: -50), animated: true)
            dragGroup = nil
            return
        }
        dragGroup = group
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
        defer { dragGroup = nil; dragStart = nil }
        guard dragMoved else { return }
        NSCursor.pop()
        controller?.tileDidSettle()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
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
