import Foundation
import Testing
@testable import Ghostty

/// Kanban cards and checklist items as tasks (see BoardTasks): what an item shows and when it's
/// finished, from its agent and the project's check.
struct BoardTasksOutcomeTests {
    private let typed = Date(timeIntervalSince1970: 1_000)
    private var before: Date { typed.addingTimeInterval(-60) }
    private var after: Date { typed.addingTimeInterval(60) }

    private func sent(finished: Bool = false, waiting: Bool = false, queued: Bool = false, manual: Bool = false,
                      legacy: Bool = false) -> BoardTasks.Sent {
        BoardTasks.Sent(finished: finished, waiting: waiting, queued: queued, at: legacy || waiting ? nil : typed, manual: manual)
    }

    private func live(_ agent: BoardTasks.Agent, fresh: Bool = true, hasCheck: Bool = false,
                      check: BoardTasks.Check? = nil) -> BoardTasks.Live {
        BoardTasks.Live(agent: agent, since: fresh ? after : before, hasCheck: hasCheck, check: check)
    }

    @Test func aBusyAgentsItemIsQueuedUntilItIsTypedIn() {
        #expect(BoardTasks.outcome(sent(waiting: true, queued: true), live(.working)) == .init(chip: .queued))
        // The agent finishing what it was doing isn't the item being done.
        #expect(BoardTasks.outcome(sent(waiting: true, queued: true), live(.done)) == .init(chip: .queued))
        #expect(BoardTasks.outcome(sent(waiting: true, queued: true), live(.done, hasCheck: true, check: .passed)) == .init(chip: .queued))
    }

    @Test func afterARelaunchAWaitingItemSaysItWasNotSent() {
        #expect(BoardTasks.outcome(sent(waiting: true, queued: false), live(.idle)) == .init(chip: .notSent))
        #expect(BoardTasks.outcome(sent(waiting: true, queued: false), live(.done)) == .init(chip: .notSent))
    }

    @Test func itFollowsTheAgentWhileItWorks() {
        #expect(BoardTasks.outcome(sent(), live(.working)) == .init(chip: .working))
        #expect(BoardTasks.outcome(sent(), live(.starting)) == .init(chip: .starting))
        #expect(BoardTasks.outcome(sent(), live(.idle)) == .init(chip: .idle))
    }

    @Test func aQuestionOrAPermissionPromptIsNotDone() {
        #expect(BoardTasks.outcome(sent(), live(.needsYou)) == .init(chip: .needsYou))
        #expect(BoardTasks.outcome(sent(), live(.needsYou, hasCheck: true, check: .passed)) == .init(chip: .needsYou))
        #expect(BoardTasks.agent(.needsPermission) == .needsYou)
        #expect(BoardTasks.agent(.needsInput) == .needsYou)
    }

    @Test func doneWithoutACheckFinishesIt() {
        #expect(BoardTasks.outcome(sent(), live(.done)) == .init(chip: .done, finish: true))
    }

    @Test func aStatusFromBeforeItWasTypedInDoesNotCount() {
        // The agent was already done (or had failed) when the item reached it.
        #expect(BoardTasks.outcome(sent(), live(.done, fresh: false)) == .init(chip: .sent))
        #expect(BoardTasks.outcome(sent(), live(.failed, fresh: false)) == .init(chip: .sent))
        #expect(BoardTasks.outcome(sent(), live(.idle, fresh: false)) == .init(chip: .sent))
        #expect(BoardTasks.outcome(sent(), BoardTasks.Live(agent: .done, since: typed)) == .init(chip: .sent))
    }

    @Test func withACheckItWaitsForThePass() {
        #expect(BoardTasks.outcome(sent(), live(.done, hasCheck: true)) == .init(chip: .checking))
        #expect(BoardTasks.outcome(sent(), live(.done, hasCheck: true, check: .running)) == .init(chip: .checking))
        #expect(BoardTasks.outcome(sent(), live(.done, hasCheck: true, check: .passed)) == .init(chip: .done, finish: true))
    }

