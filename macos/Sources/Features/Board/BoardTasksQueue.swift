#if os(macOS)
import AppKit
import Combine

/// What a board knows about its sent items that isn't saved: messages still waiting for a busy
/// agent, and the To Do columns being worked through. After a relaunch all of it is gone: queues are stopped and nothing is sent
/// again; the items keep their tiles.
@MainActor
final class BoardTaskRunner {
    /// A kanban's To Do column being worked through.
    struct Queue {
        /// How many of its agents may be on the board at once.
        var limit: Int
        var agent: BoardAgent
        /// The tiles it started.
        var workers: [UUID] = []
    }

    private weak var board: BoardController?
    private(set) var queues: [UUID: Queue] = [:]
    /// Items waiting for a busy agent: the card they're on, and the message in the agent's inbox.
    private var pending: [UUID: (card: UUID, delivery: UUID)] = [:]
    /// New tiles whose agent hasn't come up yet.
    private(set) var starting: Set<UUID> = []
    private var scheduling = false
    private var checks: AnyCancellable?
    /// Only while something waits, and only while a queue runs.
    private var inbox: AnyCancellable?
    private var watch: AnyCancellable?

    init(board: BoardController) {
        self.board = board
        checks = NotificationCenter.default.publisher(for: ProjectChecks.didChange)
            .sink { [weak self] note in
                guard let surface = note.object as? Ghostty.SurfaceView else { return }
                self?.checkChanged(surface)
            }
    }

    // MARK: Agents and checks

    /// An agent on the board changed: its items follow, and a queue may have a free agent.
    func agentChanged(_ surface: Ghostty.SurfaceView) {
        guard let board else { return }
        if VerticalTabsAgents.shared.info(for: surface) != nil { starting.remove(surface.id) }
        board.settleTasks(of: surface.id)
        schedule()
    }

    private func checkChanged(_ surface: Ghostty.SurfaceView) {
        // Only for a tile an item was sent to.
        guard let board, board.model.surfaces.contains(where: { $0 === surface }),
              board.model.cards.contains(where: { card in card.items.contains { $0.agent == surface.id } }) else { return }
        board.settleTasks(of: surface.id)
        // The chips follow the check too (the card itself may not have changed).
        board.model.agentTick &+= 1
        schedule()
    }

    /// Whether the tile's project has a check command.
    func hasCheck(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let board else { return false }
        let folders = [board.folder(of: surface), board.model.projects[surface.id]].compactMap { $0 }
        return folders.contains { ProjectChecks.shared.hasCheck(forFolder: $0) }
    }

    /// The check's result for the turn the tile's agent just ended (nil until there is one:
    /// ProjectChecks drops the last result when a new turn starts).
    func check(_ surface: Ghostty.SurfaceView) -> BoardTasks.Check? {
        guard let state = ProjectChecks.shared.result(for: surface)?.state else { return nil }
        switch state {
        case .running: return .running
        case .passed: return .passed
        default: return .failed
        }
    }

    /// A new tile was started on an item.
    func started(_ tile: UUID) { starting.insert(tile) }

    // MARK: Waiting for a busy agent

    func isQueued(_ item: UUID) -> Bool { pending[item] != nil }

    /// Follows a message in the agent's inbox until it's typed in.
    func track(_ item: UUID, on card: UUID, delivery: UUID) {
        pending[item] = (card, delivery)
        // An agent that was ready has it already.
        inboxChanged()
    }

    /// Takes back an item's message if it hasn't been typed in yet.
    func cancel(_ item: UUID) {
        guard let entry = pending.removeValue(forKey: item) else { return }
        AgentInbox.shared.cancel(entry.delivery)
        updateWatches()
    }

    private func inboxChanged() {
        guard let board else { return }
        for (item, entry) in pending {
            switch AgentInbox.shared.deliveries[entry.delivery]?.state {
            case .sent(let at)?:
                pending[item] = nil
                board.taskTyped(item, on: entry.card, at: at)
            case nil:
                // Dropped: it waited too long, or the tile closed.
                pending[item] = nil
                board.taskDropped(item, on: entry.card)
            case .waiting?, .blockedByTypedText?:
                break
            }
        }
        updateWatches()
        schedule()
    }

    // MARK: Queues

    func isRunning(_ card: UUID) -> Bool { queues[card] != nil }

    /// Starts working through a kanban's To Do column.
    func run(_ card: UUID, limit: Int, agent: BoardAgent) {
        queues[card] = Queue(limit: min(max(limit, BoardTasks.agentLimit.lowerBound), BoardTasks.agentLimit.upperBound), agent: agent)
        updateWatches()
        schedule()
    }

