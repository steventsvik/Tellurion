#if os(macOS)
import AppKit
import Combine

/// The panes of classic windows (tabs and their splits): what a classic orchestrator wires.
enum ClassicPanes {
    static var all: [(controller: TerminalController, surface: Ghostty.SurfaceView)] {
        TerminalController.all.flatMap { controller in controller.surfaceTree.map { (controller, $0) } }
    }

    static func find(_ pane: UUID) -> (controller: TerminalController, surface: Ghostty.SurfaceView)? {
        all.first { $0.surface.id == pane }
    }

    /// A pane's name before two alike are told apart: its tab's name, its agent, or "Terminal".
    static func name(_ surface: Ghostty.SurfaceView, in controller: TerminalController?) -> String {
        TerminalWindows.title(of: surface, in: controller)
            ?? VerticalTabsAgents.shared.info(for: surface)?.kind.displayName ?? "Terminal"
    }
}

/// An orchestrator for one project in the classic layout: the panes wired to it (tabs and
/// splits, in any window), its goal, and the brain that hands them work. Unlike a board's it
/// has no card: it shows in the sidebar's Orchestrator section and in a window of its own.
final class ClassicOrchestrator: ObservableObject, Identifiable, OrchestratorHost {
    let id: UUID
    /// The project it's for: a git root, or a plain folder.
    let root: String
    /// Who is wired, their roles, the goal and the turn limit.
    @Published private(set) var team: BoardTeam
    private(set) lazy var brain = OrchestratorBrain(host: self, id: id)
    /// The window it was started from: new agents open as tabs there.
    weak var origin: TerminalController?
    weak var owner: ClassicOrchestrators?
    /// Where the tabs it opened were started, until their shells say.
    private var launchFolders: [UUID: String] = [:]
    /// The engine chosen for this project, if one was.
    private var chosenEngine: HeadlessAgent.Engine?

    init(root: String, record: ClassicOrchestratorRecord? = nil, owner: ClassicOrchestrators? = nil) {
        let id = UUID()
        self.id = id
        self.root = root
        self.owner = owner
        team = BoardTeam(id: id, goal: record?.goal, turns: record?.turns)
        // Its own engine, kept with the project; a board's choice stays the board's.
        chosenEngine = record?.engine.flatMap(HeadlessAgent.Engine.init(rawValue:))
        brain.remembersEngine = false
        brain.preferredEngine = chosenEngine
    }

    var projectName: String { ProjectPath.displayName(root) }

    // MARK: Wiring

    func isWired(_ pane: UUID) -> Bool { team.members.contains { $0.tile == pane } }

    func role(of pane: UUID) -> String? { team.members.first { $0.tile == pane }?.role }

    func wire(_ panes: [UUID], role: String? = nil) {
        let fresh = panes.filter { !isWired($0) }
        guard !fresh.isEmpty else { return }
        team.members += fresh.map { BoardTeam.Member(tile: $0, role: role) }
        for pane in fresh { owner?.wiredPane(pane) }
        changed()
    }

    func unwire(_ pane: UUID) {
        guard isWired(pane) else { return }
        team.members.removeAll { $0.tile == pane }
        launchFolders[pane] = nil
        changed()
    }

    func setRole(_ role: String?, for pane: UUID) {
        let role = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = team.members.firstIndex(where: { $0.tile == pane }) else { return }
        team.members[index].role = role?.isEmpty == false ? role : nil
        changed()
    }

    func setTurns(_ turns: Int) {
        team.turns = turns == BoardTeams.turns ? nil : turns
        changed()
    }

    /// Which of your CLIs its brain runs on, kept with the project.
    func setEngine(_ engine: HeadlessAgent.Engine) {
        chosenEngine = engine
        brain.preferredEngine = engine
        brain.engine = engine
        changed()
    }

    /// Closed panes come unwired.
    func prune(keeping open: Set<UUID>) {
        guard team.members.contains(where: { !open.contains($0.tile) }) else { return }
        team.members.removeAll { !open.contains($0.tile) }
        launchFolders = launchFolders.filter { open.contains($0.key) }
        changed()
    }

