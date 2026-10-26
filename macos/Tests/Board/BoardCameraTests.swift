import Foundation
import Testing
@testable import Ghostty

/// The camera math: what the board zooms to or reveals lands in the part of the view above
/// the agent bar, not under it.
struct BoardCameraTests {
    private let board = CGSize(width: 24000, height: 16000)
    private let view = CGSize(width: 1200, height: 800)
    private let zooms: ClosedRange<CGFloat> = 0.08...1
    /// A tile with its 40-point room, bigger than the view so the zoom isn't clamped.
    private let tile = CGRect(x: 5000, y: 4000, width: 2240, height: 1520)

    /// Where a board point lands in the view, in points from its top-left corner.
    private func inView(_ point: CGPoint, _ fit: BoardCamera.Fit) -> CGPoint {
        CGPoint(x: (point.x - fit.origin.x) * fit.zoom, y: (point.y - fit.origin.y) * fit.zoom)
    }

    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

    @Test func withNoBarTheRectFillsTheViewCentred() throws {
        let fit = try #require(BoardCamera.fit(tile, in: view, covered: 0, zooms: zooms, board: board))
        #expect(near(fit.zoom, 800 / 1520))
        let center = inView(CGPoint(x: tile.midX, y: tile.midY), fit)
        #expect(near(center.x, 600) && near(center.y, 400))
        #expect(near(inView(CGPoint(x: tile.minX, y: tile.maxY), fit).y, 800))
    }

    @Test func withABarTheRectFitsAndCentresAboveIt() throws {
        let fit = try #require(BoardCamera.fit(tile, in: view, covered: 120, zooms: zooms, board: board))
        #expect(near(fit.zoom, 680 / 1520))
        let center = inView(CGPoint(x: tile.midX, y: tile.midY), fit)
        #expect(near(center.x, 600) && near(center.y, 340))
        let bottom = inView(CGPoint(x: tile.minX, y: tile.maxY), fit).y
        #expect(near(bottom, 680) && bottom <= 800 - 120)
    }

    @Test func aSmallRectStaysAtFullSizeAboveTheBar() throws {
        let small = CGRect(x: 5000, y: 4000, width: 300, height: 200)
        let fit = try #require(BoardCamera.fit(small, in: view, covered: 120, zooms: zooms, board: board))
        #expect(fit.zoom == 1)
        #expect(near(inView(CGPoint(x: small.midX, y: small.midY), fit).y, 340))
        #expect(near(inView(CGPoint(x: small.midX, y: small.midY), fit).x, 600))
    }

    @Test func theCameraStaysOnTheBoard() throws {
        let corner = CGRect(x: 0, y: 0, width: 2240, height: 1520)
        let top = try #require(BoardCamera.fit(corner, in: view, covered: 120, zooms: zooms, board: board))
        #expect(top.origin == .zero)
        let far = CGRect(x: board.width - 2240, y: board.height - 1520, width: 2240, height: 1520)
        let bottom = try #require(BoardCamera.fit(far, in: view, covered: 120, zooms: zooms, board: board))
        #expect(near(bottom.origin.x, board.width - view.width / bottom.zoom))
        #expect(near(bottom.origin.y, board.height - view.height / bottom.zoom))
    }

    @Test func theBarNeverTakesMoreThanHalfTheView() throws {
        let fit = try #require(BoardCamera.fit(tile, in: view, covered: 700, zooms: zooms, board: board))
        #expect(near(fit.zoom, 400 / 1520))
        #expect(near(inView(CGPoint(x: tile.minX, y: tile.maxY), fit).y, 400))
    }

    @Test func emptyRectsAndViewsFitNothing() {
        #expect(BoardCamera.fit(.zero, in: view, covered: 0, zooms: zooms, board: board) == nil)
        #expect(BoardCamera.fit(tile, in: .zero, covered: 0, zooms: zooms, board: board) == nil)
    }

    @Test func revealLeavesARectThatIsAlreadyAboveTheBarAlone() {
        // The view at zoom 0.5 shows 2400 × 1600 board points; a 120-point bar covers the last 240.
        let visible = CGRect(x: 4000, y: 3000, width: 2400, height: 1600)
        let shown = CGRect(x: 5000, y: 3500, width: 400, height: 200)
        #expect(BoardCamera.reveal(shown, visible: visible, zoom: 0.5, covered: 120, board: board) == nil)
        let underTheBar = CGRect(x: 5000, y: 4300, width: 400, height: 200)
        #expect(BoardCamera.reveal(underTheBar, visible: visible, zoom: 0.5, covered: 0, board: board) == nil)
    }

    @Test func revealCentresARectUnderTheBarInTheUncoveredPart() throws {
        let visible = CGRect(x: 4000, y: 3000, width: 2400, height: 1600)
        let underTheBar = CGRect(x: 5000, y: 4300, width: 400, height: 200)
        let origin = try #require(BoardCamera.reveal(underTheBar, visible: visible, zoom: 0.5, covered: 120, board: board))
        #expect(near(origin.x, 4000))
        #expect(near(origin.y, 4400 - 1360 / 2))
        let off = CGRect(x: 100, y: 100, width: 400, height: 200)
        #expect(BoardCamera.reveal(off, visible: visible, zoom: 0.5, covered: 120, board: board) == .zero)
    }
}
