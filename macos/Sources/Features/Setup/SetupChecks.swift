#if os(macOS)
import AppKit
import Combine
import UserNotifications

/// One line of the setup check: what was checked, how it stands, and how to fix it.
struct SetupCheck: Identifiable, Equatable {
    enum Status: Int, Comparable {
        case ok, info, warning, problem
        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Section: String, CaseIterable {
        case agentStatus = "Agent status"
        case tools = "Tools"
        case mac = "macOS"
    }

    let id: String
    let section: Section
    let title: String
    var status: Status
    var detail: String
    var fix: SetupFix?
    /// A quieter second choice beside the fix, like saying an agent isn't used.
    var alternative: SetupFix?
}

/// Something the setup check can fix with one click.
enum SetupFix: Equatable {
    case installHooks
    case connect(HookConfig.Agent)
    case connectMore(MoreAgent)
    /// The user doesn't use this agent: stop asking to connect it.
    case skip(HookConfig.Agent)
    case addShellIntegration
    case installJq
    case notifications
    /// Reinstall the hooks and repoint every agent at them.
    case repair
    /// Open a tab running `tellurion doctor`, which sends a test event.
    case liveTest

    var title: String {
        switch self {
        case .installHooks: return "Install hooks"
        case .connect(.claude): return "Connect Claude Code"
        case .connect(.codex): return "Connect Codex"
        case .connectMore(let agent): return "Connect \(agent.title)"
        case .skip(.claude): return "I don't use Claude Code"
        case .skip(.codex): return "I don't use Codex"
        case .addShellIntegration: return "Add to ~/.zshrc"
        case .installJq: return "Install jq"
        case .notifications: return "Allow notifications"
        case .repair: return "Repair"
        case .liveTest: return "Run live test"
        }
    }
}

/// Checks that agent status is set up and working, and fixes what isn't. Shared by the
/// Setup Check window, the welcome window, and the sidebar's warning chip.
final class SetupChecks: ObservableObject {
    static let shared = SetupChecks()
    static let windowID = "setup-check"

    @Published private(set) var checks: [SetupCheck] = []
    @Published private(set) var running = false
    @Published private(set) var lastRun: Date?
    /// Which tools are installed, for the welcome window.
    @Published private(set) var tools: [String: String] = [:]
    /// When a verified event from any agent last arrived (this launch). Not published:
    /// agents send many events, and every sidebar watches this object.
    private(set) var lastEventAt: Date?
    /// When `tellurion doctor`'s test event last arrived (this launch).
    @Published private(set) var liveCheckAt: Date?
    /// True for a few seconds after a live test passes, for the sidebar's confirmation.
    @Published private(set) var showLivePass = false
    /// The last fix that failed, shown under the list.
    @Published var fixError: String?

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.setup", qos: .utility)
    private var pendingRefresh = false
    private var completions: [() -> Void] = []

    private init() {}

    var problems: [SetupCheck] { checks.filter { $0.status == .problem } }
    var worst: SetupCheck.Status { checks.map(\.status).max() ?? .ok }

    /// Whether Claude Code or Codex is installed (or has been used here).
    var hasAgents: Bool { tools["claude"] != nil || tools["codex"] != nil }

    // MARK: Agents not used

    /// Agents the user said they don't use. A `~/.codex` folder can exist without Codex
    /// (an editor extension, one try long ago), and then "Codex isn't connected" would stay
    /// red with nothing to do about it. Skipped agents show as a quiet note instead.
    static let skippedKey = "ExtremeSkippedAgents"

    static var skipped: Set<HookConfig.Agent> {
        Set((UserDefaults.standard.stringArray(forKey: skippedKey) ?? []).compactMap(HookConfig.Agent.init(rawValue:)))
    }

    /// Remembers the choice, mirrors it for `tellurion doctor`, and checks again.
    func setSkipped(_ agent: HookConfig.Agent, _ skip: Bool) {
        var set = Self.skipped
        if skip { set.insert(agent) } else { set.remove(agent) }
        UserDefaults.standard.set(set.map(\.rawValue).sorted(), forKey: Self.skippedKey)
        Self.writeSkipFlags()
        refresh()
    }

