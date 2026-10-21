#if os(macOS)
import AppKit

/// A sketch on the board: a scratchpad tile for drawing the backend (boxes, databases and
/// the arrows between them), marking up a screenshot, or thinking with a pen. Saved with the
/// board; its images live beside the board's file.
struct BoardSketch: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var elements: [SketchElement] = []
    /// Where it sits on the board (kept in the board's frames while open).
    var frame: CGRect = .zero
}

/// One thing drawn on a sketch.
struct SketchElement: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case pen, highlighter, line, arrow, rectangle, ellipse, diamond, database, text, image

        /// Kinds drawn from a box: dragged out corner to corner, resized from their corner.
        var isBox: Bool { [.rectangle, .ellipse, .diamond, .database, .text, .image].contains(self) }
        /// Kinds an arrow can attach to.
        var isTarget: Bool { [.rectangle, .ellipse, .diamond, .database, .text, .image].contains(self) }
        var isStroke: Bool { self == .pen || self == .highlighter }
        var isConnector: Bool { self == .line || self == .arrow }
    }

    var id = UUID()
    var kind: Kind
    /// A stroke's points, or a connector's two ends (used where they aren't attached).
    var points: [CGPoint] = []
    /// A box's frame, in the sketch's points.
    var frame: CGRect = .zero
    var color: Int = 0
    var width: CGFloat = 2.5
    /// A box's label, or a text's words.
    var text: String?
    /// An image's file name (see BoardSketchImages).
    var image: String?
    /// The boxes a connector's ends are attached to; they follow the boxes.
    var start: UUID?
    var end: UUID?

    /// A connector always has two ends; ones from a damaged file or another app get them.
    var repaired: SketchElement {
        guard kind.isConnector, points.count < 2 else { return self }
        var element = self
        let start = points.first ?? CGPoint(x: frame.minX, y: frame.minY)
        element.points = [start, points.count == 1 ? start : CGPoint(x: frame.maxX, y: frame.maxY)]
        return element
    }
}

// MARK: - Colors and sizes

enum SketchStyle {
    /// System colors, so they look right in light and dark.
    static let colors: [(name: String, color: NSColor)] = [
        ("Label", .labelColor), ("Blue", .systemBlue), ("Red", .systemRed), ("Orange", .systemOrange),
        ("Yellow", .systemYellow), ("Green", .systemGreen), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]

    static func color(_ index: Int) -> NSColor { colors[min(max(index, 0), colors.count - 1)].color }

    static let widths: [(name: String, width: CGFloat)] = [("Fine", 1.5), ("Medium", 2.5), ("Bold", 5)]

    static func labelFont(_ size: CGFloat = 15) -> NSFont { .systemFont(ofSize: size, weight: .medium) }
    static let textFont = NSFont.systemFont(ofSize: 17, weight: .regular)

