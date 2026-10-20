#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// A dev server running in its own tab, so it keeps running after the agent (or tab) that
/// started it is gone. Agents' dev-server commands are redirected here by the hooks
/// (`~/.ghostty-extreme/bin/localhost`); servers can also be started from the sidebar or
/// moved here from wherever they were running.
struct LocalhostSession: Identifiable, Equatable {
    enum State: Equatable {
        /// Running, not listening on a port yet.
        case starting
        case live
        case stopped(code: Int32)
        /// The runner ended and left a plain shell in the tab.
        case detached
    }

    let id: String
    let cwd: String
    let command: String
    let log: String
    let agent: VerticalTabAgentKind?
    let created: Date
    var state: State = .starting
    var ports: [Int] = []
    /// The port it went live on (the lowest then): its address. Other ports come and go,
    /// like a dev server's internal ones.
    var mainPort: Int?
    var runnerPID: Int32?
    var liveSince: Date?
    var cpu: Double = 0
    var memoryMB: Double = 0

    var project: LocalhostProject { LocalhostProject(folder: cwd) }
    var framework: LocalhostFramework { LocalhostFramework.detect(command: command, cwd: cwd) }
    var url: URL? {
        let port = mainPort == nil ? ports.first : ports.first { $0 == mainPort }
        return port.map { URL(string: "http://localhost:\($0)")! }
    }
    var isRunning: Bool { state == .starting || state == .live }
    /// It was live, but its port isn't listening any more while its processes keep running
    /// (e.g. Next's server crashed and the `next dev` above it didn't exit).
    var isQuiet: Bool { state == .starting && liveSince != nil }
}

/// A listening dev server that isn't in a localhost session (started in a normal tab, by an
/// agent that isn't hooked up, or outside Tellurion).
struct LocalhostOtherServer: Identifiable, Equatable {
    let pid: Int32
    /// The process to restart when moving it into a session (e.g. `npm run dev`, not the
    /// `node vite` it spawned).
    let rootPID: Int32
    let rootCommand: String
    let ports: [Int]
    let cwd: String?
    let name: String

    var id: Int32 { pid }
    /// Nil for servers started from the home folder (or /), which isn't a project.
    var project: LocalhostProject? {
        guard let cwd, cwd != NSHomeDirectory(), cwd != "/" else { return nil }
        return LocalhostProject(folder: cwd)
    }
    /// The project, or else the program's name (`ngrok http 3000` -> "ngrok").
    var displayName: String {
        project?.name ?? (rootCommand.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? name)
    }
    var framework: LocalhostFramework { LocalhostFramework.detect(command: rootCommand, cwd: cwd) }
    var url: URL? { ports.first.map { URL(string: "http://localhost:\($0)")! } }
}

/// The project a server belongs to: its git repository, or else its folder.
struct LocalhostProject: Hashable {
    let root: String

