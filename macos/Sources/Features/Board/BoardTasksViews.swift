#if os(macOS)
import AppKit

/// The status of an item that was sent to an agent, under its words: a small tinted pill,
/// "working · Ada". It takes no clicks itself; the row it's in goes to the agent's tile.
final class BoardTaskChip: NSView {
    static let height: CGFloat = 16

    private let label = NSTextField(labelWithString: "")
    private var shown: (text: String, color: NSColor)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows the chip, or hides it for nil. True when its size may have changed.
    @discardableResult
    func show(_ chip: (text: String, color: NSColor)?) -> Bool {
        if chip?.text == shown?.text, chip?.color == shown?.color { return false }
        shown = chip
        isHidden = chip == nil
        label.stringValue = chip?.text ?? ""
        label.textColor = chip?.color ?? .secondaryLabelColor
        layer?.backgroundColor = chip?.color.withAlphaComponent(0.14).cgColor
        needsLayout = true
        return true
    }

    /// As wide as its words, up to `limit`.
    func width(limit: CGFloat) -> CGFloat {
        min(ceil(label.intrinsicContentSize.width) + 14, max(limit, 0))
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 7, y: floor((bounds.height - height) / 2), width: max(bounds.width - 14, 0), height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view on the board that's only there to be seen.
private final class BoardTaskGuideView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// While a kanban card is dragged off its kanban: its words follow the pointer over the
/// board, and the agent tile under it gets a ring. Dropped there, the card is sent to that agent.
@MainActor
final class BoardTaskDropGuide {
    private let ring = BoardTaskGuideView()
    private let ghost = BoardTaskGuideView()
    private let label = NSTextField(labelWithString: "")

    init(in document: NSView) {
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 9
        ring.layer?.cornerCurve = .continuous
        ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ring.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        ring.isHidden = true
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = Tellurion.chrome.raised.nsColor.cgColor
        ghost.layer?.borderColor = NSColor.controlAccentColor.cgColor
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        ghost.addSubview(label)
        document.addSubview(ring)
        document.addSubview(ghost)
    }

    /// `point` and `target` (the tile it would go to) are in board points; `text` is what the
    /// ghost says. Sizes are divided by the zoom, so they look the same at any zoom.
    func show(at point: CGPoint, target: CGRect?, text: String, zoom: CGFloat) {
        let scale = 1 / min(max(zoom, 0.25), 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.isHidden = target == nil
        if let target {
            ring.frame = target
            ring.layer?.borderWidth = 3 * scale
        }
        label.font = .systemFont(ofSize: 13 * scale, weight: .medium)
        label.stringValue = text
        let size = label.intrinsicContentSize
        let width = min(ceil(size.width), 260 * scale)
        label.frame = CGRect(x: 10 * scale, y: 6 * scale, width: width, height: ceil(size.height))
        ghost.frame = CGRect(x: point.x + 14 * scale, y: point.y + 14 * scale,
                             width: width + 20 * scale, height: ceil(size.height) + 12 * scale)
        ghost.layer?.cornerRadius = 8 * scale
        ghost.layer?.borderWidth = (target == nil ? 0 : 1.5) * scale
        ghost.alphaValue = target == nil ? 0.75 : 1
        CATransaction.commit()
    }

    func remove() {
        ring.removeFromSuperview()
        ghost.removeFromSuperview()
    }
}
#endif
