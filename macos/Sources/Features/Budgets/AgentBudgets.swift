#if os(macOS)
import AppKit
import os
import UserNotifications

/// Budgets for agents: a cap on what one session may cost at API prices, or on its tokens,
/// and what happens when it gets there.
///
/// Each live agent pane with a budget is measured from its transcript, a piece at a time
/// (see `TranscriptMeter`), off the main thread: when the agent reports something, and every
/// `tick` seconds while one is working. With no budget set anywhere, nothing is read.
///
/// At the cap the agent is frozen the way a board's Pause all freezes a tile (`BoardPause`):
/// its processes are stopped, never killed, and carry on when the budget is raised or
/// removed. Nothing is ever typed into the agent.
final class AgentBudgets: ObservableObject {
    static let shared = AgentBudgets()

    /// Posted on the main thread (object: the surface, or nil for all) when a pane's budget
    /// status or the budgets themselves change.
    static let didChange = Notification.Name("com.steventsvik.ghostty-extreme.budgetsDidChange")

    static var file: URL { AgentTools.root.appendingPathComponent("budgets.json") }

    /// Seconds between readings while an agent works.
    static let tick: TimeInterval = 15
    /// The least time between two readings of one pane, however often its agent reports.
    static let minimumGap: TimeInterval = 2

    private static let log = StoredFile.logger("Budgets")

    @Published private(set) var settings: BudgetSettings

    /// What's known about the session in a pane. Main thread only.
    private final class Session {
        let transcript: String
        var resolved: (budget: AgentBudget, scope: BudgetScope)?
        var usage = BudgetUsage()
        var status: BudgetStatus?
        var progress = BudgetProgress()
        var noticeHidden = false
        /// A reading is under way; `again` asks for another once it's back.
        var reading = false
        var again = false
        /// A reading is scheduled for when `minimumGap` has passed.
        var waiting = false
        var lastRead = Date.distantPast

        init(transcript: String) { self.transcript = transcript }
    }

    /// Weak keys: a closed pane's session goes with it.
    private let sessions = NSMapTable<Ghostty.SurfaceView, Session>.weakToStrongObjects()
    /// Panes in classic windows that a budget froze. A board keeps its own (`model.paused`).
    private var pausedPanes: Set<UUID> = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.budgets", qos: .utility)
    /// How far each transcript has been read. Only on `queue`.
    private var meters: [String: SessionMeter] = [:]
    /// Each folder's project. Only on `queue`.
    private var projects: [String: String] = [:]