    init(folder: String) {
        var dir = URL(fileURLWithPath: folder)
        var found: String?
        // Walk up to the repository root without running git (this is called from views).
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                found = dir.path
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == NSHomeDirectory() { break }
            dir = parent
        }
        root = found ?? folder
    }

    var name: String { (root as NSString).lastPathComponent }

    /// A stable, vivid color per project so its servers are easy to pick out.
    var color: Color {
        let palette: [Color] = [
            Color(red: 0.20, green: 0.83, blue: 0.93), Color(red: 0.62, green: 0.45, blue: 1.00),
            Color(red: 1.00, green: 0.45, blue: 0.70), Color(red: 0.35, green: 0.90, blue: 0.55),
            Color(red: 1.00, green: 0.66, blue: 0.25), Color(red: 0.40, green: 0.60, blue: 1.00),
            Color(red: 0.98, green: 0.85, blue: 0.30), Color(red: 1.00, green: 0.42, blue: 0.40),
        ]
        let hash = root.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// What kind of server it is, for its badge.
struct LocalhostFramework: Equatable {
    let name: String
    let symbol: String
    let color: Color

    static let generic = LocalhostFramework(name: "Server", symbol: "server.rack", color: .teal)

    private static let known: [(needle: String, framework: LocalhostFramework)] = [
        ("vite", .init(name: "Vite", symbol: "bolt.fill", color: Color(red: 0.62, green: 0.45, blue: 1.0))),
        ("next", .init(name: "Next.js", symbol: "triangle.fill", color: .white)),
        ("nuxt", .init(name: "Nuxt", symbol: "mountain.2.fill", color: Color(red: 0.0, green: 0.86, blue: 0.51))),
        ("astro", .init(name: "Astro", symbol: "sparkles", color: Color(red: 1.0, green: 0.36, blue: 0.0))),
        ("remix", .init(name: "Remix", symbol: "r.circle.fill", color: .white)),
        ("react-scripts", .init(name: "React", symbol: "atom", color: Color(red: 0.38, green: 0.85, blue: 0.98))),
        ("ng serve", .init(name: "Angular", symbol: "a.circle.fill", color: Color(red: 0.87, green: 0.19, blue: 0.23))),
        ("svelte", .init(name: "Svelte", symbol: "s.circle.fill", color: Color(red: 1.0, green: 0.24, blue: 0.0))),
        ("gatsby", .init(name: "Gatsby", symbol: "g.circle.fill", color: Color(red: 0.4, green: 0.2, blue: 0.6))),
        ("storybook", .init(name: "Storybook", symbol: "book.fill", color: Color(red: 1.0, green: 0.28, blue: 0.52))),
        ("expo", .init(name: "Expo", symbol: "iphone", color: .white)),
        ("webpack", .init(name: "Webpack", symbol: "cube.fill", color: Color(red: 0.55, green: 0.84, blue: 0.98))),
        ("parcel", .init(name: "Parcel", symbol: "shippingbox.fill", color: Color(red: 0.87, green: 0.65, blue: 0.3))),
        ("wrangler", .init(name: "Workers", symbol: "cloud.fill", color: Color(red: 0.96, green: 0.51, blue: 0.13))),
        ("manage.py", .init(name: "Django", symbol: "leaf.fill", color: Color(red: 0.27, green: 0.72, blue: 0.47))),
        ("flask", .init(name: "Flask", symbol: "flask.fill", color: .white)),
        ("fastapi", .init(name: "FastAPI", symbol: "bolt.horizontal.fill", color: Color(red: 0.0, green: 0.59, blue: 0.53))),
        ("uvicorn", .init(name: "Uvicorn", symbol: "bolt.horizontal.fill", color: Color(red: 0.0, green: 0.59, blue: 0.53))),
        ("streamlit", .init(name: "Streamlit", symbol: "chart.bar.fill", color: Color(red: 1.0, green: 0.29, blue: 0.29))),
        ("jupyter", .init(name: "Jupyter", symbol: "book.closed.fill", color: Color(red: 0.95, green: 0.46, blue: 0.14))),
        ("http.server", .init(name: "Python", symbol: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.99, green: 0.83, blue: 0.25))),
        ("rails", .init(name: "Rails", symbol: "tram.fill", color: Color(red: 0.8, green: 0.0, blue: 0.0))),
        ("bin/dev", .init(name: "Rails", symbol: "tram.fill", color: Color(red: 0.8, green: 0.0, blue: 0.0))),
        ("artisan", .init(name: "Laravel", symbol: "l.circle.fill", color: Color(red: 1.0, green: 0.18, blue: 0.13))),
        ("php", .init(name: "PHP", symbol: "p.circle.fill", color: Color(red: 0.47, green: 0.48, blue: 0.71))),
        ("hugo", .init(name: "Hugo", symbol: "h.circle.fill", color: Color(red: 1.0, green: 0.25, blue: 0.51))),
        ("jekyll", .init(name: "Jekyll", symbol: "j.circle.fill", color: Color(red: 0.8, green: 0.0, blue: 0.0))),
        ("mkdocs", .init(name: "MkDocs", symbol: "doc.text.fill", color: Color(red: 0.33, green: 0.5, blue: 1.0))),
        ("phx.server", .init(name: "Phoenix", symbol: "flame.fill", color: Color(red: 0.99, green: 0.44, blue: 0.2))),
    ]

    private static var scriptCache: [String: String] = [:]

    /// Matches the command, looking through `npm run <script>` to the script's own command.
    static func detect(command: String, cwd: String?) -> LocalhostFramework {
        var haystack = command.lowercased()
        if let cwd, let script = packageScript(in: command) {
            haystack += " " + scriptBody(script, cwd: cwd).lowercased()
        }
        return known.first { haystack.contains($0.needle) }?.framework ?? .generic
    }

    private static func packageScript(in command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard let tool = words.first, ["npm", "pnpm", "yarn", "bun"].contains(tool) else { return nil }
        let rest = words.dropFirst().filter { $0 != "run" }
        return rest.first
    }

    private static func scriptBody(_ script: String, cwd: String) -> String {
        let key = cwd + "#" + script
        if let cached = scriptCache[key] { return cached }
        let file = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        var body = ""
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: String] {
            body = scripts[script] ?? ""
        }
        scriptCache[key] = body
        return body
    }

    /// `package.json` scripts that look like servers, for the "New server" sheet.
    static func serverScripts(in folder: String) -> [(name: String, body: String)] {
        let file = URL(fileURLWithPath: folder).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        let preferred = ["dev", "start", "serve", "preview", "develop", "storybook"]
        return scripts
            .filter { name, _ in preferred.contains { name == $0 || name.hasPrefix($0 + ":") } }
            .sorted { a, b in
                let ia = preferred.firstIndex { a.key == $0 || a.key.hasPrefix($0 + ":") } ?? 99
                let ib = preferred.firstIndex { b.key == $0 || b.key.hasPrefix($0 + ":") } ?? 99
                return ia != ib ? ia < ib : a.key < b.key
            }
            .map { (name: $0.key, body: $0.value) }
    }

    /// The package manager a folder uses, from its lockfile.
    static func packageManager(in folder: String) -> String {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) }
        if has("pnpm-lock.yaml") { return "pnpm" }
        if has("yarn.lock") { return "yarn" }
        if has("bun.lockb") || has("bun.lock") { return "bun" }
        return "npm"
    }
}