    /// Stops handing out a kanban's items. Its agents finish what they have.
    func stop(_ card: UUID) {
        queues[card] = nil
        updateWatches()
    }

    /// Hands out what can be handed out now. Called whenever an agent, a check, the cards or
    /// the tiles change while a queue runs.
    private func schedule() {
        guard let board, !queues.isEmpty, !scheduling else { return }
        scheduling = true
        defer {
            scheduling = false
            updateWatches()
        }
        for (cardID, running) in queues {
            guard let card = board.model.cards.first(where: { $0.id == cardID }), card.kind == .kanban else {
                queues[cardID] = nil
                continue
            }
            var queue = running
            let workers = queue.workers.map { (id: $0, state: board.taskWorker($0, on: card)) }
            queue.workers = workers.filter { $0.state != .gone }.map(\.id)
            var failed = false
            for step in BoardTasks.plan(todo: BoardTasks.todo(card.items), workers: workers, limit: queue.limit) {
                switch step {
                case .give(let item, let worker):
                    guard let surface = board.model.surfaces.first(where: { $0.id == worker }) else { continue }
                    board.hand(item, in: cardID, to: surface)
                case .start(let item):
                    if let surface = board.hand(item, in: cardID, starting: queue.agent) {
                        queue.workers.append(surface.id)
                    } else {
                        failed = true
                    }
                }
                if failed { break }
            }
            // Nothing left in To Do (or an agent couldn't be started): the queue is over.
            let left = board.model.cards.first { $0.id == cardID }.map { BoardTasks.todo($0.items) } ?? []
            queues[cardID] = failed || left.isEmpty ? nil : queue
        }
    }

    private func updateWatches() {
        if pending.isEmpty {
            inbox = nil
        } else if inbox == nil {
            inbox = AgentInbox.shared.$deliveries.receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.inboxChanged() }
        }
        if queues.isEmpty {
            watch = nil
        } else if watch == nil, let model = board?.model {
            // A card moved by hand, a new card in To Do, a closed tile.
            watch = model.$cards.map { _ in () }.merge(with: model.$surfaces.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.schedule() }
        }
    }
}

extension BoardController {
    /// What the agent in a tile is doing, for an item that was sent to it.
    func taskAgent(of tile: UUID) -> (agent: BoardTasks.Agent, surface: Ghostty.SurfaceView?, info: VerticalTabAgentInfo?) {
        guard let surface = model.surfaces.first(where: { $0.id == tile }) else { return (.closed, nil, nil) }
        guard let info = VerticalTabsAgents.shared.info(for: surface) else {
            return (tasks.starting.contains(tile) ? .starting : .noAgent, surface, nil)
        }
        return (BoardTasks.agent(info.activity), surface, info)
    }

    /// The chip for an item, and whether it's finished; nil for one that wasn't sent to an agent.
    func taskOutcome(_ item: CardItem, in kind: BoardCard.Kind) -> BoardTasks.Outcome? {
        guard let tile = item.agent else { return nil }
        let finished = kind == .kanban ? item.column == CardItem.done : item.done
        let sent = BoardTasks.Sent(finished: finished, waiting: item.waiting == true, queued: tasks.isQueued(item.id),
                                   at: item.sent, manual: item.manual == true)
        // A finished item doesn't follow its tile any more.
        if finished { return BoardTasks.outcome(sent, BoardTasks.Live(agent: .idle)) }
        let state = taskAgent(of: tile)
        var live = BoardTasks.Live(agent: state.agent, since: state.info?.since)
        // Only asked for when it matters: the agent's turn is over.
        if state.agent == .done, !sent.waiting, !sent.manual, let surface = state.surface, tasks.hasCheck(surface) {
            live.hasCheck = true
            live.check = tasks.check(surface)
        }
        return BoardTasks.outcome(sent, live)
    }

    /// The name of the agent an item went to: its tile's now, or the one it had when it was sent.
    func taskName(_ item: CardItem) -> String? {
        guard let tile = item.agent else { return nil }
        guard let surface = model.surfaces.first(where: { $0.id == tile }) else { return item.agentName }
        if let info = VerticalTabsAgents.shared.info(for: surface) {
            return BoardTileTitle.title(surface, info, name: model.titles[tile])
        }
        return model.titles[tile] ?? item.agentName
    }