    /// What's kept between launches.
    var record: ClassicOrchestratorRecord {
        let members = team.members.map { ClassicOrchestratorRecord.Member(pane: $0.tile.uuidString, role: $0.role) }
        return ClassicOrchestratorRecord(goal: team.goal, turns: team.turns, engine: chosenEngine?.rawValue,
                                         members: members.isEmpty ? nil : members)
    }

    private func changed() {
        owner?.changed(self)
    }

    // MARK: Names

    /// The wired panes that are still open, with the name each goes by here: "Claude Code 2"
    /// when another has the same one.
    func labels() -> [(pane: UUID, label: String)] {
        let open = ClassicPanes.all
        var seen: [String: Int] = [:]
        return team.members.compactMap { member in
            guard let found = open.first(where: { $0.surface.id == member.tile }) else { return nil }
            let base = ClassicPanes.name(found.surface, in: found.controller)
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return (member.tile, n == 1 ? base : "\(base) \(n)")
        }
    }

    /// The names @mentioned in `text` (longest first, so "@Ada 2" isn't read as "@Ada"), and
    /// the text without them.
    static func mentions(in text: String, labels: [(pane: UUID, label: String)]) -> (panes: [UUID], rest: String) {
        var rest = text
        var panes: [UUID] = []
        for entry in labels.sorted(by: { $0.label.count > $1.label.count }) {
            let token = "@" + entry.label
            guard rest.range(of: token, options: .caseInsensitive) != nil else { continue }
            rest = rest.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
            panes.append(entry.pane)
        }
        return (panes, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The wired panes you can message with @: only those with an agent, since what's typed
    /// into a plain shell would run as a command.
    func mentionable() -> [(pane: UUID, label: String)] {
        labels().filter { agentInfo($0.pane) != nil }
    }

    // MARK: The brain's host

    var orchestratorPlace: OrchestratorPlace { .tabs }
    /// A tab it opens is undone as any new tab is; there's no step of its own.
    var orchestratorUndo: UndoManager? { nil }

    func orchestrator(_ id: UUID) -> BoardTeam? { id == self.id ? team : nil }

    func ensureTeam(_ id: UUID) -> BoardTeam? {
        guard id == self.id, owner == nil || owner?.list.contains(where: { $0 === self }) == true else { return nil }
        return team
    }

    func setGoal(_ goal: String, for id: UUID) {
        guard id == self.id else { return }
        team.goal = goal
        changed()
    }

    func orchestratorName(_ id: UUID) -> String { "Orchestrator" }

    func orchestratorAgents(_ id: UUID) -> [OrchestratorAgent] {
        guard id == self.id else { return [] }
        let open = ClassicPanes.all
        return team.members.compactMap { member in
            guard let surface = open.first(where: { $0.surface.id == member.tile })?.surface else { return nil }
            return OrchestratorAgent(pane: member.tile, surface: surface, role: member.role)
        }
    }

    func surface(of pane: UUID) -> Ghostty.SurfaceView? { ClassicPanes.find(pane)?.surface }

    func paneLabel(_ pane: UUID) -> String { labels().first { $0.pane == pane }?.label ?? "Terminal" }

    func paneFolder(_ pane: UUID) -> String? { surface(of: pane)?.pwd ?? launchFolders[pane] }

    /// Tabs aren't paused; that's a board's.
    func isPaused(_ pane: UUID) -> Bool { false }

    func mentionedPanes(in text: String, for id: UUID) -> (panes: [UUID], rest: String) {
        Self.mentions(in: text, labels: mentionable())
    }

    /// A new tab in the window the orchestrator was started from, in the project's folder,
    /// named and wired, without taking you out of the tab you're in.
    func spawnWired(_ agent: BoardAgent?, role: String?, task: String?, folder: String?, for id: UUID) -> UUID? {
        guard id == self.id, TellurionSettings.isOn(.orchestrator),
              let parent = origin ?? TerminalWindows.front as? TerminalController ?? TerminalController.all.first,
              let parentWindow = parent.window else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder ?? root
        var command = agent.map { $0.binary + "\n" }
        if let agent, let task, !task.isEmpty {
            let prompt = OrchestratorPrompt.memberIntro(role: role, orchestrator: orchestratorName(id), place: .tabs) + "\n\nYour task: " + task
            if agent.kind == .claude || agent.kind == .codex,
               // Unique: one reply can spawn several agents in the same second.
               let file = AgentTools.writePrompt(prompt, folder: "board-prompts",
                                                 name: "\(AgentTools.timestamp())-\(UUID().uuidString.prefix(6))-member.md") {
                command = AgentTools.agentCommand(agent.kind, promptFile: file)
            } else {
                command = agent.command(prompt: prompt)
            }
        }
        config.initialInput = command
        // Agents get a short name, as on a board, so you can tell them apart and @mention them.
        let name = agent == nil ? nil : BoardAgentNames.next(taken: Set(TerminalController.all.compactMap(\.titleOverride)))
        // A new tab is always selected: note where you were, and go back there right after.
        let selected = parentWindow.tabGroup?.selectedWindow ?? parentWindow
        let key = NSApp.keyWindow
        guard let tab = TerminalController.newTab(parent.ghostty, from: parentWindow, withBaseConfig: config),
              let surface = tab.surfaceTree.root?.leftmostLeaf() else { return nil }
        if let name { tab.titleOverride = name }
        if let window = tab.window, window !== selected {
            if window.tabGroup === selected.tabGroup { selected.tabGroup?.selectedWindow = selected }
            if let key, key !== window { key.makeKeyAndOrderFront(nil) }
        }
        if let folder = config.workingDirectory { launchFolders[surface.id] = folder }
        wire([surface.id], role: role)
        DemoDirector.note("orchestrator tab \(name ?? "Terminal") in \(ProjectPath.displayName(config.workingDirectory ?? root))")
        return surface.id
    }

    // MARK: Commands, updates and status

    /// Your command, once your CLIs have been found (the first one may come before that).
    func command(_ text: String) {
        guard brain.engines == nil else { return brain.command(text) }
        // Finding them can take a few seconds the first time: say so instead of sitting silent.
        brain.add(.event, "Looking for Claude Code and Codex on this Mac…")
        HeadlessAgent.lookUp { [weak self] _, _ in
            guard let self else { return }
            self.brain.lookUp()
            self.brain.command(text)
        }
    }

    /// Wired agents finished, asked something or need permission: the brain hears of it.
    func agentsChanged(_ events: [OrchestratorRelay.Event]) {
        let updates = orchestratorUpdates(id, events: events)
        guard !updates.isEmpty else { return }
        brain.agentsChanged(updates)
    }

    var status: OrchestratorStatus {
        let agents = orchestratorAgents(id)
        let activities = agents.map { ($0.pane, agentInfo($0.pane)?.activity) }
        let asking = activities.filter { $0.1 == .needsPermission }.map(\.0)
        let names = asking.isEmpty ? [] : labels().filter { asking.contains($0.pane) }.map(\.label)
        return OrchestratorStatus(running: brain.running, busy: brain.busy, turn: brain.turn, limit: brain.limit,
                                  working: activities.filter { $0.1 == .working }.count, needPermission: names,
                                  ending: brain.ending, wired: agents.count)
    }
}

/// An orchestrator's state in one line, for the sidebar and the window's header.
struct OrchestratorStatus: Equatable {
    enum Tone { case idle, working, needsYou, stopped, done }

    var running = false
    /// Its brain is thinking.
    var busy = false
    var turn = 0
    var limit = BoardTeams.turns
    /// How many wired agents are working.
    var working = 0
    /// The wired agents waiting for your permission, by name.
    var needPermission: [String] = []
    var ending: OrchestratorBrain.Ending?
    var wired = 0

    var tone: Tone {
        if running { return needPermission.isEmpty ? .working : .needsYou }
        switch ending {
        case .stopped: return .stopped
        case .done: return .done
        case nil: return .idle
        }
    }

    /// "Turn 3 of 12 · 2 working", "Waiting on you: Ada needs permission", "Stopped", "Idle".
    var line: String {
        switch tone {
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        case .done: return "Done"
        case .needsYou:
            switch needPermission.count {
            case 1: return "Waiting on you: \(needPermission[0]) needs permission"
            case 2: return "Waiting on you: \(needPermission[0]) and \(needPermission[1]) need permission"
            default: return "Waiting on you: \(needPermission.count) agents need permission"
            }
        case .working:
            let turns = "Turn \(max(turn, 1)) of \(limit)"
            if busy { return turns + " · thinking" }
            return turns + (working > 0 ? " · \(working) working" : " · waiting")
        }
    }
}

/// What the sidebar's Orchestrator section shows for the project of the tab it's in.
struct OrchestratorGlance: Equatable {
    /// The project's root, or nil when the tab has no folder yet.
    var root: String?
    var project = ""
    var goal: String?
    /// The latest error, while it's the last thing that happened.
    var problem: String?
    var status = OrchestratorStatus()
}

/// A pane the Wire menu offers.
struct OrchestratorWireChoice: Identifiable, Equatable {
    let id: UUID
    let label: String
    let detail: String?
    let isAgent: Bool
}

/// A project's panes in the Wire menu.
struct OrchestratorWireGroup: Identifiable, Equatable {
    /// The project's root.
    let id: String
    let name: String
    let choices: [OrchestratorWireChoice]
    var agents: [UUID] { choices.filter(\.isAgent).map(\.id) }
}

/// Every project's classic orchestrator: one per project root, made when you first open or
/// command one. Feeds each what its wired agents do, unwires panes that close, and keeps the
/// cheap parts (goal, roles, turn limit, engine) in a file between launches.
final class ClassicOrchestrators: ObservableObject {
    static let shared = ClassicOrchestrators(store: .standard, live: true)

    @Published private(set) var list: [ClassicOrchestrator] = []
    /// Every pane wired to an orchestrator, for the mark on its sidebar card.
    @Published private(set) var wired: Set<UUID> = []

    /// Something about an orchestrator changed (its goal, its wires, what its brain is doing):
    /// the sidebar's section reads it again. A few times a second at most.
    private let pulse = PassthroughSubject<Void, Never>()
    private(set) lazy var pulses: AnyPublisher<Void, Never> = pulse
        .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()
    private var watching: [UUID: AnyCancellable] = [:]

    private let store: ClassicOrchestratorStore
    private var records: [String: ClassicOrchestratorRecord]
    /// Panes that were wired before the relaunch and may still come back with their windows.
    private var returning: [String: [ClassicOrchestratorRecord.Member]] = [:]
    private let relay = OrchestratorRelay()
    private var observers: [NSObjectProtocol] = []
    private var roots: [String: (root: String, found: Date)] = [:]
    private var started = false
    private let live: Bool

    /// `live`: watches agents and windows (the shared one); tests make their own without.
    init(store: ClassicOrchestratorStore, live: Bool = false) {
        self.store = store
        self.live = live
        records = store.load()
        guard live else { return }
        returning = records.compactMapValues(\.members)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: VerticalTabsAgents.didChange, object: nil, queue: .main) { [weak self] note in
            guard let surface = note.object as? Ghostty.SurfaceView else { return }
            self?.agentChanged(surface)
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            // The window's panes are gone a moment after this.
            DispatchQueue.main.async { self?.prune() }
        })
    }

