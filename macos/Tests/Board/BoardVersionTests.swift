import Foundation
import Testing
@testable import Ghostty

/// Board files from a newer build (see BoardStore.decode): they open, with what this build
/// doesn't know left out, and are marked read-only so saving can't lose the rest.
struct BoardVersionTests {
    private func object(_ workspace: BoardWorkspace) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(workspace)) as? [String: Any])
    }

    private func sample() -> BoardWorkspace {
        var workspace = BoardWorkspace(name: "Board", folder: "/tmp")
        workspace.tiles = [BoardTile(id: UUID(), frame: CGRect(x: 0, y: 60, width: 480, height: 300), cwd: "/tmp", title: "Planner")]
        workspace.cards = [BoardCard(id: UUID(), kind: .note, title: "Note"), BoardCard(id: UUID(), kind: .checklist, title: "List")]
        workspace.groups = [BoardGroupNode(id: UUID(), name: "Web", role: .frontend, tiles: workspace.tiles.map(\.id))]
        return workspace
    }

    @Test func aBoardFromThisBuildIsNotReadOnly() throws {
        let workspace = sample()
        let decoded = try BoardStore.decode(JSONSerialization.data(withJSONObject: object(workspace)))
        #expect(!decoded.readOnly)
        #expect(decoded.workspace.tiles == workspace.tiles)
        #expect(decoded.workspace.cards == workspace.cards)
        #expect(decoded.workspace.groups == workspace.groups)
    }

    @Test func aNewerVersionOpensReadOnly() throws {
        let workspace = sample()
        var object = try object(workspace)
        object["version"] = BoardStore.currentVersion + 1
        object["somethingNewer"] = ["kept": true]
        let decoded = try BoardStore.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.readOnly)
        #expect(decoded.workspace.id == workspace.id)
        #expect(decoded.workspace.tiles == workspace.tiles)
    }

    @Test func aCardOfAnUnknownKindIsLeftOutAndTheBoardIsReadOnly() throws {
        let workspace = sample()
        var object = try object(workspace)
        var cards = try #require(object["cards"] as? [[String: Any]])
        cards[0]["kind"] = "hologram"
        object["cards"] = cards
        let decoded = try BoardStore.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.readOnly)
        #expect(decoded.workspace.cards?.map(\.title) == ["List"])
        #expect(decoded.workspace.tiles == workspace.tiles)
    }

    @Test func anUnknownRoleShowsAsGeneralAndTheBoardIsReadOnly() throws {
        let workspace = sample()
        var object = try object(workspace)
        var groups = try #require(object["groups"] as? [[String: Any]])
        groups[0]["role"] = "astronauts"
        object["groups"] = groups
        let decoded = try BoardStore.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.readOnly)
        #expect(decoded.workspace.groups?.first?.role == .general)
        #expect(decoded.workspace.groups?.first?.name == "Web")
    }

    @Test func aFileThatIsNotABoardThrows() {
        #expect(throws: (any Error).self) { try BoardStore.decode(Data("{\"name\":1}".utf8)) }
        #expect(throws: (any Error).self) { try BoardStore.decode(Data("not json".utf8)) }
    }
}