    @Test func aFailedCheckKeepsItInProgress() {
        #expect(BoardTasks.outcome(sent(), live(.done, hasCheck: true, check: .failed)) == .init(chip: .checkFailed))
    }

    @Test func aCheckResultDoesNotFinishAnAgentThatIsWorkingAgain() {
        #expect(BoardTasks.outcome(sent(), live(.working, hasCheck: true, check: .passed)) == .init(chip: .working))
    }

    @Test func aFailedAgentIsNotDone() {
        #expect(BoardTasks.outcome(sent(), live(.failed)) == .init(chip: .failed))
        #expect(BoardTasks.outcome(sent(), live(.failed, hasCheck: true, check: .passed)) == .init(chip: .failed))
    }

    @Test func aClosedTileSaysSoAndMovesNothing() {
        #expect(BoardTasks.outcome(sent(), BoardTasks.Live(agent: .closed)) == .init(chip: .closed))
        #expect(BoardTasks.outcome(sent(waiting: true, queued: true), BoardTasks.Live(agent: .closed)) == .init(chip: .closed))
        #expect(BoardTasks.outcome(sent(), live(.noAgent)) == .init(chip: .noAgent))
    }

    @Test func anItemMovedByHandIsNeverMovedAgain() {
        #expect(BoardTasks.outcome(sent(manual: true), live(.done)) == .init(chip: .done))
        #expect(BoardTasks.outcome(sent(manual: true), live(.done, hasCheck: true, check: .passed)) == .init(chip: .done))
        #expect(BoardTasks.outcome(sent(manual: true), live(.working)) == .init(chip: .working))
    }

    @Test func aFinishedItemStaysFinished() {
        // Its agent starting something else doesn't bring it back.
        for agent in [BoardTasks.Agent.working, .needsYou, .failed, .closed, .noAgent, .idle, .done] {
            #expect(BoardTasks.outcome(sent(finished: true), live(agent)) == .init(chip: .done))
        }
    }

    @Test func anItemSentByAnOlderVersionStillFinishes() {
        #expect(BoardTasks.outcome(sent(legacy: true), live(.done, fresh: false)) == .init(chip: .done, finish: true))
        #expect(BoardTasks.outcome(sent(legacy: true), live(.working)) == .init(chip: .working))
    }

    @Test func everyActivityHasAState() {
        #expect(BoardTasks.agent(.ready) == .idle)
        #expect(BoardTasks.agent(.working) == .working)
        #expect(BoardTasks.agent(.done) == .done)
        #expect(BoardTasks.agent(.failed) == .failed)
    }
}

/// What an item remembers, and what moving it by hand changes.
struct BoardTasksItemTests {
    private let tile = UUID()

    @Test func sendingLinksTheItem() {
        var item = CardItem(text: "Fix the login form", done: true)
        item.manual = true
        let now = Date(timeIntervalSince1970: 5_000)
        BoardTasks.link(&item, to: tile, name: "Ada", at: now)
        #expect(item.agent == tile)
        #expect(item.agentName == "Ada")
        #expect(item.sent == now)
        #expect(item.waiting == nil)
        #expect(item.manual == nil)
        #expect(!item.done)
    }

    @Test func aBusyAgentsItemWaits() {
        var item = CardItem(text: "Fix the login form")
        BoardTasks.link(&item, to: tile, name: "Ada", at: nil)
        #expect(item.waiting == true)
        #expect(item.sent == nil)
    }

    @Test func movingByHandKeepsTheLink() {
        var item = CardItem(text: "Fix the login form")
        let now = Date(timeIntervalSince1970: 5_000)
        BoardTasks.link(&item, to: tile, name: "Ada", at: now)
        BoardTasks.movedByHand(&item)
        #expect(item.manual == true)
        #expect(item.agent == tile)
        #expect(item.agentName == "Ada")
        #expect(item.sent == now)
    }

    @Test func movingAWaitingItemTakesItBack() {
        var item = CardItem(text: "Fix the login form")
        BoardTasks.link(&item, to: tile, name: "Ada", at: nil)
        BoardTasks.movedByHand(&item)
        #expect(item.agent == nil)
        #expect(item.agentName == nil)
        #expect(item.waiting == nil)
        #expect(item.manual == nil)
    }

