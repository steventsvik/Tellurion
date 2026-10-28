import Foundation
import Testing
@testable import Ghostty

/// The saved board file (see BoardStore) across builds. `released` (tiles away in classic
/// windows) is optional, so boards saved before it and after it load either way.
struct BoardWorkspaceTests {
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func tile(_ title: String, x: CGFloat = 0) -> BoardTile {
        BoardTile(id: UUID(), frame: CGRect(x: x, y: 60, width: 480, height: 300), cwd: "/tmp/\(title)", title: title)
    }

    @Test func forgettingReleasedTilesDropsWhatWaitedForThem() {
        let here = tile("here"), away = tile("away", x: 600)
        let card = UUID()
        let group = BoardGroupNode(id: UUID(), name: "Web", role: .frontend, tiles: [here.id, away.id])
        let onlyAway = BoardGroupNode(id: UUID(), name: "Gone", role: .backend, tiles: [away.id])
        let ink = [BoardInkStroke(id: UUID(), points: [.zero], color: 0, width: 2, anchor: here.id),
                   BoardInkStroke(id: UUID(), points: [.zero], color: 0, width: 2, anchor: away.id),
                   BoardInkStroke(id: UUID(), points: [.zero], color: 0, width: 2, anchor: card),
                   BoardInkStroke(id: UUID(), points: [.zero], color: 0, width: 2, anchor: nil)]
        var team = BoardTeam(id: UUID())
        team.members = [.init(tile: here.id), .init(tile: away.id)]
        team.groups = ["group:\(group.id.uuidString)", "group:\(onlyAway.id.uuidString)", "/tmp/project"]
        var workspace = BoardWorkspace(name: "Board", folder: nil)
        workspace.tiles = [here]
        workspace.released = [away]
        workspace.cards = [BoardCard(id: card, kind: .note, title: "Note")]
        workspace.groups = [group, onlyAway]
        workspace.ink = ink
        workspace.teams = [team]
        let pruned = workspace.forgettingReleased()
        #expect(pruned.released == nil)
        #expect(pruned.ink?.map { $0.anchor } == [here.id, card, nil])
        #expect(pruned.groups?.map { $0.tiles } == [[here.id]])
        #expect(pruned.teams?.first?.members.map { $0.tile } == [here.id])
        #expect(pruned.teams?.first?.groups == ["group:\(group.id.uuidString)", "/tmp/project"])
        #expect(pruned.tiles == [here])
        // Nothing away: nothing changes.
        var settled = workspace
        settled.released = []
        #expect(settled.forgettingReleased() == settled)
    }

    @Test func aTilesAccountsComeBackByProvider() {
        var tile = tile("t")
        let claude = UUID(), codex = UUID()
        tile.accounts = ["claude": claude, "codex": codex, "future-provider": UUID()]
        #expect(tile.chosenAccounts == [.claude: claude, .codex: codex])
        #expect(self.tile("plain").chosenAccounts.isEmpty)
    }

    /// A board written by a build that didn't know released tiles.
    @Test func loadsABoardSavedBeforeReleasedTiles() throws {
        let json = """
        {"id":"6F2C1E0A-3B7D-4C8E-9F10-1234567890AB","name":"Board","open":true,"tiles":[],
         "updated":"2026-10-25T12:00:00Z","version":1}
        """
        let workspace = try decoder.decode(BoardWorkspace.self, from: Data(json.utf8))
        #expect(workspace.name == "Board")
        #expect(workspace.released == nil)
        #expect(workspace.tiles.isEmpty)
        #expect(workspace.open)
    }

    /// The same, with tiles: a saved file with the key removed, as an older build wrote it.
    @Test func loadsTilesFromABoardWithoutTheReleasedKey() throws {
        var workspace = BoardWorkspace(name: "Board", folder: "/tmp")
        workspace.tiles = [tile("Planner"), tile("Reviewer", x: 520)]
        workspace.released = [tile("Away", x: 1040)]
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(workspace)) as? [String: Any])
        #expect(object["released"] != nil)
        object["released"] = nil
        let loaded = try decoder.decode(BoardWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(loaded.id == workspace.id)
        #expect(loaded.tiles == workspace.tiles)
        #expect(loaded.released == nil)
    }

    /// Tiles that left for windows come back from the file with their place and name.
    @Test func releasedTilesSurviveASaveAndLoad() throws {
        var workspace = BoardWorkspace(name: "Board", folder: nil)
        workspace.tiles = [tile("Planner")]
        workspace.released = [tile("Away", x: 520), tile("Also away", x: 1040)]
        let loaded = try decoder.decode(BoardWorkspace.self, from: encoder.encode(workspace))
        #expect(loaded.released == workspace.released)
        #expect(loaded.released?.map(\.title) == ["Away", "Also away"])
        #expect(loaded.released?.first?.frame == CGRect(x: 520, y: 60, width: 480, height: 300))
        #expect(loaded.tiles == workspace.tiles)
    }

    /// A board with nothing away saves as it did before: no `released` key, so an older build's
    /// file and a new build's file look the same.
    @Test func aBoardWithNothingAwaySavesWithoutTheKey() throws {
        let workspace = BoardWorkspace(name: "Board", folder: nil)
        let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(workspace)) as? [String: Any])
        #expect(object["released"] == nil)
        #expect(object["version"] as? Int == 1)
    }

    /// An older build opening a file from a newer one: keys it doesn't know are skipped.
    @Test func ignoresKeysFromNewerBuilds() throws {
        var workspace = BoardWorkspace(name: "Board", folder: nil)
        workspace.released = [tile("Away")]
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(workspace)) as? [String: Any])
        object["somethingNewer"] = ["kept": true]
        let loaded = try decoder.decode(BoardWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(loaded.released == workspace.released)
    }

    /// What ink, groups and wires may refer to: the tiles on the board and those away.
    @Test @MainActor func tileIDsIncludeTilesThatAreAway() {
        let model = BoardModel()
        #expect(model.tileIDs.isEmpty)
        let away = [tile("Away"), tile("Also away", x: 520)]
        model.released = away
        #expect(model.tileIDs == Set(away.map(\.id)))
    }
}
