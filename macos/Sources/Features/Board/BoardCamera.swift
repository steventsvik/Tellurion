#if os(macOS)
import Foundation

/// Where the camera goes to show something: the math behind "zoom to a tile" and "scroll a
/// tile into view". The board's agent bar covers the bottom of the canvas, so a target is
/// fitted and centred in the part above it; `covered` is that bar's height in points.
enum BoardCamera {
    struct Fit: Equatable {
        var zoom: CGFloat
        /// The clip view's bounds origin, in board coordinates (y down).
        var origin: CGPoint
    }

    /// The zoom that shows `rect` as large as the uncovered part of a `size`-point view
    /// allows, within `zooms`, and the origin that centres it there, kept on the board.
    static func fit(_ rect: CGRect, in size: CGSize, covered: CGFloat,
                    zooms: ClosedRange<CGFloat>, board: CGSize) -> Fit? {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return nil }
        let free = freeHeight(of: size.height, covered: covered)
        let zoom = min(max(min(size.width / rect.width, free / rect.height), zooms.lowerBound), zooms.upperBound)
        let visible = CGSize(width: size.width / zoom, height: size.height / zoom)
        let origin = CGPoint(x: rect.midX - visible.width / 2, y: rect.midY - free / zoom / 2)
        return Fit(zoom: zoom, origin: clamp(origin, visible: visible, board: board))
    }

    /// Where to scroll, at the current zoom, so `rect` is in the uncovered part of `visible`
    /// (both in board coordinates); nil when it already is.
    static func reveal(_ rect: CGRect, visible: CGRect, zoom: CGFloat, covered: CGFloat, board: CGSize) -> CGPoint? {
        guard zoom > 0 else { return nil }
        let free = freeHeight(of: visible.height, covered: covered / zoom)
        let uncovered = CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: free)
        guard !uncovered.contains(rect) else { return nil }
        let origin = CGPoint(x: rect.midX - visible.width / 2, y: rect.midY - free / 2)
        return clamp(origin, visible: visible.size, board: board)
    }

    /// The bar never claims more than half the view: a small window with a tall reply would
    /// otherwise leave nothing to fit into.
    private static func freeHeight(of height: CGFloat, covered: CGFloat) -> CGFloat {
        max(height - max(covered, 0), height / 2)
    }

    /// Kept on the board, as a drag is: a view past its edge would snap back on the next pan.
    private static func clamp(_ origin: CGPoint, visible: CGSize, board: CGSize) -> CGPoint {
        CGPoint(x: min(max(origin.x, 0), max(board.width - visible.width, 0)),
                y: min(max(origin.y, 0), max(board.height - visible.height, 0)))
    }
}
#endif