    @Test func movingAnItemNobodyHasChangesNothing() {
        var item = CardItem(text: "Fix the login form")
        let same = item
        BoardTasks.movedByHand(&item)
        #expect(item == same)
    }

    @Test func aCardFromAnOlderVersionStillOpens() throws {
        let id = UUID()
        let json = """
        {"id": "\(id.uuidString)", "text": "Old card", "done": false, "column": 2, "agent": "\(tile.uuidString)"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(CardItem.self, from: Data(json.utf8))
        #expect(item.id == id)
        #expect(item.agent == tile)
        #expect(item.agentName == nil)
        #expect(item.sent == nil)
        #expect(item.waiting == nil)
        #expect(item.manual == nil)
    }

    @Test func whatAnItemRemembersIsSavedAsOptionalKeys() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A card nobody has adds nothing to the file, so an older version reads it as before.
        let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(CardItem(text: "Plain"))) as? [String: Any])
        #expect(Set(plain.keys) == ["id", "text", "done", "column"])
        var item = CardItem(text: "Sent")
        BoardTasks.link(&item, to: tile, name: "Ada", at: Date(timeIntervalSince1970: 5_000))
        item.manual = true
        #expect(try decoder.decode(CardItem.self, from: encoder.encode(item)) == item)
        // And the board it's on is one this version saves, not a read-only one.
        var workspace = BoardWorkspace(name: "Board", folder: nil)
        workspace.cards = [BoardCard(id: UUID(), kind: .kanban, title: "Kanban", items: [item])]
        let decoded = try BoardStore.decode(encoder.encode(workspace))
        #expect(!decoded.readOnly)
        #expect(decoded.workspace.cards?.first?.items == [item])
    }
}

/// Working through a To Do column: who takes what, and never more agents than asked for.
struct BoardTasksQueueTests {
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    @Test func itStartsAgentsUpToTheLimit() {
        let todo = ids(5)
        #expect(BoardTasks.plan(todo: todo, workers: [], limit: 2) == [.start(item: todo[0]), .start(item: todo[1])])
        #expect(BoardTasks.plan(todo: todo, workers: [], limit: 1) == [.start(item: todo[0])])
        #expect(BoardTasks.plan(todo: Array(todo.prefix(2)), workers: [], limit: 6) == [.start(item: todo[0]), .start(item: todo[1])])
    }

    @Test func aFreeAgentTakesTheNextItemFromTheTop() {
        let todo = ids(3), workers = ids(2)
        let plan = BoardTasks.plan(todo: todo, workers: [(workers[0], .busy), (workers[1], .free)], limit: 2)
        #expect(plan == [.give(item: todo[0], worker: workers[1])])
    }

    @Test func freeAgentsComeBeforeNewOnes() {
        let todo = ids(3), workers = ids(1)
        let plan = BoardTasks.plan(todo: todo, workers: [(workers[0], .free)], limit: 3)
        #expect(plan == [.give(item: todo[0], worker: workers[0]), .start(item: todo[1]), .start(item: todo[2])])
    }

    @Test func busyAgentsLeaveNothingToDo() {
        let workers = ids(2)
        #expect(BoardTasks.plan(todo: ids(3), workers: [(workers[0], .busy), (workers[1], .busy)], limit: 2).isEmpty)
    }

    @Test func aHeldAgentGetsNothingAndCountsTowardsTheLimit() {
        let todo = ids(3), workers = ids(2)
        // Both failed their check: nothing more is started, so failures don't pile up.
        #expect(BoardTasks.plan(todo: todo, workers: [(workers[0], .held), (workers[1], .held)], limit: 2).isEmpty)
        // One held, room for one more.
        #expect(BoardTasks.plan(todo: todo, workers: [(workers[0], .held)], limit: 2) == [.start(item: todo[0])])
    }

    @Test func aClosedAgentIsReplaced() {
        let todo = ids(2), workers = ids(2)
        let plan = BoardTasks.plan(todo: todo, workers: [(workers[0], .gone), (workers[1], .busy)], limit: 2)
        #expect(plan == [.start(item: todo[0])])
    }

    @Test func theLimitStaysBetweenOneAndSix() {
        let todo = ids(10)
        #expect(BoardTasks.plan(todo: todo, workers: [], limit: 0).count == 1)
        #expect(BoardTasks.plan(todo: todo, workers: [], limit: 99).count == 6)
    }

    @Test func anEmptyColumnNeedsNobody() {
        #expect(BoardTasks.plan(todo: [], workers: [(UUID(), .free)], limit: 3).isEmpty)
    }

    @Test func whatAnAgentCanDoNext() {
        // Nothing of this card left with it.
        #expect(BoardTasks.worker(.done, item: nil) == .free)
        #expect(BoardTasks.worker(.idle, item: nil) == .free)
        #expect(BoardTasks.worker(.working, item: nil) == .busy)
        #expect(BoardTasks.worker(.needsYou, item: nil) == .busy)
        #expect(BoardTasks.worker(.starting, item: nil) == .busy)
        #expect(BoardTasks.worker(.noAgent, item: nil) == .gone)
        #expect(BoardTasks.worker(.closed, item: nil) == .gone)
        #expect(BoardTasks.worker(.closed, item: .closed) == .gone)
        // Still on its item.
        for chip in [BoardTasks.Chip.queued, .starting, .sent, .working, .needsYou, .checking] {
            #expect(BoardTasks.worker(.working, item: chip) == .busy)
        }
        // Its item didn't finish: it waits for you.
        #expect(BoardTasks.worker(.done, item: .checkFailed) == .held)
        #expect(BoardTasks.worker(.failed, item: .failed) == .held)
        #expect(BoardTasks.worker(.noAgent, item: .noAgent) == .held)
        #expect(BoardTasks.worker(.idle, item: .notSent) == .held)
    }

    @Test func theQueueTakesToDoCardsWithWordsOnThem() {
        let first = CardItem(text: "First", column: CardItem.todo)
        let empty = CardItem(text: "  ", column: CardItem.todo)
        let backlog = CardItem(text: "Later", column: CardItem.backlog)
        let second = CardItem(text: "Second", column: CardItem.todo)
        let doing = CardItem(text: "Now", column: CardItem.doing)
        #expect(BoardTasks.todo([backlog, first, empty, doing, second]) == [first.id, second.id])
    }

    @Test func anAgentsCurrentItemIsTheOneItHasNotFinished() {
        let tile = UUID()
        var finished = CardItem(text: "Done", column: CardItem.done)
        finished.agent = tile
        var moved = CardItem(text: "Moved", column: CardItem.todo)
        moved.agent = tile
        moved.manual = true
        var current = CardItem(text: "Now", column: CardItem.doing)
        current.agent = tile
        var other = CardItem(text: "Other", column: CardItem.doing)
        other.agent = UUID()
        #expect(BoardTasks.current([finished, moved, other, current], of: tile) == current)
        #expect(BoardTasks.current([finished, moved, other], of: tile) == nil)
    }

    /// A whole run, step by step: five cards, two agents, the second card's check fails.
    @Test func aRunNeverHasMoreAgentsThanAskedFor() throws {
        let todoIDs = ids(5)
        var todo = todoIDs
        var workers: [(id: UUID, state: BoardTasks.Worker)] = []
        var given: [UUID: UUID] = [:]
        var finished: [UUID] = []
        let failing = todoIDs[1]
        var held: UUID?
        for _ in 0..<20 {
            for step in BoardTasks.plan(todo: todo, workers: workers, limit: 2) {
                switch step {
                case .start(let item):
                    let worker = UUID()
                    workers.append((worker, .busy))
                    given[worker] = item
                    todo.removeAll { $0 == item }
                case .give(let item, let worker):
                    let index = try #require(workers.firstIndex { $0.id == worker })
                    #expect(workers[index].state == .free)
                    workers[index].state = .busy
                    given[worker] = item
                    todo.removeAll { $0 == item }
                }
            }
            #expect(workers.count <= 2)
            #expect(workers.filter { $0.state == .busy }.count <= 2)
            // Every busy agent finishes its turn.
            for index in workers.indices where workers[index].state == .busy {
                let item = try #require(given[workers[index].id])
                if item == failing {
                    workers[index].state = .held
                    held = workers[index].id
                } else {
                    workers[index].state = .free
                    finished.append(item)
                }
            }
        }
        // The other agent did the rest alone; the one whose check failed got nothing more.
        #expect(todo.isEmpty)
        #expect(finished == [todoIDs[0], todoIDs[2], todoIDs[3], todoIDs[4]])
        #expect(held.flatMap { given[$0] } == failing)
        #expect(workers.count == 2)
    }

    @Test func theTopTileUnderThePointerIsTheDropTarget() {
        let back = UUID(), front = UUID(), hidden = UUID()
        let frames = [back: CGRect(x: 0, y: 0, width: 400, height: 300), front: CGRect(x: 200, y: 100, width: 400, height: 300),
                      hidden: CGRect(x: 0, y: 0, width: 800, height: 600)]
        let order = [back, front, hidden]
        #expect(BoardTasks.node(at: CGPoint(x: 50, y: 50), order: order, frames: frames, hidden: [hidden]) == back)
        #expect(BoardTasks.node(at: CGPoint(x: 300, y: 200), order: order, frames: frames, hidden: [hidden]) == front)
        #expect(BoardTasks.node(at: CGPoint(x: 700, y: 500), order: order, frames: frames, hidden: [hidden]) == nil)
        // Not hidden, it's on top.
        #expect(BoardTasks.node(at: CGPoint(x: 300, y: 200), order: order, frames: frames) == hidden)
        // A closed tile's frame is kept for undo, but it isn't in the order.
        #expect(BoardTasks.node(at: CGPoint(x: 700, y: 500), order: [back, front], frames: frames) == nil)
    }
}

/// Duplicating a tile, and the "No prompts" badge: neither trusts a command from a board file.
struct BoardDuplicateTests {
    private let planted = "claude --dangerously-skip-permissions; touch /tmp/planted-by-board-file\n"

    @Test func aDuplicateStartsItsAgentAfresh() {
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.claude), skipsPermissions: false) == "claude\n")
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.codex), skipsPermissions: false) == "codex\n")
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.gemini), skipsPermissions: false) == "gemini\n")
    }

    @Test func aDuplicateOfAPlainTerminalIsAPlainShell() {
        #expect(BoardController.duplicateLine(agent: nil, skipsPermissions: false) == nil)
        #expect(BoardController.duplicateLine(agent: nil, skipsPermissions: true) == nil)
    }

    @Test func aDuplicateSkipsPromptsOnlyIfItsTileWasStartedThatWayHere() {
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.claude), skipsPermissions: true)
                == "claude --dangerously-skip-permissions\n")
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.codex), skipsPermissions: true)
                == "codex --dangerously-bypass-approvals-and-sandbox\n")
        // An agent with no such flag starts plainly.
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.opencode), skipsPermissions: true) == "opencode\n")
    }

    @Test func aCommandFromABoardFileNeverTurnsPromptsOff() {
        // The file says the tile skips prompts; the app didn't start it that way in this run.
        #expect(!BoardController.skipsPermissions(command: planted, startedSkipping: false))
        #expect(!BoardController.skipsPermissions(command: "codex --dangerously-bypass-approvals-and-sandbox\n", startedSkipping: false))
        let skips = BoardController.skipsPermissions(command: planted, startedSkipping: false)
        #expect(BoardController.duplicateLine(agent: BoardAgent.forKind(.claude), skipsPermissions: skips) == "claude\n")
    }

    @Test func aTileStartedWithoutPromptsHereSaysSo() {
        #expect(BoardController.skipsPermissions(command: "claude --dangerously-skip-permissions\n", startedSkipping: true))
        #expect(BoardController.skipsPermissions(command: "gemini --yolo\n", startedSkipping: true))
        // Its agent quit (the command is dropped), or it was started with prompts.
        #expect(!BoardController.skipsPermissions(command: nil, startedSkipping: true))
        #expect(!BoardController.skipsPermissions(command: "claude\n", startedSkipping: true))
    }
}
