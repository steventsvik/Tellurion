#if os(macOS)
import AppKit

/// One session a search found, kept for the glasses that asked so it can be resumed.
struct GlassesSearchHit: Equatable {
    var session: String
    var agent: String
    var title: String
    var snippet: String
    var folder: String?
    /// Resumed with a plain command line; ones on another provider are left to the Mac.
    var plain: Bool
}

/// What takes a while to work out, kept between looks: today's activity.
private final class GlassesToolCache {
    static let shared = GlassesToolCache()
    var activity: [String] = []
    var activityAt = Date.distantPast
    var working = false
}

/// The Mac's tools on the glasses: the list, a page for the ones worth a glance, and
/// opening the others' windows on the Mac. Reading shows no more than a tool's own rows
/// show in a line; everything that changes something is rate-limited where it arrives,
/// logged without its content, and only ever sent by the glasses from a confirming tap.
extension GlassesServer {
    // MARK: The list

    /// The tools that are on, each with a few words about it now.
    func toolList(_ tools: GlassesTools, panes: [GlassesAgent]) -> [[String: Any]] {
        var summaries: [GlassesTool: String] = [:]
        var bright: Set<GlassesTool> = []
        let agents = panes.filter(\.isAgent)
        let needs = agents.filter { $0.activity == .needsPermission || $0.activity == .needsInput }.count
        summaries[.mission] = needs > 0 ? (needs == 1 ? "1 needs you" : "\(needs) need you") : "\(agents.count) agents"
        if needs > 0 { bright.insert(.mission) }
        summaries[.orchestrator] = ClassicOrchestrators.shared.list.isEmpty ? "None started" : "\(ClassicOrchestrators.shared.list.count) started"
        summaries[.review] = tools.review > 0 ? "\(tools.review) waiting" : "Nothing to review"
        summaries[.checks] = tools.failedChecks.isEmpty ? "None failed" : "\(tools.failedChecks.count) failed"
        if !tools.failedChecks.isEmpty { bright.insert(.checks) }
        summaries[.budgets] = tools.budgets.contains { $0.fraction >= GlassesTools.budgetFloor } ? "Near a cap" : "\(tools.budgets.count) set"
        summaries[.conflicts] = tools.conflicts > 0 ? "\(tools.conflicts) between agents" : "None"
        summaries[.localhost] = tools.servers.isEmpty ? "None running" : "\(tools.servers.count) running"
        summaries[.usage] = tools.usage.first.map { entry in
            entry.windows.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
        }
        summaries[.search] = "Hold to say what to look for"
        summaries[.ruler] = "How many characters fit"
        return GlassesToolList.items(GlassesTool.listed(isOn: TellurionSettings.isOn), summaries: summaries, bright: bright)
    }

    // MARK: Pages

    /// A page was opened: what it shows is brought up to date in the background.
    func prepare(_ tool: GlassesTool) {
        switch tool {
        case .ports: PortsMonitor.shared.refresh()
        case .background: Housekeeping.shared.refresh()
        case .activity: refreshActivity()
        default: break
        }
    }

