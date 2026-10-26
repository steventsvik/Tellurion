import Foundation
import Testing
@testable import Ghostty

/// The order a tile's processes are stopped and continued in: the shell before what it runs
/// when pausing, and after it when resuming, so it never sees its job stop.
struct BoardPauseTests {
    // A tile: login (not ours) → shell 100 → agent 200 → the agent's child 300 and 301.
    private let parents: [Int32: Int32] = [100: 1, 200: 100, 300: 200, 301: 200]

    @Test func pausingStopsTheShellFirstAndResumingContinuesItLast() {
        let found: [Int32] = [301, 200, 300, 100]
        let paused = BoardPause.order(found, parents: parents, paused: true)
        #expect(paused.first == 100)
        #expect(paused[1] == 200)
        #expect(Set(paused.suffix(2)) == [300, 301])
        let resumed = BoardPause.order(found, parents: parents, paused: false)
        #expect(resumed.last == 100)
        #expect(resumed[resumed.count - 2] == 200)
        #expect(Set(resumed.prefix(2)) == [300, 301])
        #expect(Set(paused) == Set(found))
        #expect(resumed == Array(paused.reversed()))
    }

    @Test func tilesAreOrderedByDepthNotByTile() {
        // Two tiles: the second's shell 500 runs agent 600.
        let parents: [Int32: Int32] = [100: 1, 200: 100, 500: 1, 600: 500]
        let paused = BoardPause.order([600, 200, 500, 100], parents: parents, paused: true)
        #expect(Set(paused.prefix(2)) == [100, 500])
        #expect(Set(paused.suffix(2)) == [200, 600])
    }

    @Test func aParentOutsideTheTileDoesNotCount() {
        // 200's parent 100 isn't among the found processes: 200 is a root of its own.
        let paused = BoardPause.order([300, 200], parents: parents, paused: true)
        #expect(paused == [200, 300])
    }

    @Test func nothingToOrderIsNothing() {
        #expect(BoardPause.order([], parents: parents, paused: true).isEmpty)
        #expect(BoardPause.order([42], parents: [:], paused: false) == [42])
    }
}
