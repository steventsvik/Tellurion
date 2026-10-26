#if os(macOS)
import AppKit

/// A picture pasted into an orchestrator's command field: a thumbnail under the field, and
/// sent with the command. Kept as PNG no larger than `maxEdge` on a side, which is as much
/// as the models read.
struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let image: NSImage
    let png: Data
    let pixelSize: CGSize

    /// The longest side a sent picture keeps.
    static let maxEdge: CGFloat = 1568

    init?(image: NSImage) {
        guard let (png, size) = Self.png(image) else { return nil }
        self.image = image
        self.png = png
        pixelSize = size
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// The pictures on a pasteboard: image files (copied in the Finder), or picture data (a
    /// screenshot, a copied image). Nothing for text alone, or for files that aren't pictures.
    static func read(from pasteboard: NSPasteboard) -> [ImageAttachment] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let images = urls.isEmpty ? (NSImage(pasteboard: pasteboard).map { [$0] } ?? []) : urls.compactMap { NSImage(contentsOf: $0) }
        return images.compactMap(ImageAttachment.init(image:))
    }

    /// Whether a pasteboard may hold pictures (a cheap check, for menu validation).
    static func mayHoldImages(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// PNG data, scaled down to `maxEdge` when larger, and its size in pixels.
    static func png(_ image: NSImage, maxEdge: CGFloat = maxEdge) -> (Data, CGSize)? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxEdge / max(width, height))
        let size = CGSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else { return nil }
        return (data, size)
    }

    // MARK: Files

    /// Where sent pictures are written, for Codex (which takes them as files) and for agents
    /// told about them by path.
    static let folder = AgentTools.root.appendingPathComponent("board-agent", isDirectory: true)
        .appendingPathComponent("images", isDirectory: true)

    /// Writes the pictures as PNG files and returns their paths. Files older than a day go.
    static func save(_ images: [ImageAttachment], in folder: URL = folder, now: Date = Date()) -> [URL] {
        guard !images.isEmpty else { return [] }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        prune(folder, before: now.addingTimeInterval(-86_400))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        return images.compactMap { image in
            let url = folder.appendingPathComponent("\(stamp)-\(image.id.uuidString.prefix(8)).png")
            return (try? image.png.write(to: url)) == nil ? nil : url
        }
    }

    private static func prune(_ folder: URL, before cutoff: Date) {
        let files = FileManager.default
        guard let contents = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in contents {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date < cutoff else { continue }
            try? files.removeItem(at: url)
        }
    }
}
#endif