final class LocalhostSessions: ObservableObject {
    static let shared = LocalhostSessions()

    static let eventTitle = "ghostty-extreme://localhost"
    static let windowID = "localhost-manager"

    @Published private(set) var sessions: [LocalhostSession] = []
    /// Other dev servers listening on this Mac. Only refreshed while the manager is open.
    @Published private(set) var others: [LocalhostOtherServer] = []
    /// A session that just went live, shown briefly over the terminal.
    @Published var toast: LocalhostSession?

    /// Each session's terminal: a tab of its own, or a tile on a board.
    private var tabs: [String: Weak<Ghostty.SurfaceView>] = [:]
    private var timer: Timer?
    private var polling = false
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.localhost", qos: .utility)
    private var toastDismiss: DispatchWorkItem?
    /// Polls in a row that a live session wasn't listening, by id.
    private var quietPolls: [String: Int] = [:]
    /// Set while the manager window is open, so other servers are scanned too.
    var scanOthers = false {
        didSet { if scanOthers { poll() } else { others = [] } }
    }

    static var directory: URL { AgentTools.root.appendingPathComponent("localhost", isDirectory: true) }
    static var runner: String { AgentTools.root.appendingPathComponent("bin/localhost-run").path }

    private init() {
        cleanUpOldFiles()
        // Restored windows bring back the tab titles of last run's sessions, but not the
        // servers; don't let those tabs pose as localhost sessions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for controller in TerminalController.all
            where controller.titleOverride?.hasPrefix("localhost") == true && self.session(for: controller) == nil {
                controller.titleOverride = nil
            }
        }
    }

    var liveCount: Int { sessions.filter { $0.state == .live }.count }

    /// The session a classic tab runs. A board isn't one session; ask about its tiles.
    func session(for controller: BaseTerminalController) -> LocalhostSession? {
        guard !(controller is BoardController) else { return nil }
        return controller.surfaceTree.lazy.compactMap { self.session(for: $0) }.first
    }

    func session(for surface: Ghostty.SurfaceView) -> LocalhostSession? {
        guard let id = tabs.first(where: { $0.value.value === surface })?.key else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The session's terminal, while it's open.
    func surface(for session: LocalhostSession) -> Ghostty.SurfaceView? {
        guard let surface = tabs[session.id]?.value, TerminalWindows.controller(for: surface) != nil else { return nil }
        return surface
    }

    func controller(for session: LocalhostSession) -> BaseTerminalController? {
        surface(for: session).flatMap { TerminalWindows.controller(for: $0) }
    }

    /// Sessions end when the app quits, so anything left on disk is stale.
    private func cleanUpOldFiles() {
        let fm = FileManager.default
        let dir = Self.directory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        for file in files {
            if file.pathExtension == "log" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < weekAgo { try? fm.removeItem(at: file) }
            } else if file.lastPathComponent.hasSuffix(".status.json") || file.lastPathComponent.hasSuffix(".restart") {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: Events

    private struct Event: Decodable {
        let event: String
        let id: String
        let pid: Int32?
        let code: Int32?
    }

    /// Handles `ghostty-extreme://localhost` events: `open`/`stop`/`restart` from the
    /// `localhost` command (usually run by an agent), `running`/`exited`/`close`/`detached`
    /// from a session's runner.
    func handle(body: String, from surface: Ghostty.SurfaceView) {
        guard let data = body.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data),
              event.id.hasPrefix("lh-"), !event.id.contains("/") else { return }
        switch event.event {
        case "open":
            open(id: event.id, from: surface)
        case "running":
            update(event.id) {
                $0.runnerPID = event.pid
                $0.state = .starting
                $0.ports = []
                $0.mainPort = nil
                $0.liveSince = nil
            }
            // Adopt the tab if the session was opened before (e.g. restart after "shell here").
            if tabs[event.id]?.value == nil, TerminalWindows.controller(of: surface.window) != nil {
                tabs[event.id] = Weak(surface)
            }
            ensureTimer()
            poll()
        case "exited":
            update(event.id) {
                $0.state = .stopped(code: event.code ?? 0)
                $0.ports = []
                $0.cpu = 0
                $0.memoryMB = 0
            }
        case "detached":
            update(event.id) { $0.state = .detached }
        case "close":
            if let session = sessions.first(where: { $0.id == event.id }) { close(session, confirm: false) }
        case "stop":
            if let session = sessions.first(where: { $0.id == event.id }) { stop(session) }
        case "restart":
            if let session = sessions.first(where: { $0.id == event.id }) {
                Task { @MainActor in self.restart(session) }
            }
        default:
            break
        }
    }

    private struct Request: Decodable {
        let id: String
        let cwd: String
        let command: String
        let log: String?
        let agent: String?
    }

    private func open(id: String, from surface: Ghostty.SurfaceView) {
        let file = Self.directory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: file),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              request.id == id else { return }
        // Who asked: an agent running in the requesting pane, or nobody in particular.
        let kind = request.agent.flatMap { $0.isEmpty ? nil : VerticalTabAgentKind(id: $0) }
            ?? VerticalTabsAgents.shared.info(for: surface)?.kind
        let session = LocalhostSession(
            id: id, cwd: request.cwd, command: request.command,
            log: request.log ?? Self.directory.appendingPathComponent("\(id).log").path,
            agent: kind, created: Date())
        let owner = TerminalWindows.controller(of: surface.window)
        launch(session, from: owner, focus: false)
    }

    // MARK: Starting

    /// Starts `command` in `folder` as a new session. Used by the sidebar and manager.
    @discardableResult
    func start(command: String, in folder: String, from owner: BaseTerminalController?, focus: Bool = true) -> LocalhostSession? {
        let id = "lh-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...99999))"
        let log = Self.directory.appendingPathComponent("\(id).log").path
        let request: [String: Any] = ["id": id, "cwd": folder, "command": command, "log": log, "agent": ""]
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted])
            try data.write(to: Self.directory.appendingPathComponent("\(id).json"))
        } catch {
            return nil
        }
        let session = LocalhostSession(id: id, cwd: folder, command: command, log: log, agent: nil, created: Date())
        launch(session, from: owner, focus: focus)
        return session
    }

    /// Starts a server again in a tab that already exists (a window restored after an
    /// update), so it's a localhost session there like before.
    @MainActor
    @discardableResult
    func restart(command: String, in folder: String, tab controller: TerminalController) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.runner),
              let surface = controller.surfaceTree.first else { return false }
        let id = "lh-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...99999))"
        let log = Self.directory.appendingPathComponent("\(id).log").path
        let request: [String: Any] = ["id": id, "cwd": folder, "command": command, "log": log, "agent": ""]
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted])
            try data.write(to: Self.directory.appendingPathComponent("\(id).json"))
        } catch {
            return false
        }
        let session = LocalhostSession(id: id, cwd: folder, command: command, log: log, agent: nil, created: Date())
        controller.titleOverride = "localhost · \(session.project.name)"
        sessions.append(session)
        tabs[id] = Weak(surface)
        writeStatus(session)
        if let model = surface.surfaceModel {
            ResumeAfterUpdate.run(" \(AgentTools.shellQuote(Self.runner)) \(id)", in: model)
        }
        ensureTimer()
        VerticalTabs.setNeedsRefresh()
        return true
    }

    /// Opens the session's terminal beside `owner`: a tab, or a tile when it's a board.
    private func launch(_ session: LocalhostSession, from owner: BaseTerminalController?, focus: Bool) {
        guard FileManager.default.isExecutableFile(atPath: Self.runner) else {
            let alert = NSAlert()
            alert.messageText = "Localhost sessions aren't installed"
            alert.informativeText = "Run agent-hooks/install.sh from the Tellurion repository, then try again."
            alert.runModal()
            return
        }
        guard let owner = owner ?? TerminalWindows.front ?? TerminalWindows.all.first else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = session.cwd
        // A leading space keeps it out of shell history.
        config.initialInput = " \(AgentTools.shellQuote(Self.runner)) \(session.id)\n"
        let agent = owner.focusedSurface
        guard let surface = TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config,
                                                        title: "localhost · \(session.project.name)") else { return }
        sessions.append(session)
        tabs[session.id] = Weak(surface)
        writeStatus(session)
        if !focus {
            // Stay with the agent; the sidebar card and toast show the new session.
            owner.window?.makeKeyAndOrderFront(nil)
            if owner is BoardController, let agent { Ghostty.moveFocus(to: agent) }
        }
        ensureTimer()
        VerticalTabs.setNeedsRefresh()
    }

    // MARK: Controlling

    func stop(_ session: LocalhostSession) {
        guard let pid = session.runnerPID else { return }
        queue.async {
            let table = Self.processTable()
            let targets = Self.descendants(of: pid, in: table)
            for target in targets { kill(target, SIGTERM) }
            // Anything that ignores SIGTERM gets killed after a grace period.
            self.queue.asyncAfter(deadline: .now() + 3) {
                let still = Self.descendants(of: pid, in: Self.processTable())
                for target in still where targets.contains(target) { kill(target, SIGKILL) }
            }
        }
    }

    @MainActor
    func restart(_ session: LocalhostSession) {
        guard let surface = surface(for: session) else { return }
        switch session.state {
        case .stopped:
            // The runner is waiting for a key.
            surface.surfaceModel?.sendText("r")
        case .detached:
            // The runner is gone and a shell is left; start it again in the same tab.
            if let model = surface.surfaceModel {
                ResumeAfterUpdate.run(" \(AgentTools.shellQuote(Self.runner)) \(session.id)", in: model)
            }
        case .starting, .live:
            FileManager.default.createFile(
                atPath: Self.directory.appendingPathComponent("\(session.id).restart").path, contents: nil)
            stop(session)
        }
    }

    /// Closes the session's tab, stopping the server.
    func close(_ session: LocalhostSession, confirm: Bool = true) {
        if confirm, session.isRunning {
            let alert = NSAlert()
            alert.messageText = "Stop \(session.project.name)'s server and close its tab?"
            alert.informativeText = session.command
            alert.addButton(withTitle: "Stop and close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        stop(session)
        let surface = surface(for: session)
        sessions.removeAll { $0.id == session.id }
        tabs.removeValue(forKey: session.id)
        quietPolls.removeValue(forKey: session.id)
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(session.id).status.json"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let surface { TerminalWindows.close(surface) }
            VerticalTabs.setNeedsRefresh()
        }
    }

    func stopAll(in project: LocalhostProject? = nil) {
        for session in sessions where session.isRunning && (project == nil || session.project == project) {
            stop(session)
        }
    }

    func focus(_ session: LocalhostSession) {
        guard let surface = surface(for: session) else { return }
        TerminalWindows.show(surface)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openInBrowser(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Stops a server running elsewhere and starts the same command in a session.
    func adopt(_ server: LocalhostOtherServer) {
        guard let cwd = server.cwd else { return }
        let command = server.rootCommand
        kill(server.rootPID, SIGTERM)
        // Give it a moment to free its port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.start(command: command, in: cwd, from: nil, focus: true)
        }
    }

    func stopOther(_ server: LocalhostOtherServer) {
        kill(server.rootPID, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.poll() }
    }

    private func update(_ id: String, _ change: (inout LocalhostSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[index]
        let before = session
        change(&session)
        guard session != before else { return }
        sessions[index] = session
        writeStatus(session)
        if before.state != .live, session.state == .live, before.liveSince == nil { announce(session) }
        if let surface = surface(for: session) {
            let port = session.url?.port.map { ":\($0)" } ?? ""
            TerminalWindows.setTitle("localhost\(port) · \(session.project.name)", of: surface)
        }
    }

    private func announce(_ session: LocalhostSession) {
        toast = session
        toastDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.toast?.id == session.id { self?.toast = nil }
        }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    /// What the `localhost` command waits on.
    private func writeStatus(_ session: LocalhostSession) {
        var status: [String: Any] = ["id": session.id, "ports": session.ports]
        switch session.state {
        case .starting: status["state"] = session.isQuiet ? "quiet" : "starting"
        case .live: status["state"] = "live"
        case .stopped(let code):
            status["state"] = "exited"
            status["code"] = code
        case .detached: status["state"] = "exited"
        }
        if let url = session.url { status["url"] = url.absoluteString }
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: Self.directory.appendingPathComponent("\(session.id).status.json"), options: .atomic)
        }
    }

    // MARK: Watching ports

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    struct ProcessInfoRow {
        let pid: Int32
        let ppid: Int32
        let cpu: Double
        let rssKB: Double
        let command: String
    }

    func poll() {
        // Drop sessions whose tab was closed some other way.
        let closed = sessions.filter { tabs[$0.id]?.value == nil }
        if !closed.isEmpty {
            for session in closed {
                stop(session)
                quietPolls.removeValue(forKey: session.id)
                try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(session.id).status.json"))
            }
            sessions.removeAll { session in closed.contains { $0.id == session.id } }
        }
        if sessions.isEmpty && !scanOthers {
            timer?.invalidate()
            timer = nil
            return
        }
        guard !polling else { return }
        polling = true
        let snapshot = sessions
        let scanOthers = self.scanOthers
        queue.async {
            let table = Self.processTable()
            let listening = Self.listeningPorts()
            var results: [String: (ports: [Int], cpu: Double, mem: Double)] = [:]
            var claimed: Set<Int32> = []
            for session in snapshot {
                guard let runner = session.runnerPID, session.isRunning else { continue }
                let family = Self.descendants(of: runner, in: table)
                claimed.formUnion(family)
                claimed.insert(runner)
                let ports = Set(family.flatMap { listening[$0] ?? [] }).sorted()
                let cpu = family.compactMap { table[$0]?.cpu }.reduce(0, +)
                let mem = family.compactMap { table[$0]?.rssKB }.reduce(0, +) / 1024
                results[session.id] = (ports, cpu, mem)
            }
            let others = scanOthers ? Self.otherServers(listening: listening, table: table, excluding: claimed) : []
            DispatchQueue.main.async {
                self.polling = false
                for (id, result) in results {
                    // A live server whose port stays closed for a few polls in a row (not just
                    // a dev server's quick reload) isn't live any more.
                    let main = self.sessions.first { $0.id == id }?.mainPort
                    let closed = main.map { !result.ports.contains($0) } ?? false
                    let quiet = closed ? (self.quietPolls[id] ?? 0) + 1 : 0
                    self.quietPolls[id] = quiet
                    self.update(id) { session in
                        session.ports = result.ports
                        session.cpu = result.cpu
                        session.memoryMB = result.mem
                        if session.state == .starting, let first = result.ports.first, !closed {
                            session.state = .live
                            session.mainPort = session.mainPort ?? first
                            session.liveSince = Date()
                        } else if quiet >= 3, session.state == .live {
                            session.state = .starting
                        }
                    }
                }
                if scanOthers, self.others != others { self.others = others }
            }
        }
    }

    static func processTable() -> [Int32: ProcessInfoRow] {
        let output = run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,command="])
        var table: [Int32: ProcessInfoRow] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            table[pid] = ProcessInfoRow(pid: pid, ppid: ppid, cpu: Double(parts[2]) ?? 0,
                                        rssKB: Double(parts[3]) ?? 0, command: String(parts[4]))
        }
        return table
    }

    static func descendants(of root: Int32, in table: [Int32: ProcessInfoRow]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for row in table.values { children[row.ppid, default: []].append(row.pid) }
        var result: Set<Int32> = []
        var stack = children[root] ?? []
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            stack.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    /// TCP ports each process is listening on (only this user's processes are visible).
    static func listeningPorts() -> [Int32: [Int]] {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        var result: [Int32: [Int]] = [:]
        var current: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = current,
                      let port = line.split(separator: ":").last.flatMap({ Int($0) }) {
                if !(result[pid]?.contains(port) ?? false) { result[pid, default: []].append(port) }
            }
        }
        return result
    }

    /// Runtimes whose listening processes are almost certainly dev servers.
    private static let devRuntimes: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "php", "java", "uvicorn", "gunicorn",
        "hugo", "jekyll", "rails", "puma", "beam.smp", "dotnet", "go", "air", "esbuild", "caddy",
    ]
    /// Parents that aren't part of the server (walking up stops at them).
    static let boundaries: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "sh", "login", "launchd", "tmux", "screen", "claude",
        "codex", "script", "ghostty", "sudo",
    ]

    private static func otherServers(listening: [Int32: [Int]], table: [Int32: ProcessInfoRow],
                                     excluding claimed: Set<Int32>) -> [LocalhostOtherServer] {
        let me = ProcessInfo.processInfo.processIdentifier
        func name(_ command: String) -> String {
            let first = command.split(separator: " ").first.map(String.init) ?? command
            return (first as NSString).lastPathComponent
        }
        var candidates: [(pid: Int32, ports: [Int], root: ProcessInfoRow)] = []
        for (pid, ports) in listening where !claimed.contains(pid) && pid != me {
            guard let row = table[pid] else { continue }
            let runtime = name(row.command).lowercased()
            guard devRuntimes.contains(runtime) || devRuntimes.contains(where: { runtime.hasPrefix($0) }) else { continue }
            // Walk up to the command the user (or agent) actually ran, e.g. `npm run dev`.
            var root = row
            while let parent = table[root.ppid], parent.pid > 1,
                  !boundaries.contains(name(parent.command).lowercased()) {
                root = parent
            }
            candidates.append((pid, ports.sorted(), root))
        }
        guard !candidates.isEmpty else { return [] }
        let cwds = workingDirectories(of: candidates.map(\.root.pid))
        return candidates.map { candidate in
            LocalhostOtherServer(
                pid: candidate.pid, rootPID: candidate.root.pid,
                rootCommand: prettyCommand(candidate.root.command),
                ports: candidate.ports, cwd: cwds[candidate.root.pid],
                name: name(table[candidate.pid]?.command ?? ""))
        }
        .sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
    }

    /// `node /Users/me/app/node_modules/.bin/vite --port 3000` -> `vite --port 3000`.
    static func prettyCommand(_ command: String) -> String {
        var words = command.split(separator: " ").map(String.init)
        if words.count > 1, ["node", "bun"].contains((words[0] as NSString).lastPathComponent),
           words[1].contains("/node_modules/.bin/") {
            words.removeFirst()
            words[0] = (words[0] as NSString).lastPathComponent
        } else if let first = words.first, first.hasPrefix("/") {
            let base = (first as NSString).lastPathComponent
            if ["npm", "pnpm", "yarn", "bun", "python", "python3", "ruby", "php", "node"].contains(base) { words[0] = base }
        }
        return words.joined(separator: " ")
    }

    private static func workingDirectories(of pids: [Int32]) -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", list])
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid = current { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

extension LocalhostSession {
    /// Exit codes from Ctrl-C and our own stop (SIGTERM) mean it was stopped, not crashed.
    private static func isCleanExit(_ code: Int32) -> Bool { [0, 130, 143].contains(code) }

    var statusLabel: String {
        switch state {
        case .starting: return isQuiet ? "Not listening" : "Starting"
        case .live: return "Live"
        case .stopped(let code): return Self.isCleanExit(code) ? "Stopped" : "Crashed · exit \(code)"
        case .detached: return "Stopped"
        }
    }

    var statusColor: Color {
        switch state {
        case .starting: return isQuiet ? Extreme.danger : Extreme.warn
        case .live: return Extreme.live
        case .stopped(let code): return Self.isCleanExit(code) ? Extreme.muted : Extreme.danger
        case .detached: return Extreme.muted
        }
    }
}
#endif