    private init() {
        settings = Self.load(from: Self.file)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: VerticalTabsAgents.didChange, object: nil, queue: .main) { [weak self] note in
            guard let self, let surface = note.object as? Ghostty.SurfaceView else { return }
            self.refresh(surface)
            self.startTimerIfNeeded()
        })
        observers.append(center.addObserver(forName: TellurionSettings.featuresDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.object as? TellurionFeature == .budgets else { return }
            self?.settingsChanged()
        })
        // A frozen process can't quit with the app; let it go first.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.pausedPanes.isEmpty else { return }
            BoardPause.set(false, surfaces: self.pausedPanes)
        })
    }

    /// Called once at launch, so budgets hold whether or not anything is showing them.
    func start() {
        refreshAll()
    }

    // MARK: Reading

    var isOn: Bool { TellurionSettings.isOn(.budgets) }

    /// Whether anything has to be measured at all.
    private var active: Bool { isOn && !settings.isEmpty }

    /// A pane's budget and how far along it is, or nil when none applies.
    func status(for surface: Ghostty.SurfaceView) -> BudgetStatus? {
        guard isOn else { return nil }
        return sessions.object(forKey: surface)?.status
    }

    /// The budget a pane's session is held to and where it comes from.
    func budget(for surface: Ghostty.SurfaceView) -> (budget: AgentBudget, scope: BudgetScope)? {
        guard isOn else { return nil }
        return sessions.object(forKey: surface)?.resolved
    }

    /// What a measured pane's session has used so far.
    func usage(for surface: Ghostty.SurfaceView) -> BudgetUsage? {
        guard isOn, let session = sessions.object(forKey: surface), session.resolved != nil else { return nil }
        return session.usage
    }

    /// What was chosen on the pane's own card, if anything: a budget, or none at all
    /// (`isSet` is false), which keeps the defaults off it.
    func ownBudget(for surface: Ghostty.SurfaceView) -> AgentBudget? {
        settings.panes[surface.id.uuidString]
    }

    /// Whether the card still shows that the session is past 80%.
    func showsNotice(for surface: Ghostty.SurfaceView) -> Bool {
        guard let session = sessions.object(forKey: surface) else { return false }
        return session.status?.state == .warning && !session.noticeHidden
    }

    func hideNotice(for surface: Ghostty.SurfaceView) {
        guard let session = sessions.object(forKey: surface), !session.noticeHidden else { return }
        session.noticeHidden = true
        publish(surface)
    }

    /// Whether a pane's agent is one whose transcript can be measured.
    static func canMeasure(_ info: VerticalTabAgentInfo?) -> Bool {
        guard let info else { return false }
        return format(info.kind) != nil
    }

    private static func format(_ kind: VerticalTabAgentKind) -> TranscriptMeter.Format? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        default: return nil
        }
    }

    // MARK: Changing budgets

    /// Sets the pane's own budget, which wins over the defaults.
    func setBudget(_ budget: AgentBudget, for surface: Ghostty.SurfaceView) {
        settings.setPane(budget, for: surface.id)
        settingsChanged()
    }

    /// No budget for this pane, whatever the defaults say. A paused agent carries on.
    func removeBudget(for surface: Ghostty.SurfaceView) {
        let action = sessions.object(forKey: surface)?.resolved?.budget.action ?? .pause
        settings.setPane(AgentBudget(action: action), for: surface.id)
        release(surface)
        settingsChanged()
    }

    /// Forgets what was chosen on the pane's card, so the defaults apply to it again.
    func useDefaults(for surface: Ghostty.SurfaceView) {
        settings.setPane(nil, for: surface.id)
        settingsChanged()
    }

    /// Gives the pane's session more room and lets a paused agent carry on. The raised
    /// budget becomes the pane's own.
    func raise(_ step: BudgetStep, for surface: Ghostty.SurfaceView) {
        guard let session = sessions.object(forKey: surface), let current = session.resolved?.budget else { return }
        settings.setPane(current.raised(step, spent: session.usage.spent, tokens: session.usage.tokens), for: surface.id)
        release(surface)
        settingsChanged()
    }

    /// The default for every new session; nil turns it off.
    func setDefault(_ budget: AgentBudget?, now: Date = Date()) {
        var budget = budget
        budget?.since = now
        settings.everywhere = budget?.isSet == true ? budget : nil
        settingsChanged()
    }

    /// The default for new sessions in a project (its repository root); nil removes it.
    func setProject(_ budget: AgentBudget?, root: String, now: Date = Date()) {
        var budget = budget
        budget?.since = now
        settings.projects[root] = budget?.isSet == true ? budget : nil
        settingsChanged()
    }

    /// The project a folder belongs to: its repository's root, or the folder itself.
    func project(of folder: String, then: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let project = self.project(of: folder)
            DispatchQueue.main.async { then(project) }
        }
    }

    private func settingsChanged() {
        StoredFile.write(json: settings, to: Self.file, what: "the budgets", log: Self.log)
        refreshAll()
        publish(nil)
    }

    // MARK: Storage

    static func load(from file: URL) -> BudgetSettings {
        StoredFile.load(BudgetSettings.self, from: file, what: "the budgets", log: log).value ?? BudgetSettings()
    }

    // MARK: Measuring

    private func refreshAll() {
        for (_, surface) in TerminalWindows.surfaces { refresh(surface, force: true) }
        if !active {
            // Off, or nothing set: whatever a budget froze carries on.
            let frozen = pausedPanes
            pausedPanes = []
            if !frozen.isEmpty { BoardPause.queue.async { BoardPause.set(false, surfaces: frozen) } }
        }
        startTimerIfNeeded()
    }

    /// Reads what's new in a pane's transcript, unless one reading is under way or the last
    /// was a moment ago (`force` skips that wait).
    private func refresh(_ surface: Ghostty.SurfaceView, force: Bool = false) {
        guard active, let info = VerticalTabsAgents.shared.info(for: surface), let format = Self.format(info.kind),
              let path = info.transcriptPath else {
            forget(surface)
            return
        }
        let session: Session
        if let known = sessions.object(forKey: surface), known.transcript == path {
            session = known
        } else {
            // A new session in the pane starts from nothing.
            forget(surface)
            session = Session(transcript: path)
            sessions.setObject(session, forKey: surface)
        }
        if session.reading {
            session.again = true
            return
        }
        let wait = Self.minimumGap - Date().timeIntervalSince(session.lastRead)
        if !force, wait > 0 {
            guard !session.waiting else { return }
            session.waiting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak surface, weak session] in
                session?.waiting = false
                guard let self, let surface else { return }
                self.refresh(surface, force: true)
            }
            return
        }
        session.reading = true
        session.lastRead = Date()
        let snapshot = settings, pane = surface.id, folder = surface.pwd
        let rates = prices(for: info)
        queue.async { [weak self, weak surface] in
            guard let self else { return }
            let reading = self.measure(path, format: format, settings: snapshot, pane: pane, folder: folder, prices: rates)
            DispatchQueue.main.async {
                guard let surface else { return }
                self.apply(reading, to: surface)
            }
        }
    }

    private struct Reading {
        let transcript: String
        let resolved: (budget: AgentBudget, scope: BudgetScope)?
        let usage: BudgetUsage
    }

    /// On `queue`: which budget covers the session, and what it has used if one does.
    private func measure(_ path: String, format: TranscriptMeter.Format, settings: BudgetSettings, pane: UUID,
                         folder: String?, prices: BudgetPrices) -> Reading {
        var meter = meters[path] ?? SessionMeter(transcript: URL(fileURLWithPath: path), format: format)
        let resolved = settings.budget(pane: pane, project: folder.map { project(of: $0) }, sessionStart: meter.start())
        if resolved != nil { meter.read() }
        meters[path] = meter
        return Reading(transcript: path, resolved: resolved, usage: meter.usage(prices))
    }

    /// On `queue`. Git is asked once per folder.
    private func project(of folder: String) -> String {
        if let known = projects[folder] { return known }
        let project = AgentTools.repoRoot(of: folder) ?? folder
        projects[folder] = project
        return project
    }

    /// The prices a pane's session is costed with. Venice's come from its own model list,
    /// once the Local Models window has read it.
    private func prices(for info: VerticalTabAgentInfo) -> BudgetPrices {
        guard info.kind == .codex else { return BudgetPrices() }
        var prices = BudgetPrices(codex: APIPricing.codexRates)
        if info.veniceModel != nil {
            prices.provider = VeniceCodex.provider
            prices.venice = Self.veniceRates(MainActor.assumeIsolated { VeniceAccount.shared.models })
        } else if let local = info.localCodex {
            prices.provider = local.provider
        }
        return prices
    }

    /// Venice's prices per million tokens, for the models that list them.
    static func veniceRates(_ models: [VeniceAPI.Model]) -> [String: APIPricing.CodexRates] {
        var rates: [String: APIPricing.CodexRates] = [:]
        for model in models {
            guard let input = model.inputPrice, let output = model.outputPrice else { continue }
            rates[model.id] = APIPricing.CodexRates(input: input, cached: model.cachedInputPrice ?? input, output: output)
        }
        return rates
    }

    private func apply(_ reading: Reading, to surface: Ghostty.SurfaceView) {
        guard let session = sessions.object(forKey: surface), session.transcript == reading.transcript else { return }
        session.reading = false
        let before = session.status
        if active, let resolved = reading.resolved {
            let budget = resolved.budget
            let fraction = budget.fraction(spent: reading.usage.spent, tokens: reading.usage.tokens)
            session.resolved = resolved
            session.usage = reading.usage
            // Resumed from somewhere else (a board's own Resume): it isn't paused any more.
            if session.progress.paused, !isFrozen(surface) { session.progress.paused = false }
            let event = session.progress.update(fraction: fraction)
            if session.progress.paused, fraction < 1 { release(surface) }
            if event == .warning { session.noticeHidden = false }
            if session.progress.shouldPause(fraction: fraction, action: budget.action) { setFrozen(true, surface) }
            session.status = BudgetStatus(spent: reading.usage.spent, tokens: reading.usage.tokens,
                                          capDollars: budget.dollars.flatMap { $0 > 0 ? $0 : nil },
                                          capTokens: budget.tokens.flatMap { $0 > 0 ? $0 : nil },
                                          fraction: fraction, state: session.progress.state(fraction: fraction))
            if event == .reached, let status = session.status { notify(status, on: surface) }
        } else {
            release(surface)
            session.resolved = nil
            session.status = nil
            session.progress = BudgetProgress()
        }
        if session.status != before { publish(surface) }
        if session.again {
            session.again = false
            refresh(surface, force: true)
        }
    }

    private func forget(_ surface: Ghostty.SurfaceView) {
        guard let session = sessions.object(forKey: surface) else { return }
        release(surface)
        sessions.removeObject(forKey: surface)
        if session.status != nil { publish(surface) }
    }

    private func publish(_ surface: Ghostty.SurfaceView?) {
        objectWillChange.send()
        NotificationCenter.default.post(name: Self.didChange, object: surface)
    }

    // MARK: Pausing

    /// Whether the pane's processes are stopped right now.
    private func isFrozen(_ surface: Ghostty.SurfaceView) -> Bool {
        if let board = TerminalWindows.controller(for: surface) as? BoardController {
            return board.model.paused.contains(surface.id)
        }
        return pausedPanes.contains(surface.id)
    }

    /// Stops or continues everything running in the pane: the board's own pause for a tile,
    /// so the tile shows it and Resume all works, and the same signals for a classic pane.
    private func setFrozen(_ frozen: Bool, _ surface: Ghostty.SurfaceView) {
        if let board = TerminalWindows.controller(for: surface) as? BoardController {
            board.setPaused(frozen, [surface.id])
            return
        }
        let id = surface.id
        guard pausedPanes.contains(id) != frozen else { return }
        if frozen { pausedPanes.insert(id) } else { pausedPanes.remove(id) }
        BoardPause.queue.async { BoardPause.set(frozen, surfaces: [id]) }
        startTimerIfNeeded()
    }

    /// Lets a pane the budget paused carry on.
    private func release(_ surface: Ghostty.SurfaceView) {
        guard let session = sessions.object(forKey: surface), session.progress.paused else { return }
        session.progress.paused = false
        setFrozen(false, surface)
    }

    // MARK: Telling the user

    /// The same notification an agent waiting on you gets; clicking it goes to the pane.
    private func notify(_ status: BudgetStatus, on surface: Ghostty.SurfaceView) {
        guard !VerticalTabsAgents.isBeingViewed(surface) else { return }
        let name = VerticalTabsAgents.shared.info(for: surface)?.name ?? "An agent"
        let title = status.state == .paused ? "\(name) is paused at its budget" : "\(name) reached its budget"
        let body = BudgetFormat.progress(status) + (status.state == .paused ? ". Raise or remove the budget on its card to carry on."
                                                                           : ". It's still running.")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [surface] _, _ in
            center.getNotificationSettings { [surface] settings in
                guard settings.authorizationStatus == .authorized else { return }
                DispatchQueue.main.async { [weak surface] in
                    surface?.showUserNotification(title: title, body: body)
                }
            }
        }
    }

    // MARK: The clock

    /// Runs while an agent with a budget may be working, or a classic pane is paused (to let
    /// it go if the pane closes).
    private func startTimerIfNeeded() {
        guard timer == nil, active || !pausedPanes.isEmpty else { return }
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.ticked() }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ticked() {
        let live = TerminalWindows.surfaces.map { $0.surface }
        var working = false
        var transcripts: Set<String> = []
        for surface in live {
            guard let info = VerticalTabsAgents.shared.info(for: surface), Self.format(info.kind) != nil else { continue }
            if let path = info.transcriptPath { transcripts.insert(path) }
            guard active, info.activity == .working else { continue }
            working = true
            // A paused agent writes nothing; only check that it's still paused.
            if let session = sessions.object(forKey: surface), session.progress.paused, isFrozen(surface) { continue }
            refresh(surface)
        }
        // A paused pane that closed is continued, so what's in it can quit.
        let gone = pausedPanes.subtracting(live.map(\.id))
        if !gone.isEmpty {
            pausedPanes.subtract(gone)
            BoardPause.queue.async { BoardPause.set(false, surfaces: gone) }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.meters = self.meters.filter { transcripts.contains($0.key) }
        }
        if !working, pausedPanes.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
#endif