    /// The items sent to a tile follow it: one whose turn is over (and whose check passed, when
    /// the project has one) goes to Done.
    func settleTasks(of tile: UUID) {
        for card in model.cards where card.items.contains(where: { $0.agent == tile }) {
            updateCard(card.id) { card in
                // By id: a move puts an item at the end and shifts the ones after it.
                for itemID in card.items.filter({ $0.agent == tile }).map(\.id) {
                    guard let index = card.items.firstIndex(where: { $0.id == itemID }),
                          let outcome = taskOutcome(card.items[index], in: card.kind), outcome.chip != .done || outcome.finish else { continue }
                    // The name its tile was given once the agent came up.
                    if let name = taskName(card.items[index]), card.items[index].agentName != name { card.items[index].agentName = name }
                    guard outcome.finish else { continue }
                    card.items[index].done = true
                    if card.kind == .kanban { Self.move(&card.items, index, toColumn: CardItem.done) }
                }
            }
        }
    }

    /// A waiting item was typed into its agent.
    func taskTyped(_ itemID: UUID, on cardID: UUID, at date: Date) {
        updateCard(cardID) { card in
            guard let index = card.items.firstIndex(where: { $0.id == itemID }), card.items[index].waiting == true else { return }
            card.items[index].sent = date
            card.items[index].waiting = nil
        }
    }

    /// A waiting item's message was dropped before it was typed in. With its tile still there
    /// it goes back to To Do, as if it had never been sent; a closed tile's item stays where it is.
    func taskDropped(_ itemID: UUID, on cardID: UUID) {
        updateCard(cardID) { card in
            guard let index = card.items.firstIndex(where: { $0.id == itemID }), card.items[index].waiting == true,
                  let tile = card.items[index].agent, model.surfaces.contains(where: { $0.id == tile }) else { return }
            BoardTasks.unlink(&card.items[index])
            if card.kind == .kanban, card.items[index].column == CardItem.doing { Self.move(&card.items, index, toColumn: CardItem.todo) }
        }
    }

    /// What a queue's agent can do next (see BoardTasks.worker).
    func taskWorker(_ tile: UUID, on card: BoardCard) -> BoardTasks.Worker {
        let chip = BoardTasks.current(card.items, of: tile).flatMap { taskOutcome($0, in: card.kind)?.chip }
        return BoardTasks.worker(taskAgent(of: tile).agent, item: chip)
    }

    /// The agent tile on top at a point of the board (board points), for dropping an item on
    /// it. Only a tile with an agent running: a plain terminal would run the words as a command.
    func taskDropTarget(at point: CGPoint) -> (surface: Ghostty.SurfaceView, name: String)? {
        let present = Set(model.nodeIDs)
        guard let id = BoardTasks.node(at: point, order: model.order.filter(present.contains), frames: model.frames,
                                       hidden: collapsedTiles) else { return nil }
        return boardAgents.first { $0.surface.id == id }
    }

    // MARK: Run the To Do column

    /// Asks how many agents at once and which kind, then works through the kanban's To Do
    /// column from the top.
    func promptRunQueue(_ cardID: UUID) {
        // Looking for the agents reads the login shell's PATH: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let agents = BoardAgent.installed().filter(\.takesPrompt)
            DispatchQueue.main.async { [weak self] in self?.askRunQueue(cardID, agents: agents) }
        }
    }

    private func askRunQueue(_ cardID: UUID, agents: [BoardAgent]) {
        guard let window, let card = model.cards.first(where: { $0.id == cardID }), card.kind == .kanban else { return }
        let waiting = BoardTasks.todo(card.items).count
        let alert = NSAlert()
        guard waiting > 0, !agents.isEmpty else {
            alert.messageText = waiting == 0 ? "Nothing in To Do" : "No agent to run it"
            alert.informativeText = waiting == 0 ? "Add cards to the To Do column first."
                : "Running a column needs an agent that takes its task when it starts: Claude Code, Codex, Gemini or Qwen."
            alert.beginSheetModal(for: window)
            return
        }
        alert.messageText = "Run the To Do Column"
        alert.informativeText = "Agents start beside “\(card.title)” and each takes the next card from the top of To Do when it's "
            + "free. A card goes to Done when its agent finishes (and the project's check passes, if it has one)."
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        for agent in agents { kind.addItem(withTitle: agent.kind.displayName) }
        if let claude = agents.firstIndex(where: { $0.kind == .claude }) { kind.selectItem(at: claude) }
        let count = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        for number in BoardTasks.agentLimit { count.addItem(withTitle: number == 1 ? "1 at a time" : "\(number) at once") }
        count.selectItem(at: min(waiting, 3) - 1)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Agent"), kind], [NSTextField(labelWithString: "How many"), count]])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, agents.indices.contains(kind.indexOfSelectedItem) else { return }
            self?.tasks.run(cardID, limit: count.indexOfSelectedItem + 1, agent: agents[kind.indexOfSelectedItem])
        }
    }
}
#endif