    static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

// MARK: - Geometry

extension SketchElement {
    /// Everything the element covers, in the sketch's points.
    func bounds(in elements: [SketchElement]) -> CGRect {
        if kind.isBox { return frame }
        let ends = kind.isConnector ? connectorEnds(in: elements) : nil
        let pts = ends.map { [$0.0, $0.1] } ?? points
        guard let first = pts.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in pts.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        let pad = kind == .highlighter ? width * 4 : width + 6
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    /// Where a connector's ends are: on the edge of the boxes they're attached to, pointing at
    /// each other, or at their own points.
    func connectorEnds(in elements: [SketchElement]) -> (CGPoint, CGPoint) {
        let free0 = points.first ?? .zero, free1 = points.count > 1 ? points[1] : free0
        let a = start.flatMap { id in elements.first { $0.id == id } }
        let b = end.flatMap { id in elements.first { $0.id == id } }
        let toward0 = b.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? free1
        let toward1 = a.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? free0
        let p0 = a.map { $0.edgePoint(toward: toward0) } ?? free0
        let p1 = b.map { $0.edgePoint(toward: toward1) } ?? free1
        return (p0, p1)
    }

    /// The point on this box's outline in the direction of `target`, a few points outside it.
    func edgePoint(toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        let rx = max(frame.width / 2, 1), ry = max(frame.height / 2, 1)
        guard dx != 0 || dy != 0 else { return center }
        let t: CGFloat
        switch kind {
        case .ellipse: t = 1 / ((dx / rx) * (dx / rx) + (dy / ry) * (dy / ry)).squareRoot()
        case .diamond: t = 1 / (abs(dx) / rx + abs(dy) / ry)
        default: t = 1 / max(abs(dx) / rx, abs(dy) / ry)
        }
        let length = hypot(dx, dy)
        let gap: CGFloat = 6
        let scale = t + gap / length
        return CGPoint(x: center.x + dx * min(scale, 1), y: center.y + dy * min(scale, 1))
    }

    /// Whether a click at `point` (with `slop` points of leeway) lands on the element.
    func hit(_ point: CGPoint, slop: CGFloat, in elements: [SketchElement]) -> Bool {
        switch kind {
        case .pen, .highlighter:
            let reach = (kind == .highlighter ? width * 4 : width) / 2 + slop
            guard bounds(in: elements).insetBy(dx: -slop, dy: -slop).contains(point) else { return false }
            if points.count == 1 { return hypot(points[0].x - point.x, points[0].y - point.y) <= reach }
            return zip(points, points.dropFirst()).contains { Self.distance(point, $0, $1) <= reach }
        case .line, .arrow:
            let (a, b) = connectorEnds(in: elements)
            return Self.distance(point, a, b) <= width / 2 + slop
        case .text, .image, .rectangle, .database:
            return frame.insetBy(dx: -slop, dy: -slop).contains(point)
        case .ellipse:
            let rx = frame.width / 2 + slop, ry = frame.height / 2 + slop
            let dx = (point.x - frame.midX) / rx, dy = (point.y - frame.midY) / ry
            return dx * dx + dy * dy <= 1
        case .diamond:
            let rx = frame.width / 2 + slop, ry = frame.height / 2 + slop
            return abs(point.x - frame.midX) / rx + abs(point.y - frame.midY) / ry <= 1
        }
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Moves the element; attached connector ends stay attached.
    mutating func offset(by delta: CGSize) {
        frame = frame.offsetBy(dx: delta.width, dy: delta.height)
        points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
    }

    /// Scales a stroke's points from `old` to `new` (its bounds before and after resizing).
    mutating func scalePoints(from old: CGRect, to new: CGRect) {
        let sx = old.width > 0 ? new.width / old.width : 1, sy = old.height > 0 ? new.height / old.height : 1
        points = points.map { CGPoint(x: new.minX + ($0.x - old.minX) * sx, y: new.minY + ($0.y - old.minY) * sy) }
    }

    /// Fewer points for a finished stroke, keeping its shape (Ramer–Douglas–Peucker).
    static func simplify(_ points: [CGPoint], tolerance: CGFloat = 0.6) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var index = 0, far: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = distance(points[i], first, last)
            if d > far { far = d; index = i }
        }
        guard far > tolerance else { return [first, last] }
        let left = simplify(Array(points[...index]), tolerance: tolerance)
        let right = simplify(Array(points[index...]), tolerance: tolerance)
        return left.dropLast() + right
    }
}

// MARK: - Drawing

/// Draws a sketch's elements, on screen and when exporting.
enum SketchRenderer {
    static func draw(_ elements: [SketchElement], images: (String) -> NSImage?, in context: CGContext, editing: UUID? = nil) {
        for element in elements {
            draw(element, all: elements, images: images, in: context, hideText: element.id == editing)
        }
    }

