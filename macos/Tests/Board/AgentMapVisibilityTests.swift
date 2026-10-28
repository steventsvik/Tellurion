import AppKit
import Testing
@testable import Ghostty

@MainActor
struct AgentMapVisibilityTests {
    @Test func onlyTheBoardStartsAndStopsPolling() {
        let map = AgentMapContent(frame: .zero)
        #expect(!map.isRunning)
        map.setBoardVisible(true)
        #expect(map.isRunning)
        map.setBoardVisible(true)
        #expect(map.isRunning)
        map.setBoardVisible(false)
        #expect(!map.isRunning)
        // AppKit callbacks and a window notification must not undo the board's stop.
        map.viewDidUnhide()
        map.viewDidMoveToWindow()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        #expect(!map.isRunning)
        map.setBoardVisible(true)
        #expect(map.isRunning)
        map.setBoardVisible(false)
    }

    @Test func visibilityIncludesWindowViewportAndOverviewZoom() {
        let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
        let visible = CGRect(x: 50, y: 50, width: 100, height: 100)
        let outside = CGRect(x: 200, y: 200, width: 100, height: 100)
        #expect(BoardCardView.mapIsVisible(windowVisible: true, frame: visible, visibleRect: viewport, zoom: 0.45))
        #expect(!BoardCardView.mapIsVisible(windowVisible: false, frame: visible, visibleRect: viewport, zoom: 1))
        #expect(!BoardCardView.mapIsVisible(windowVisible: true, frame: outside, visibleRect: viewport, zoom: 1))
        #expect(!BoardCardView.mapIsVisible(windowVisible: true, frame: visible, visibleRect: viewport, zoom: 0.44))
    }
}