    /// Called once the first window is up: wires what came back with the windows.
    static func start() {
        guard TellurionSettings.isOn(.orchestrator), !shared.started else { return }
        shared.started = true
        if !shared.returning.isEmpty { shared.restoreWires(attempt: 0) }
    }

    // MARK: Looking up

    /// The project a folder is in: its git root, or the folder itself.
    func root(of folder: String) -> String {
        if let cached = roots[folder], Date().timeIntervalSince(cached.found) < 15 { return cached.root }
        let root = LocalhostProject(folder: folder).root
        roots[folder] = (root, Date())
        return root
    }

    /// The project of the tab in front in a window; the home folder until its shell says
    /// where it is.
    func root(for controller: BaseTerminalController) -> String {
        root(of: (controller.focusedSurface ?? controller.surfaceTree.first)?.pwd ?? NSHomeDirectory())
    }

    func orchestrator(root: String) -> ClassicOrchestrator? { list.first { $0.root == root } }

    func orchestrator(wiring pane: UUID) -> ClassicOrchestrator? {
        wired.contains(pane) ? list.first { $0.isWired(pane) } : nil
    }

    func record(root: String) -> ClassicOrchestratorRecord? { records[root] }

    /// The project's orchestrator, made if it has none yet (with what was kept about it).
    /// It starts stopped, whatever it was doing before.
    @discardableResult
    func open(root: String, from origin: TerminalController? = nil) -> ClassicOrchestrator {
        if let existing = orchestrator(root: root) {
            // Its new tabs open in the window it was last reached from.
            if let origin { existing.origin = origin }
            return existing
        }
        let orchestrator = ClassicOrchestrator(root: root, record: records[root], owner: self)
        orchestrator.origin = origin
        list.append(orchestrator)
        // After the brain's change has landed, not while it's being made.
        watching[orchestrator.id] = orchestrator.brain.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.pulse.send() }
        }
        // Finds your CLIs (off the main thread, once for the app).
        if live { orchestrator.brain.lookUp() }
        return orchestrator
    }

    // MARK: Changes

    /// Something to keep changed: the marks follow, and the file.
    func changed(_ orchestrator: ClassicOrchestrator) {
        let now = Set(list.flatMap { $0.team.members.map(\.tile) })
        if now != wired { wired = now }
        records[orchestrator.root] = orchestrator.record.checked
        save()
        pulse.send()
    }

    /// A pane was just wired: its status from here on is what counts as news.
    func wiredPane(_ pane: UUID) {
        guard let surface = ClassicPanes.find(pane)?.surface else { return }
        relay.last[pane] = VerticalTabsAgents.shared.info(for: surface)?.activity
    }

    private func save() {
        var records = records
        // Panes still expected back keep their place in the file until they're given up on.
        for (root, members) in returning {
            var record = records[root] ?? ClassicOrchestratorRecord()
            let known = Set((record.members ?? []).map(\.pane))
            record.members = (record.members ?? []) + members.filter { !known.contains($0.pane) }
            records[root] = record
        }
        store.save(records)
    }

    /// Wires or unwires a pane from its sidebar card: to its own project's orchestrator.
    func toggleWire(_ surface: Ghostty.SurfaceView, in controller: TerminalController) {
        if let current = orchestrator(wiring: surface.id) {
            current.unwire(surface.id)
            return
        }
        guard TellurionSettings.isOn(.orchestrator) else { return }
        open(root: root(of: surface.pwd ?? NSHomeDirectory()), from: controller).wire([surface.id])
    }

    /// Panes that closed come unwired.
    func prune() {
        guard !wired.isEmpty else { return }
        let open = Set(ClassicPanes.all.map(\.surface.id))
        guard !wired.isSubset(of: open) else { return }
        for pane in wired.subtracting(open) { relay.forget(pane: pane) }
        for orchestrator in list { orchestrator.prune(keeping: open) }
    }

    /// The feature was turned off: nothing keeps running, and its windows close.
    func turnedOff() {
        for orchestrator in list {
            orchestrator.brain.stop(quietly: true)
            relay.forget(orchestrator: orchestrator.id)
            AgentToolWindows.close(id: Self.windowID(orchestrator))
        }
    }

    // MARK: Agents

    private func agentChanged(_ surface: Ghostty.SurfaceView) {
        guard wired.contains(surface.id), TellurionSettings.isOn(.orchestrator) else { return }
        guard let event = relay.note(surface.id, info: VerticalTabsAgents.shared.info(for: surface)) else { return }
        for orchestrator in list where orchestrator.isWired(surface.id) {
            relay.schedule(event, for: orchestrator.id) { [weak orchestrator] events in orchestrator?.agentsChanged(events) }
        }
    }

    // MARK: After a relaunch

    /// Restored windows keep their panes' ids, so what was wired can be wired again once the
    /// windows are back (they arrive shortly after launch). Nothing starts running.
    private func restoreWires(attempt: Int) {
        let open = Set(ClassicPanes.all.map(\.surface.id.uuidString))
        for (root, members) in returning {
            let back = members.filter { open.contains($0.pane) }
            guard !back.isEmpty else { continue }
            let orchestrator = self.open(root: root)
            for member in back {
                guard let pane = UUID(uuidString: member.pane) else { continue }
                orchestrator.wire([pane], role: member.role)
            }
            let rest = members.filter { !open.contains($0.pane) }
            returning[root] = rest.isEmpty ? nil : rest
        }
        guard !returning.isEmpty else { return }
        if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restoreWires(attempt: attempt + 1) }
            return
        }
        // The rest didn't come back: their wires are forgotten, the goals and settings stay.
        for root in returning.keys where orchestrator(root: root) == nil { records[root]?.members = nil }
        returning = [:]
        save()
    }

    // MARK: For the views

    func glance(for controller: BaseTerminalController) -> OrchestratorGlance {
        let root = root(for: controller)
        var glance = OrchestratorGlance(root: root, project: ProjectPath.displayName(root))
        guard let orchestrator = orchestrator(root: root) else {
            glance.goal = records[root]?.goal
            return glance
        }
        glance.goal = orchestrator.team.goal
        glance.status = orchestrator.status
        if let last = orchestrator.brain.log.last, last.kind == .error { glance.problem = last.text }
        return glance
    }

    /// Every classic pane that isn't wired yet, by project (this orchestrator's first), agents
    /// first in each.
    func wireChoices(for orchestrator: ClassicOrchestrator) -> [OrchestratorWireGroup] {
        var groups: [String: [OrchestratorWireChoice]] = [:]
        for (controller, surface) in ClassicPanes.all where !wired.contains(surface.id) {
            guard !HermesSessions.shared.isHermes(controller), LocalhostSessions.shared.session(for: controller) == nil else { continue }
            let info = VerticalTabsAgents.shared.info(for: surface)
            let folder = surface.pwd
            let name = ClassicPanes.name(surface, in: controller)
            // A named tab also says which agent it is.
            let kind = info.flatMap { $0.kind.displayName == name ? nil : $0.kind.displayName }
            let doing = info?.task.map { BoardTeams.clip($0, 40) } ?? folder?.abbreviatedPath
            let detail = [kind, doing].compactMap { $0 }.joined(separator: " · ")
            groups[folder.map(root(of:)) ?? "", default: []].append(
                OrchestratorWireChoice(id: surface.id, label: name, detail: detail.isEmpty ? nil : detail, isAgent: info != nil))
        }
        return groups.map { root, choices in
            OrchestratorWireGroup(id: root, name: root.isEmpty ? "No folder" : ProjectPath.displayName(root),
                                  choices: choices.filter(\.isAgent) + choices.filter { !$0.isAgent })
        }
        .sorted { a, b in
            if (a.id == orchestrator.root) != (b.id == orchestrator.root) { return a.id == orchestrator.root }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Windows

    static func windowID(_ orchestrator: ClassicOrchestrator) -> String { "orchestrator-" + orchestrator.root }

    /// The project's orchestrator in its own window.
    static func show(_ orchestrator: ClassicOrchestrator) {
        guard TellurionSettings.isOn(.orchestrator) else { return }
        AgentToolWindows.show(id: windowID(orchestrator), title: "Orchestrator · \(orchestrator.projectName)",
                              size: NSSize(width: 980, height: 660)) {
            ClassicOrchestratorView(orchestrator: orchestrator, brain: orchestrator.brain)
        }
    }

    /// The orchestrator of the project of a window's front tab, made if needed.
    @discardableResult
    static func show(from controller: BaseTerminalController?) -> ClassicOrchestrator? {
        guard TellurionSettings.isOn(.orchestrator), let tab = controller as? TerminalController else { return nil }
        let orchestrator = shared.open(root: shared.root(for: tab), from: tab)
        show(orchestrator)
        return orchestrator
    }

    /// The View menu's item and ⌃⌘O: the front classic window's project.
    static func toggleForFrontTab() {
        // Read before anything opens: the front tab is the one behind the window.
        guard let tab = TerminalWindows.front as? TerminalController ?? TerminalController.preferredParent else { return }
        if let existing = shared.orchestrator(root: shared.root(for: tab)), AgentToolWindows.isOpen(windowID(existing)) {
            AgentToolWindows.close(id: windowID(existing))
        } else {
            show(from: tab)
        }
    }
}
#endif