    static func draw(_ element: SketchElement, all: [SketchElement], images: (String) -> NSImage?,
                     in context: CGContext, hideText: Bool = false) {
        let color = SketchStyle.color(element.color)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch element.kind {
        case .pen, .highlighter:
            let highlighter = element.kind == .highlighter
            context.setStrokeColor(color.withAlphaComponent(highlighter ? 0.35 : 1).cgColor)
            context.setLineWidth(highlighter ? element.width * 4 : element.width)
            if highlighter { context.setBlendMode(.normal) }
            context.addPath(smoothPath(element.points))
            if element.points.count == 1, let p = element.points.first {
                let r = (highlighter ? element.width * 4 : element.width) / 2
                context.setFillColor(color.withAlphaComponent(highlighter ? 0.35 : 1).cgColor)
                context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            } else {
                context.strokePath()
            }
        case .line, .arrow:
            let (a, b) = element.connectorEnds(in: all)
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(element.width)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(10, element.width * 4)
            // The line stops at the arrowhead's base, so its round cap doesn't poke through.
            let tip = element.kind == .arrow ? CGPoint(x: b.x - cos(angle) * head * 0.6, y: b.y - sin(angle) * head * 0.6) : b
            context.move(to: a)
            context.addLine(to: tip)
            context.strokePath()
            if element.kind == .arrow {
                let spread: CGFloat = .pi / 7
                context.move(to: b)
                context.addLine(to: CGPoint(x: b.x - cos(angle - spread) * head, y: b.y - sin(angle - spread) * head))
                context.addLine(to: CGPoint(x: b.x - cos(angle + spread) * head, y: b.y - sin(angle + spread) * head))
                context.closePath()
                context.fillPath()
            }
            if !hideText, let text = element.text, !text.isEmpty {
                drawLabel(text, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), color: color, in: context, pill: true)
            }
        case .rectangle, .ellipse, .diamond, .database:
            let path = shapePath(element.kind, element.frame)
            context.addPath(path)
            context.setFillColor(color.withAlphaComponent(0.14).cgColor)
            context.fillPath()
            context.addPath(path)
            if element.kind == .database { context.addPath(databaseLid(element.frame)) }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(element.width)
            context.strokePath()
            if !hideText, let text = element.text, !text.isEmpty {
                drawText(text, in: element.frame.insetBy(dx: 10, dy: element.kind == .database ? 14 : 8),
                         font: SketchStyle.labelFont(), color: .labelColor, in: context, centered: true)
            }
        case .text:
            if !hideText {
                drawText(element.text ?? "", in: element.frame, font: SketchStyle.textFont, color: color, in: context, centered: false)
            }
        case .image:
            if let name = element.image, let image = images(name) {
                let path = CGPath(roundedRect: element.frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
                context.addPath(path)
                context.clip()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                image.draw(in: element.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                context.setFillColor(NSColor.quaternaryLabelColor.cgColor)
                context.fill(element.frame)
            }
        }
    }

    /// A stroke through `points`, smoothed by curving through their midpoints.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func shapePath(_ kind: SketchElement.Kind, _ rect: CGRect) -> CGPath {
        switch kind {
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .diamond:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .database:
            // A cylinder: the sides, the bottom curve, and the back of the top (the lid's
            // front is drawn over it by databaseLid).
            let lid = databaseLidHeight(rect)
            let top = rect.minY + lid / 2, bottom = rect.maxY - lid / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: top))
            path.addLine(to: CGPoint(x: rect.minX, y: bottom))
            path.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: true,
                        transform: ellipse(rect, centerY: bottom, height: lid))
            path.addLine(to: CGPoint(x: rect.maxX, y: top))
            path.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: -.pi, clockwise: true,
                        transform: ellipse(rect, centerY: top, height: lid))
            path.closeSubpath()
            return path
        default:
            let radius = min(12, rect.width / 4, rect.height / 4)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }

    static func databaseLidHeight(_ rect: CGRect) -> CGFloat { min(max(rect.height * 0.2, 10), 30) }

    /// The front of the cylinder's top, drawn over the body.
    static func databaseLid(_ rect: CGRect) -> CGPath {
        let lid = databaseLidHeight(rect)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + lid / 2))
        path.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: true,
                    transform: ellipse(rect, centerY: rect.minY + lid / 2, height: lid))
        return path
    }

    /// Maps the unit circle onto an ellipse as wide as `rect`.
    private static func ellipse(_ rect: CGRect, centerY: CGFloat, height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: rect.midX, y: centerY).scaledBy(x: rect.width / 2, y: height / 2)
    }

    static func attributes(_ font: NSFont, _ color: NSColor, centered: Bool) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: SketchStyle.paragraph(centered ? .center : .left)]
    }

    /// Text in a rect (flipped context), centered vertically when `centered`.
    static func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, in context: CGContext, centered: Bool) {
        let string = NSAttributedString(string: text, attributes: attributes(font, color, centered: centered))
        let size = string.boundingRect(with: CGSize(width: max(rect.width, 1), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let y = centered ? rect.midY - size.height / 2 : rect.minY
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: max(size.height, rect.height)),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A connector's label, on a small backing so the line doesn't run through it.
    static func drawLabel(_ text: String, at center: CGPoint, color: NSColor, in context: CGContext, pill: Bool) {
        let font = SketchStyle.labelFont(13)
        let string = NSAttributedString(string: text, attributes: attributes(font, .labelColor, centered: true))
        let size = string.boundingRect(with: CGSize(width: 220, height: 200), options: [.usesLineFragmentOrigin]).size
        let rect = CGRect(x: center.x - size.width / 2 - 6, y: center.y - size.height / 2 - 3,
                          width: size.width + 12, height: size.height + 6)
        if pill {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fillPath()
        }
        drawText(text, in: rect.insetBy(dx: 6, dy: 3), font: font, color: .labelColor, in: context, centered: true)
    }

    /// The whole sketch as a picture, with a margin, for sharing and for agents.
    static func image(of elements: [SketchElement], images: @escaping (String) -> NSImage?, appearance: NSAppearance?) -> NSImage? {
        guard let first = elements.first else { return nil }
        let bounds = elements.dropFirst().reduce(first.bounds(in: elements)) { $0.union($1.bounds(in: elements)) }
            .insetBy(dx: -32, dy: -32).integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let image = NSImage(size: bounds.size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let draw = {
                context.setFillColor(NSColor.textBackgroundColor.cgColor)
                context.fill(CGRect(origin: .zero, size: bounds.size))
                context.translateBy(x: -bounds.minX, y: -bounds.minY)
                SketchRenderer.draw(elements, images: images, in: context)
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        return image
    }

    /// PNG data at twice the picture's size, sharp on Retina screens and for agents.
    static func png(_ image: NSImage, scale: CGFloat = 2) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Images

/// Pictures put on sketches, saved as files beside the board's file and loaded once.
enum BoardSketchImages {
    private static var cache: [String: NSImage] = [:]
    /// Pictures whose file is gone, so a redraw doesn't look on disk again.
    private static var missing: Set<String> = []

    static var folder: URL { BoardStore.folder.appendingPathComponent("images", isDirectory: true) }

    /// Saves a picture (as PNG, at most 2400 points on its long side) and returns its name.
    static func store(_ image: NSImage) -> String? {
        var image = image
        let longest = max(image.size.width, image.size.height)
        if longest > 2400 {
            let scale = 2400 / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let source = image
            image = NSImage(size: size, flipped: false) { rect in
                source.draw(in: rect)
                return true
            }
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        cache[name] = image
        return name
    }

    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard !missing.contains(name) else { return nil }
        // Names are ours (a UUID and .png); anything else isn't loaded.
        guard name.range(of: #"^[0-9A-F-]{36}\.png$"#, options: .regularExpression) != nil,
              let image = NSImage(contentsOf: folder.appendingPathComponent(name)) else {
            missing.insert(name)
            return nil
        }
        cache[name] = image
        return image
    }

    /// Pictures as sketch elements in a row, each at most `largest` points on its long side,
    /// starting at `origin` (or centered on it).
    static func elements(for images: [NSImage], largest: CGFloat, at origin: CGPoint, centered: Bool = false) -> [SketchElement] {
        var placed: [SketchElement] = []
        var x = origin.x
        for image in images {
            guard let name = store(image) else { continue }
            let scale = min(1, largest / max(image.size.width, image.size.height, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            var element = SketchElement(kind: .image)
            element.image = name
            element.frame = CGRect(x: centered ? x - size.width / 2 : x, y: centered ? origin.y - size.height / 2 : origin.y,
                                   width: size.width, height: size.height)
            placed.append(element)
            x += size.width + 16
        }
        return placed
    }
}
#endif