    /// A tool's page as it stands now.
    func page(_ tool: GlassesTool, for session: Session, panes: [GlassesAgent]) -> GlassesToolPage {
        var page = GlassesToolPage(tool: tool)
        let names = GlassesAgents.names(panes)
        let home = NSHomeDirectory()
        switch tool {
        case .mission:
            let agents = zip(panes, names).filter { $0.0.isAgent }
            // The ones that need you first, as Mission Control has them.
            for (pane, name) in agents.sorted(by: { GlassesAgents.rank($0.0) < GlassesAgents.rank($1.0) }) {
                let needs = pane.activity == .needsPermission || pane.activity == .needsInput
                let words = GlassesAgents.glyph(pane.activity, unseen: pane.unseen) + " "
                    + [name, pane.group?.name, GlassesAgents.activity(pane.activity)].compactMap { $0 }.joined(separator: " · ")
                page.rows.append(.init(id: pane.id.uuidString, text: words, sub: pane.detail ?? pane.task ?? "", bright: needs,
                                       open: "p:" + pane.id.uuidString))
            }
            page.note = "No agents running."
        case .orchestrator:
            for root in projectRoots() {
                let orchestrator = ClassicOrchestrators.shared.orchestrator(root: root)
                page.rows.append(.init(id: Self.projectID(root),
                                       text: ProjectPath.displayName(root) + " · " + (orchestrator?.status.line ?? "Not started"),
                                       sub: orchestrator?.team.goal ?? ClassicOrchestrators.shared.record(root: root)?.goal ?? "",
                                       open: "o:" + Self.projectID(root)))
            }
            page.note = "No project has agents an orchestrator could run."
        case .review:
            for item in ReviewInbox.shared.items {
                let files = item.files.count == 1 ? "1 file" : "\(item.files.count) files"
                var row = GlassesToolPage.Row(id: item.id.uuidString,
                                              text: "\(item.agent.displayName) · \(item.repoName) · \(files) +\(item.added) -\(item.removed)",
                                              sub: item.task ?? "", bright: item.unseen)
                if ReviewInbox.shared.surface(for: item) != nil {
                    row.actions.append(.init(action: .feedback, label: "Say feedback", ask: "", name: item.agent.displayName))
                }
                row.actions.append(.init(action: .open, label: "Open on Mac", ask: "Open this review on your Mac?"))
                page.rows.append(row)
            }
            page.note = "Nothing to review."
        case .checks:
            for (root, run) in ProjectChecks.shared.runs.sorted(by: { $0.key < $1.key }) {
                let state: String
                switch run.result.state {
                case .running: state = "running"
                case .passed: state = "passed"
                case .failed: state = "failed"
                case .timedOut: state = "timed out"
                }
                let name = ProjectPath.displayName(root)
                page.rows.append(.init(id: Self.projectID(root), text: "\(name) · \(state)", sub: run.result.summary,
                                       bright: run.result.state == .failed || run.result.state == .timedOut,
                                       actions: [.init(action: .run, label: "Run now", ask: "Run \(name)'s check now?")]))
            }
            page.note = "No check has run yet."
        case .budgets:
            for (pane, name) in zip(panes, names) where pane.isAgent {
                guard let surface = surface(pane.id), let status = AgentBudgets.shared.status(for: surface) else { continue }
                let state: String
                switch status.state {
                case .ok: state = "within its budget"
                case .warning: state = "close to its cap"
                case .reached: state = "at its cap"
                case .paused: state = "paused at its cap"
                }
                page.rows.append(.init(id: pane.id.uuidString, text: "\(name) · \(BudgetFormat.progress(status))", sub: state,
                                       bright: status.state == .reached || status.state == .paused,
                                       actions: [
                                           .init(action: .add, label: "Add and resume", ask: "Raise \(name)'s cap a step and let it carry on?"),
                                           .init(action: .remove, label: "Remove", ask: "Remove \(name)'s budget?"),
                                       ]))
            }
            page.note = "No agent has a budget."
        case .conflicts:
            for (pane, name) in zip(panes, names) {
                for conflict in AgentConflicts.shared.byPane[pane.id] ?? [] {
                    page.rows.append(.init(id: pane.id.uuidString + ":" + String(page.rows.count), text: conflict.path,
                                           sub: ([name] + conflict.others).joined(separator: ", "), bright: true))
                }
            }
            page.note = "No two agents are in the same file."
        case .worktrees:
            for record in AgentWorktreeList.shared.records {
                page.rows.append(.init(id: record.id.uuidString, text: "\(record.repoName) · \(record.branch)",
                                       sub: record.agent + " · " + GlassesProjects.shortPath(record.path, home: home)))
            }
            page.note = "No worktrees."
        case .localhost:
            for server in LocalhostSessions.shared.sessions {
                let state: String
                switch server.state {
                case .starting: state = "starting"
                case .live: state = "live"
                case .stopped: state = "stopped"
                case .detached: state = "detached"
                }
                let address = server.url.map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") } ?? "no address yet"
                var row = GlassesToolPage.Row(id: server.id, text: "\(server.project.name) · \(address) · \(state)",
                                              sub: server.isRunning ? "CPU \(Int(server.cpu.rounded()))% · \(Int(server.memoryMB.rounded())) MB" : "")
                if server.isRunning {
                    row.actions.append(.init(action: .stop, label: "Stop", ask: "Stop \(server.project.name)'s server?"))
                }
                row.actions.append(.init(action: .restart, label: "Restart", ask: "Restart \(server.project.name)'s server?"))
                page.rows.append(row)
            }
            page.note = "No localhost sessions."
        case .ports:
            for entry in PortsMonitor.shared.entries.sorted(by: { $0.port < $1.port }) {
                page.rows.append(.init(id: "\(entry.port)-\(entry.pid)", text: ":\(entry.port) · \(entry.title)", sub: entry.processName))
            }
            page.note = "Nothing is listening, or still looking."
        case .usage:
            for entry in UsageMonitor.shared.entries {
                for window in entry.windows {
                    let passed = window.resetsAt.map { $0 <= Date() } ?? false
                    let resets = window.resetsAt.flatMap { passed ? nil : "resets " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) }
                    page.rows.append(.init(id: entry.id + ":" + window.label,
                                           text: "\(entry.name) · \(window.label) · \(passed ? 0 : Int(window.usedPercent.rounded()))%",
                                           sub: resets ?? "", bright: !passed && window.usedPercent >= 80))
                }
            }
            page.note = "No usage numbers yet."
        case .activity:
            refreshActivity()
            page.rows = GlassesToolCache.shared.activity.enumerated().map { .init(id: "a\($0.offset)", text: $0.element) }
            page.note = "Adding today up..."
        case .background:
            let items = Housekeeping.shared.items.sorted { $0.score > $1.score }
            for item in items.prefix(12) {
                page.rows.append(.init(id: item.id, text: "\(item.title) · \(item.rating.label)", sub: item.detail, bright: item.rating >= .stale))
            }
            page.note = Housekeeping.shared.staleCount == 0 ? "Nothing stale." : "\(Housekeeping.shared.staleCount) stale"
        case .scoreboard:
            for standing in AgentRaceScores.standings(AgentRaceScores.shared.records) {
                let who = [standing.agent, standing.model].compactMap { $0 }.joined(separator: " ")
                page.rows.append(.init(id: who, text: "\(who) · \(standing.wins) of \(standing.races) won",
                                       sub: standing.medianSeconds.map { "Median \(Int($0.rounded()))s" } ?? ""))
            }
            page.note = "No races yet."
        case .search:
            page.voice = (.query, "search")
            for hit in session.found {
                var row = GlassesToolPage.Row(id: hit.session, text: hit.title, sub: hit.snippet)
                if hit.plain, hit.folder != nil {
                    row.actions.append(.init(action: .resume, label: "Resume on Mac", ask: "Resume this session in a new tab on your Mac?"))
                }
                page.rows.append(row)
            }
            page.note = session.searching ? "Searching..." : "Hold and say what to look for."
        default:
            page.note = "This one opens on your Mac."
        }
        return page
    }

    /// Today in three lines, as the Activity window's tiles have it. Reading the sessions
    /// is slow the first time, so it's done off the main thread and kept for a minute.
    private func refreshActivity() {
        let cache = GlassesToolCache.shared
        guard !cache.working, Date().timeIntervalSince(cache.activityAt) > 60 else { return }
        cache.working = true
        DispatchQueue.global(qos: .utility).async {
            let day = ActivityStats.dayKey(Date())
            let sessions = ActivityStats.shared.sessions(since: Calendar.current.startOfDay(for: Date())).filter {
                $0.activeByDay[day] != nil || $0.claudeCostByDay[day] != nil || $0.codexTokens[day] != nil
            }
            let active = sessions.reduce(0.0) { $0 + ($1.activeByDay[day] ?? 0) }
            var value = sessions.reduce(0.0) { $0 + ($1.claudeCostByDay[day] ?? []).reduce(0, +) }
            for session in sessions {
                for (model, tokens) in session.codexTokens[day] ?? [:] {
                    if let cost = APIPricing.codexCost(model: model, tokens: tokens, rates: APIPricing.codexRates) { value += cost.input + cost.output }
                }
            }
            let minutes = Int(active / 60)
            let lines = [
                sessions.count == 1 ? "1 session today" : "\(sessions.count) sessions today",
                "Active " + (minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"),
                String(format: "Worth $%.2f at API prices", value),
            ]
            DispatchQueue.main.async {
                cache.activity = lines
                cache.activityAt = Date()
                cache.working = false
            }
        }
    }

    // MARK: Opening a tool on the Mac

    /// Opens a tool's window the way its row in the Tools panel does.
    func open(_ tool: GlassesTool, for session: Session) {
        let owner = TerminalWindows.front ?? TerminalWindows.all.first
        let folder = owner?.focusedSurface?.pwd
        var opened = tool.opensOnMac && (tool.feature.map(TellurionSettings.isOn) ?? true)
        if opened {
            switch tool {
            case .editor:
                if let owner { EditorPanel.shared.toggle(from: owner) } else { opened = false }
            case .visualFix: VisualFixPanel.shared.toggle(owner)
            case .commandHistory:
                if let owner { CommandBlocksPanel.shared.toggle(owner) } else { opened = false }
            case .mission: MissionControl.show()
            case .orchestrator: opened = ClassicOrchestrators.show(from: owner) != nil
            case .races:
                if let owner { AgentRaces.showSetup(from: owner) } else { opened = false }
            case .scoreboard: AgentRaceScores.showScoreboard()
            case .review: ReviewInbox.show()
            case .checks: ProjectChecksWindow.show(folder: folder)
            case .activity: ActivityDashboard.toggle()
            case .search: SessionSearch.toggle()
            case .budgets: BudgetsWindow.show()
            case .worktrees: AgentWorktreesWindow.show()
            case .localhost: LocalhostManager.show()
            case .skills: SkillsWindow.show(folder: folder)
            case .memory: MemoryWindow.showForFrontTab()
            case .environment: EnvironmentWindow.show(folder: folder)
            case .background: HousekeepingWindow.show()
            case .phone: PhoneSetup.show()
            case .localModels: LocalModelsWindow.show()
            case .layout: LayoutWindow.show()
            case .design: DesignWindow.show()
            case .settings: TellurionSettingsWindow.show()
            case .conflicts, .ports, .usage, .ruler: opened = false
            }
        }
        Self.log.info("Tool \(tool.rawValue, privacy: .public) from \(session.peer.device.id, privacy: .public): opened \(opened)")
        session.peer.send(GlassesRoutes.json(["t": "did", "ok": opened, "message": opened ? "\(tool.title) is open on your Mac" : "\(tool.title) couldn't be opened"]))
    }

    // MARK: Actions

    /// One of a page's actions. The request has already been checked against what the tool
    /// may be asked; here the row has to still be there.
    func perform(_ action: GlassesToolAction, on row: String, of tool: GlassesTool, text: String?, for session: Session) {
        var message = "That's gone."
        var done = false
        let pane = UUID(uuidString: row).flatMap { surface($0) }
        switch (tool, action) {
        case (.review, .open):
            if let item = ReviewInbox.shared.items.first(where: { $0.id.uuidString == row }) {
                ReviewInbox.show(selecting: item)
                (done, message) = (true, "Open on your Mac")
            }
        case (.review, .feedback):
            // Queued as the agent's next prompt, like a message: never into a pane with no agent.
            if let item = ReviewInbox.shared.items.first(where: { $0.id.uuidString == row }), let text,
               let target = ReviewInbox.shared.surface(for: item) {
                if let refusal = GlassesRules.sayRefusal(hasAgent: VerticalTabsAgents.shared.info(for: target) != nil, text: text) {
                    message = refusal
                } else {
                    AgentInbox.shared.deliver(text, to: target, label: "From your glasses")
                    (done, message) = (true, "Sent as feedback")
                }
            }
        case (.checks, .run):
            if let root = ProjectChecks.shared.runs.keys.first(where: { PhoneDevices.equal(Self.projectID($0), row) }) {
                ProjectChecks.shared.runNow(root)
                (done, message) = (true, "Running")
            }
        case (.budgets, .add):
            if let pane, AgentBudgets.shared.status(for: pane) != nil {
                AgentBudgets.shared.raise(.fixed, for: pane)
                (done, message) = (true, "Raised")
            }
        case (.budgets, .remove):
            if let pane, AgentBudgets.shared.status(for: pane) != nil {
                AgentBudgets.shared.removeBudget(for: pane)
                (done, message) = (true, "Budget removed")
            }
        case (.localhost, .stop):
            if let server = LocalhostSessions.shared.sessions.first(where: { $0.id == row }) {
                LocalhostSessions.shared.stop(server)
                (done, message) = (true, "Stopping")
            }
        case (.localhost, .restart):
            if let server = LocalhostSessions.shared.sessions.first(where: { $0.id == row }) {
                MainActor.assumeIsolated { LocalhostSessions.shared.restart(server) }
                (done, message) = (true, "Restarting")
            }
        case (.search, .query):
            if let text {
                search(text, for: session)
                (done, message) = (true, "Searching")
            }
        case (.search, .resume):
            if let hit = session.found.first(where: { $0.session == row }) {
                done = resume(hit)
                message = done ? "Resumed in a new tab on your Mac" : "Resume that one on your Mac."
            }
        default:
            message = "That can't be done from here."
        }
        Self.log.info("Tool \(tool.rawValue, privacy: .public) \(action.rawValue, privacy: .public) from \(session.peer.device.id, privacy: .public): done \(done)")
        session.peer.send(GlassesRoutes.json(["t": "did", "ok": done, "message": message]))
    }

    /// Looks through past sessions for what was said, off the main thread, and keeps the
    /// first few for the glasses that asked.
    private func search(_ text: String, for session: Session) {
        guard !session.searching else { return }
        session.searching = true
        session.found = []
        session.toolPageBuilt = .distantPast
        let request = SessionSearchEngine.Request(query: SessionSearchQuery(text), filters: SessionSearchFilters(), limit: 8)
        DispatchQueue.global(qos: .userInitiated).async { [weak session] in
            var hits: [GlassesSearchHit] = []
            let lock = NSLock()
            SessionSearchEngine.search(request, roots: .standard, cache: SessionSearch.cache) { result in
                let hit = GlassesSearchHit(session: result.meta.session, agent: result.meta.agent,
                                           title: result.meta.title ?? "Untitled session",
                                           snippet: result.snippets.first?.text ?? "", folder: result.meta.cwd,
                                           plain: result.meta.codexProvider == nil && UUID(uuidString: result.meta.session) != nil)
                lock.lock()
                hits.append(hit)
                lock.unlock()
            }
            DispatchQueue.main.async {
                guard let session else { return }
                session.found = Array(hits.prefix(8))
                session.searching = false
                session.toolPageBuilt = .distantPast
            }
        }
    }

    /// A found session resumed in a new tab, the way the Activity window does it.
    private func resume(_ hit: GlassesSearchHit) -> Bool {
        guard hit.plain, let folder = hit.folder, let kind = VerticalTabAgentKind(rawValue: hit.agent),
              let line = AgentResume.line(kind, session: hit.session),
              let owner = TerminalWindows.front ?? TerminalWindows.all.first else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        config.initialInput = line
        return TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config) != nil
    }
}
#endif