    /// Mirrors the skipped agents into `~/.ghostty-extreme/features/<agent>-off`, which the
    /// doctor script reads. Called at launch and on every change.
    static func writeSkipFlags() {
        let folder = ExtremeSettings.flagsFolder
        let skipped = skipped
        for agent in [HookConfig.Agent.claude, .codex] {
            let flag = folder.appendingPathComponent(agent.rawValue + "-off")
            if skipped.contains(agent) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: flag.path, contents: Data())
            } else {
                try? FileManager.default.removeItem(at: flag)
            }
        }
    }

    // MARK: Events

    /// Called for every verified agent event, on the main thread.
    func eventArrived() {
        let first = lastEventAt == nil
        lastEventAt = Date()
        // Only the first one changes what's shown ("No agent has reported" → reporting).
        if first, let index = checks.firstIndex(where: { $0.id == "events" }) {
            checks[index] = Self.eventsCheck(lastEventAt: lastEventAt, liveCheckAt: liveCheckAt)
        }
    }

    /// The doctor's test event made it through the hook, the terminal and the app.
    func liveCheckArrived() {
        Self.testLog("live check arrived")
        liveCheckAt = Date()
        lastEventAt = Date()
        showLivePass = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.showLivePass = false }
        refresh()
    }

    // MARK: Running

    /// Runs every check off the main thread, then calls `then` on the main thread.
    func refresh(then: (() -> Void)? = nil) {
        if let then { completions.append(then) }
        guard !running else { pendingRefresh = true; return }
        running = true
        let lastEventAt = lastEventAt, liveCheckAt = liveCheckAt
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let notifications = settings.authorizationStatus
            self.queue.async {
                let tools = Self.findTools()
                let checks = Self.run(tools: tools, notifications: notifications,
                                      lastEventAt: lastEventAt, liveCheckAt: liveCheckAt)
                DispatchQueue.main.async {
                    self.tools = tools
                    self.checks = checks
                    Self.testLog("checks: " + checks.map { "\($0.id)=\($0.status)" }.joined(separator: " "))
                    self.lastRun = Date()
                    self.running = false
                    if self.pendingRefresh {
                        self.pendingRefresh = false
                        self.refresh()
                    } else {
                        let completions = self.completions
                        self.completions = []
                        completions.forEach { $0() }
                    }
                }
            }
        }
    }

    /// Runs the checks only if they haven't run for a while (app activation, window open).
    func refreshIfStale(_ age: TimeInterval = 300) {
        if lastRun.map({ Date().timeIntervalSince($0) > age }) ?? true { refresh() }
    }

    private static func run(tools: [String: String], notifications: UNAuthorizationStatus,
                            lastEventAt: Date?, liveCheckAt: Date?) -> [SetupCheck] {
        var checks: [SetupCheck] = []
        let home = HookInstaller.home
        let skipped = skipped
        // Found: installed, or its folder is there. Used: found and not skipped by the user.
        let foundClaude = tools["claude"] != nil || FileManager.default.fileExists(atPath: home + "/.claude")
        let foundCodex = tools["codex"] != nil || FileManager.default.fileExists(atPath: home + "/.codex")
        let usesClaude = foundClaude && !skipped.contains(.claude)
        let usesCodex = foundCodex && !skipped.contains(.codex)

        // The hook files.
        switch HookInstaller.filesState() {
        case .current:
            checks.append(.init(id: "hooks", section: .agentStatus, title: "Hooks installed", status: .ok,
                                detail: "In ~/.ghostty-extreme, with the localhost and ghostty-extreme commands"))
        case .missing:
            checks.append(.init(id: "hooks", section: .agentStatus, title: "Hooks aren't installed", status: .problem,
                                detail: "Agents report their status through small scripts in ~/.ghostty-extreme",
                                fix: .installHooks))
        case .outdated:
            checks.append(.init(id: "hooks", section: .agentStatus, title: "Hooks are out of date", status: .warning,
                                detail: "Installed by a different build of Tellurion", fix: .installHooks))
        case .unavailable:
            checks.append(.init(id: "hooks", section: .agentStatus, title: "Hooks not included in this build", status: .warning,
                                detail: "Run ./agent-hooks/install.sh from the repository"))
        }

        // Each agent's config.
        for (agent, found, name) in [(HookConfig.Agent.claude, foundClaude, "Claude Code"), (.codex, foundCodex, "Codex")] where found {
            let file = HookInstaller.display(HookInstaller.file(for: agent))
            if skipped.contains(agent) {
                let why = tools[agent.rawValue] == nil ? "The \(agent.rawValue) command isn't installed; only its folder is here" : "You said you don't use it"
                checks.append(.init(id: agent.rawValue, section: .agentStatus, title: "\(name) isn't connected", status: .info,
                                    detail: "\(why). Connect it if that changes", fix: .connect(agent)))
                continue
            }
            do {
                let report = HookConfig.report(try HookInstaller.readConfig(agent), agent: agent, home: home)
                if report.isComplete {
                    checks.append(.init(id: agent.rawValue, section: .agentStatus, title: "\(name) connected", status: .ok,
                                        detail: "All \(report.entries.count) hooks in \(file)"))
                } else {
                    var parts: [String] = []
                    if report.isEmpty {
                        parts.append("No Tellurion hooks in \(file) yet")
                    } else if !report.missing.isEmpty {
                        parts.append("Missing \(report.missing.joined(separator: ", "))")
                    }
                    if !report.elsewhere.isEmpty {
                        parts.append("\(report.elsewhere.joined(separator: ", ")) run from outside ~/.ghostty-extreme, which macOS can block")
                    }
                    if agent == .codex { parts.append("Codex asks you to approve new hooks once") }
                    // Only its folder, no command: it may well not be used here, so say so.
                    if tools[agent.rawValue] == nil { parts.append("The \(agent.rawValue) command isn't installed") }
                    checks.append(.init(id: agent.rawValue, section: .agentStatus,
                                        title: report.isEmpty ? "\(name) isn't connected" : "\(name) is partly connected",
                                        status: .problem, detail: parts.joined(separator: ". "), fix: .connect(agent),
                                        alternative: .skip(agent)))
                }
            } catch {
                checks.append(.init(id: agent.rawValue, section: .agentStatus, title: "\(name): can't read \(file)",
                                    status: .problem, detail: error.localizedDescription))
            }
        }

        // Other agents with hooks: optional, so never a problem, only an offer.
        for agent in MoreAgent.allCases where agent.isPresent(home: home, tools: tools) {
            let file = HookInstaller.display(agent.file(home: home))
            if HookInstaller.isConnected(agent) {
                checks.append(.init(id: "more-" + agent.rawValue, section: .agentStatus, title: "\(agent.title) connected",
                                    status: .ok, detail: "Reports \(agent.reports) · \(file)"))
            } else {
                checks.append(.init(id: "more-" + agent.rawValue, section: .agentStatus, title: "\(agent.title) can show live status",
                                    status: .info, detail: "Adds Tellurion's hooks to \(file). It reports \(agent.reports).",
                                    fix: .connectMore(agent)))
            }
        }

        // jq: the hooks report nothing without it.
        if tools["jq"] != nil {
            checks.append(.init(id: "jq", section: .agentStatus, title: "jq installed", status: .ok, detail: "The hooks use it to build events"))
        } else {
            checks.append(.init(id: "jq", section: .agentStatus, title: "jq isn't installed",
                                status: usesClaude || usesCodex ? .problem : .warning,
                                detail: "The hooks need it; without it agents report nothing", fix: .installJq))
        }
        if usesCodex, tools["python3"] == nil {
            checks.append(.init(id: "python3", section: .agentStatus, title: "python3 isn't installed", status: .problem,
                                detail: "Codex's hook adapter is a Python script. Install Xcode's command line tools"))
        }

        // Shell detection.
        if HookInstaller.zshIsLoginShell {
            if HookInstaller.shellIntegrationInstalled() {
                checks.append(.init(id: "shell", section: .agentStatus, title: "Shell integration", status: .ok,
                                    detail: "~/.zshrc shows an agent's logo as soon as it starts"))
            } else {
                checks.append(.init(id: "shell", section: .agentStatus, title: "Shell integration isn't set up", status: .warning,
                                    detail: "Adds one line to ~/.zshrc so an agent's logo shows the moment it starts",
                                    fix: .addShellIntegration))
            }
        } else {
            checks.append(.init(id: "shell", section: .agentStatus, title: "Shell integration needs zsh", status: .info,
                                detail: "Agent status still works; logos appear once the agent reports in"))
        }

        // Failures Claude Code recorded since the hooks were last installed.
        if usesClaude {
            let since = max(Date().addingTimeInterval(-86_400),
                            Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: HookInstaller.installedAtKey)))
            let errors = recentHookErrors(since: since)
            if errors.count > 0 {
                checks.append(.init(id: "errors", section: .agentStatus,
                                    title: "Claude Code reported \(errors.count) hook error\(errors.count == 1 ? "" : "s")",
                                    status: .problem, detail: errors.latest ?? "", fix: .repair))
            }
        }

        checks.append(eventsCheck(lastEventAt: lastEventAt, liveCheckAt: liveCheckAt))

        // Tools: what each one unlocks.
        let optional: [(String, String)] = [
            ("claude", "Claude Code"), ("codex", "Codex"), ("git", "Review, undo and races"),
            ("gh", "Pull request status (coming in the Git panel)"), ("docker", "Isolated sessions"), ("hermes", "Hermes sessions"),
            ("jj", "jj repositories in the Git panel and Undo"),
        ]
        for (tool, use) in optional {
            if let path = tools[tool] {
                checks.append(.init(id: "tool-" + tool, section: .tools, title: tool, status: .ok,
                                    detail: "\(use) · \(HookInstaller.display(URL(fileURLWithPath: path)))"))
            } else {
                checks.append(.init(id: "tool-" + tool, section: .tools, title: tool, status: .info, detail: "Not installed · \(use)"))
            }
        }

        // Notifications.
        switch notifications {
        case .authorized, .provisional, .ephemeral:
            checks.append(.init(id: "notifications", section: .mac, title: "Notifications allowed", status: .ok,
                                detail: "Alerts when an agent finishes or needs you"))
        case .denied:
            checks.append(.init(id: "notifications", section: .mac, title: "Notifications are turned off", status: .warning,
                                detail: "You won't hear when an agent finishes or needs permission", fix: .notifications))
        default:
            checks.append(.init(id: "notifications", section: .mac, title: "Notifications not set up yet", status: .warning,
                                detail: "Alerts when an agent finishes or needs you. macOS asks with a banner at the top right of the screen",
                                fix: .notifications))
        }
        return checks
    }

    /// Whether events are arriving.
    private static func eventsCheck(lastEventAt: Date?, liveCheckAt: Date?) -> SetupCheck {
        if let liveCheckAt {
            return .init(id: "events", section: .agentStatus, title: "Live test passed", status: .ok,
                         detail: "A test event went through the hooks and arrived \(ago(liveCheckAt))")
        } else if let lastEventAt {
            return .init(id: "events", section: .agentStatus, title: "Agents are reporting", status: .ok,
                         detail: "Last event \(ago(lastEventAt))", fix: .liveTest)
        }
        return .init(id: "events", section: .agentStatus, title: "No agent has reported since launch", status: .info,
                     detail: "Normal if none has run yet. A live test sends one through the real hooks", fix: .liveTest)
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    // MARK: Tools

    /// The tools on the user's PATH, as their login shell sees it (apps launched from the
    /// Dock get a much shorter PATH). Off the main thread only.
    private static func findTools() -> [String: String] {
        let names = ["claude", "codex", "jq", "git", "python3", "gh", "docker", "colima", "hermes", "brew", "jj"]
            + MoreAgent.allCases.flatMap(\.commands)
        var found: [String: String] = [:]
        let fm = FileManager.default
        for name in names {
            for folder in loginPath {
                let path = (folder as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { found[name] = path; break }
            }
        }
        // Colima stands in for Docker Desktop.
        if found["docker"] == nil, let colima = found["colima"] { found["docker"] = colima }
        // /usr/bin/git and python3 are stubs that ask to install the command line tools.
        for stub in ["git", "python3"] where found[stub] == "/usr/bin/\(stub)" {
            if !fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/\(stub)"),
               (try? runQuietly("/usr/bin/xcode-select", ["-p"])) == nil {
                found.removeValue(forKey: stub)
            }
        }
        return found
    }

    /// A tool on the login shell's PATH. Off the main thread only (the first call asks the shell).
    static func locate(_ tool: String) -> String? {
        loginPath.lazy.map { ($0 as NSString).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The login shell's PATH, found once.
    static let loginPath: [String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local", NSHomeDirectory() + "/.bun/bin",
                        NSHomeDirectory() + "/.npm-global/bin", NSHomeDirectory() + "/.cargo/bin"]
        // Interactive too, since many people set PATH in ~/.zshrc. Markers skip anything
        // their startup files print.
        guard let output = try? runQuietly(shell, ["-ilc", "printf '__GX__%s__GX__' \"$PATH\""], timeout: 5),
              let start = output.range(of: "__GX__"), let end = output.range(of: "__GX__", range: start.upperBound..<output.endIndex) else {
            return fallback
        }
        let path = output[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
        return path + fallback.filter { !path.contains($0) }
    }()

    private static func runQuietly(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: Hook errors

    /// Hook failures Claude Code recorded in transcripts written since `since` (for
    /// example "Operation not permitted" when the script lives in a protected folder).
    private static func recentHookErrors(since: Date) -> (count: Int, latest: String?) {
        let root = URL(fileURLWithPath: HookInstaller.home + "/.claude/projects", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return (0, nil) }
        var recent: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified > since {
                recent.append((url, modified))
            }
        }
        var count = 0
        var latest: (Date, String)?
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Newest transcripts first, and only their ends: errors that matter are recent.
        for (url, _) in recent.sorted(by: { $0.1 > $1.1 }).prefix(20) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            for line in text.split(separator: "\n") where line.contains("hook_non_blocking_error") && line.contains("agent-hook.sh") {
                // The record itself, not a message that mentions one (like a conversation about hooks).
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let attachment = record["attachment"] as? [String: Any],
                      attachment["type"] as? String == "hook_non_blocking_error",
                      (attachment["command"] as? String)?.contains("agent-hook.sh") == true else { continue }
                let date = (record["timestamp"] as? String).flatMap(formatter.date(from:)) ?? .distantPast
                guard date > since else { continue }
                count += 1
                let stderr = (attachment["stderr"] as? String ?? "")
                    .replacingOccurrences(of: "Failed with non-blocking status code: ", with: "")
                    .replacingOccurrences(of: HookInstaller.home, with: "~")
                if latest.map({ date > $0.0 }) ?? true { latest = (date, String(stderr.prefix(160))) }
            }
        }
        return (count, latest?.1)
    }

    /// Test-only: `GHOSTTY_EXTREME_TEST_LOG=<file>` collects what the checks found.
    private static func testLog(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_LOG"] else { return }
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Fixing

    /// Applies a fix, then checks again. Errors are kept in `fixError`.
    func apply(_ fix: SetupFix) {
        fixError = nil
        do {
            switch fix {
            case .installHooks:
                try HookInstaller.installFiles()
            case .connect(let agent):
                if HookInstaller.filesState() != .current { try HookInstaller.installFiles() }
                try HookInstaller.connect(agent)
                if Self.skipped.contains(agent) { setSkipped(agent, false) }
            case .connectMore(let agent):
                try HookInstaller.connect(agent)
            case .skip(let agent):
                setSkipped(agent, true)
            case .addShellIntegration:
                if HookInstaller.filesState() != .current { try HookInstaller.installFiles() }
                try HookInstaller.addShellIntegration()
            case .installJq:
                if let brew = tools["brew"] {
                    Self.openTab(running: "\(AgentTools.shellQuote(brew)) install jq")
                } else if let url = URL(string: "https://jqlang.org/download/") {
                    NSWorkspace.shared.open(url)
                }
            case .notifications:
                requestNotifications()
            case .repair:
                try HookInstaller.installFiles()
                for agent in [HookConfig.Agent.claude, .codex]
                where checks.contains(where: { $0.id == agent.rawValue && $0.status != .info }) {
                    try HookInstaller.connect(agent)
                }
            case .liveTest:
                if HookInstaller.filesState() != .current { try HookInstaller.installFiles() }
                Self.openTab(running: "~/.ghostty-extreme/bin/tellurion doctor")
            }
        } catch {
            fixError = error.localizedDescription
        }
        refresh()
    }

    private func requestNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard settings.authorizationStatus == .notDetermined else {
                    // Already decided (usually "off"): only System Settings can change it now.
                    self.openNotificationSettings()
                    return
                }
                // macOS asks with a banner at the top right of the screen. Focus modes can hide
                // it, and then nothing would seem to happen; so if it doesn't end with
                // notifications on, say so and open System Settings instead.
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    center.getNotificationSettings { after in
                        DispatchQueue.main.async {
                            if !granted || after.authorizationStatus != .authorized {
                                // System Settings lists apps by their name on disk ("Tellurion").
                                let name = FileManager.default.displayName(atPath: Bundle.main.bundlePath)
                                    .replacingOccurrences(of: ".app", with: "")
                                self.fixError = "Notifications aren't on yet. In System Settings → Notifications, choose "
                                    + "\(name) and turn on Allow Notifications."
                                self.openNotificationSettings()
                            }
                            self.refresh()
                        }
                    }
                }
            }
        }
    }

    private func openNotificationSettings() {
        guard let id = Bundle.main.bundleIdentifier,
              let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens a new tab (or window, or a tile on a board) that runs `command` in the user's shell.
    static func openTab(running command: String) {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.initialInput = command + "\n"
        TerminalWindows.newTerminal(ghostty, from: TerminalWindows.front, config: config)
    }
}
#endif
