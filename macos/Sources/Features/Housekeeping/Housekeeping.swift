#if os(macOS)
import AppKit
import Combine
import Foundation

/// Everything left running in the background: dev servers, VMs and containers, agent
/// sessions, browser automation, databases, watchers, log followers and login services.
/// Each gets a "last used" time from real signals and a staleness rating, so old work can
/// be found and closed.
///
/// "Last used" comes from what shows use, not just from being alive:
/// - a terminal's last keystroke and last output (the tty device's access/modify times);
/// - an agent's transcript being written;
/// - connections to a server's listening port;
/// - containers inside a VM, and their CPU;
/// - bursts of CPU, remembered between scans (and across launches) in a small history.
final class Housekeeping: ObservableObject {
    static let shared = Housekeeping()
    static let windowID = "housekeeping"

    enum Kind: String, CaseIterable {
        case vm, container, devServer, agent, browser, database, watcher, logs, service, heavy

        var title: String {
            switch self {
            case .vm: return "Virtual machines"
            case .container: return "Containers"
            case .devServer: return "Dev servers"
            case .agent: return "Agent sessions"
            case .browser: return "Browser automation"
            case .database: return "Databases"
            case .watcher: return "Watchers"
            case .logs: return "Log followers"
            case .service: return "Login services"
            case .heavy: return "Other heavy processes"
            }
        }

        var symbol: String {
            switch self {
            case .vm: return "cube.transparent"
            case .container: return "shippingbox"
            case .devServer: return "server.rack"
            case .agent: return "sparkles"
            case .browser: return "safari"
            case .database: return "cylinder.split.1x2"
            case .watcher: return "eye"
            case .logs: return "text.alignleft"
            case .service: return "power"
            case .heavy: return "gauge.with.dots.needle.67percent"
            }
        }
    }

    enum Rating: Int, Comparable {
        case active, idle, stale, close
        static func < (a: Rating, b: Rating) -> Bool { a.rawValue < b.rawValue }

        init(score: Int) {
            self = score >= 80 ? .close : score >= 60 ? .stale : score >= 30 ? .idle : .active
        }

        var label: String {
            switch self {
            case .active: return "Active"
            case .idle: return "Idle"
            case .stale: return "Stale"
            case .close: return "Ready to close"
            }
        }
    }

    enum CloseAction: Equatable {
        case terminate([Int32])
        case colimaStop(String)
        case dockerStop(context: String, id: String)
        case launchdStop(String)
        case none
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let kind: Kind
        var title: String
        var detail: String
        var command: String
        var folder: String?
        var pids: [Int32] = []
        var started: Date?
        var memory: Int64 = 0
        /// Memory it reserves rather than uses right now (a VM's allocation).
        var reserved: Int64 = 0
        var cpu: Double = 0
        var ports: [Int] = []
        var lastActive: Date?
        var activeSource = ""
        var inTerminal = false
        var orphaned = false
        var score = 0
        var reasons: [String] = []
        var close: CloseAction = .none

        var rating: Rating { Rating(score: score) }
        var project: String? { folder.map { ($0 as NSString).lastPathComponent } }
        var idle: TimeInterval { Date().timeIntervalSince(lastActive ?? started ?? Date()) }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var scannedAt: Date?
    @Published private(set) var scanning = false
    /// This app's own CPU and memory, so a runaway terminal shows up too.
    @Published private(set) var selfUsage: (cpu: Double, memory: Int64) = (0, 0)

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.housekeeping", qos: .utility)
    private var history: [String: Seen] = [:]
    /// Test-only: sample items closed this run (see `refresh`).
    private var closedSamples: Set<String> = []
    private static var showsSample: Bool { TestHooks.showsBackgroundSample }
    private var timer: Timer?
    private var fastTimer: Timer?
    private var watchers = 0

    /// What the history remembers about an item between scans.
    private struct Seen: Codable {
        var cpuTime: Double
        var lastActive: Double?
        var firstSeen: Double
        var idleSince: Double?
    }

    private static var historyURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ghostty-extreme/background-activity.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([String: Seen].self, from: data) {
            history = saved
        }
        // A light scan every five minutes keeps "last used" honest while nobody's looking.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.refresh() }
    }

    /// Scans every few seconds while a view is showing.
    func watch(_ on: Bool) {
        watchers += on ? 1 : -1
        fastTimer?.invalidate()
        fastTimer = nil
        if watchers > 0 {
            refresh()
            fastTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        }
    }

    var reclaimable: Int64 {
        items.filter { $0.rating >= .stale }.reduce(0) { $0 + max($1.memory, $1.reserved) }
    }

    var staleCount: Int { items.filter { $0.rating >= .stale }.count }

    // MARK: Scanning

    func refresh() {
        // Test-only: representative sample data, for screenshots that shouldn't show this Mac.
        if Self.showsSample {
            items = Self.sample().filter { !closedSamples.contains($0.id) }
            scannedAt = Date()
            selfUsage = (1.2, 162_000_000)
            return
        }
        guard !scanning else { return }
        scanning = true
        queue.async { [self] in
            let (found, usage) = scan()
            if let log = TestHooks.log {
                let lines = found.map { "\($0.kind.rawValue)\t\($0.score)\t\($0.rating.label)\t\($0.title)\t\($0.detail)\t\(Self.bytes(max($0.memory, $0.reserved)))\t\($0.reasons.joined(separator: "; "))" }
                try? (lines.joined(separator: "\n") + "\n---\n").write(toFile: log, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async {
                self.items = found
                self.selfUsage = usage
                self.scannedAt = Date()
                self.scanning = false
            }
        }
    }

    private struct Proc {
        let pid: Int32
        let ppid: Int32
        let elapsed: TimeInterval
        let cpuTime: Double
        let rss: Int64
        let cpu: Double
        let tty: String
        let command: String
    }

    private func scan() -> ([Item], (Double, Int64)) {
        let me = getuid()
        let procs = Self.processes(uid: me)
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid) }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let usage = byPid[ownPid].map { ($0.cpu, $0.rss) } ?? (0, 0)

        // Which processes run inside this app's terminals (descendants of this app).
        var inApp = Set<Int32>()
        var stack = children[ownPid] ?? []
        while let pid = stack.popLast() {
            guard inApp.insert(pid).inserted else { continue }
            stack += children[pid] ?? []
        }

        // Login services (launchd jobs that aren't Apple's).
        let services = Self.launchdServices()

        // Classify, then fold each matched process's children into it.
        var matched: [Int32: Kind] = [:]
        let home = NSHomeDirectory()
        for p in procs where p.pid != ownPid {
            // Started by an app (the Codex app's server, an editor's helpers): that app manages it.
            if let parent = byPid[p.ppid], parent.pid != ownPid, parent.command.contains(".app/Contents/") { continue }
            if let kind = Self.classify(p.command) { matched[p.pid] = kind }
            // A login service is a login service, whatever it runs (a dashboard's dev server included).
            if services[p.pid] != nil { matched[p.pid] = .service }
            // Anything else of yours holding a lot: tools from Homebrew, your home folder, or a
            // language runtime, never the system's own processes or apps you can quit yourself.
            let exe = p.command.split(separator: " ").first.map(String.init) ?? ""
            let yours = exe.hasPrefix(home) || exe.hasPrefix("/opt/homebrew/") || exe.hasPrefix("/usr/local/")
                || ["node", "python", "python3", "ruby", "java", "deno", "bun", "php", "go"].contains((exe as NSString).lastPathComponent)
            if matched[p.pid] == nil, yours, !p.command.contains(".app/Contents/"), p.rss > 1_500_000_000 || p.cpu > 40 {
                matched[p.pid] = .heavy
            }
        }
        // Roots: matched processes whose parent isn't matched as the same kind.
        func underService(_ pid: Int32) -> Bool {
            var p = byPid[pid]?.ppid ?? 1
            while p > 1, let proc = byPid[p] {
                if matched[p] == .service { return true }
                p = proc.ppid
            }
            return false
        }
        let roots = matched.filter { pid, kind in
            if kind != .service && underService(pid) { return false }
            guard let parent = byPid[pid]?.ppid, let parentKind = matched[parent] else { return true }
            return parentKind != kind
        }
        func tree(_ pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var todo = [pid]
            while let p = todo.popLast() {
                out.append(p)
                todo += (children[p] ?? []).filter { matched[$0] == nil || matched[$0] == matched[pid] || matched[pid] == .service }
            }
            return out
        }

        let ports = Self.listeningPorts()
        let connected = Self.connectedPorts()
        let cwds = Self.workingDirectories(Array(roots.keys))
        let now = Date()
        var items: [Item] = []

        for (pid, kind) in roots {
            guard let root = byPid[pid] else { continue }
            let pids = tree(pid)
            let group = pids.compactMap { byPid[$0] }
            // A process that's always around (the VM's helpers) is described by its VM entry.
            if kind == .vm { continue }
            var item = Item(id: "pid:\(pid):\(root.command.prefix(80))", kind: kind,
                            title: Self.title(for: root.command, kind: kind), detail: "", command: root.command)
            item.pids = pids
            item.folder = cwds[pid].flatMap { $0 == "/" || $0 == NSHomeDirectory() ? nil : $0 }
            item.started = now.addingTimeInterval(-root.elapsed)
            item.memory = group.reduce(0) { $0 + $1.rss }
            item.cpu = group.reduce(0) { $0 + $1.cpu }
            item.ports = Array(Set(pids.flatMap { ports[$0] ?? [] })).sorted()
            item.inTerminal = inApp.contains(pid)
            item.orphaned = root.ppid == 1 && kind != .service
            if let label = services[pid] { item.title = label; item.close = .launchdStop(label) } else { item.close = .terminate(pids) }

            // Signals of use.
            var signals: [(Date, String)] = []
            if root.tty != "??", let tty = Self.ttyTimes(root.tty) {
                signals.append((tty.input, "typed in its terminal"))
                signals.append((tty.output, "printed to its terminal"))
            }
            if item.ports.contains(where: { connected.contains($0) }) { signals.append((now, "has a live connection")) }
            if kind == .agent, let folder = cwds[pid], let written = Self.transcriptActivity(folder: folder, command: root.command) {
                signals.append((written, "agent transcript updated"))
            }
            let cpuTime = group.reduce(0) { $0 + $1.cpuTime }
            track(&item, cpuTime: cpuTime, signals: signals, now: now, burst: kind == .devServer || kind == .watcher ? 3 : 1.5)
            item.detail = Self.describe(item)
            items.append(item)
        }

        items += vmsAndContainers(now: now, connected: connected)
        for index in items.indices { rate(&items[index], now: now) }
        save()
        return (items.sorted { ($0.rating, $0.score, $0.memory) > ($1.rating, $1.score, $1.memory) }, usage)
    }

    /// Updates an item's "last used" from fresh signals and remembered CPU bursts.
    private func track(_ item: inout Item, cpuTime: Double, signals: [(Date, String)], now: Date, burst: Double) {
        var seen = history[item.id] ?? Seen(cpuTime: cpuTime, lastActive: nil, firstSeen: now.timeIntervalSince1970)
        // A real burst of work since the last scan (not just a server's idle polling).
        let elapsed = max(60, now.timeIntervalSince1970 - (scannedAt?.timeIntervalSince1970 ?? now.timeIntervalSince1970 - 300))
        if cpuTime - seen.cpuTime > burst * elapsed / 60 { seen.lastActive = now.timeIntervalSince1970 }
        seen.cpuTime = cpuTime
        var best: (Date, String)? = seen.lastActive.map { (Date(timeIntervalSince1970: $0), "used CPU") }
        for signal in signals where signal.0 > (best?.0 ?? .distantPast) { best = signal }
        if let best { seen.lastActive = max(seen.lastActive ?? 0, best.0.timeIntervalSince1970) }
        history[item.id] = seen
        item.lastActive = best?.0
        item.activeSource = best?.1 ?? ""
        if item.lastActive == nil, let first = Optional(Date(timeIntervalSince1970: seen.firstSeen)),
           now.timeIntervalSince(first) > 600 {
            // Watched for a while without any sign of use: idle at least that long.
            item.lastActive = max(first, item.started ?? first)
            item.activeSource = "no activity seen"
        }
    }

    // MARK: Staleness

    private func rate(_ item: inout Item, now: Date) {
        let idle = item.idle
        var score: Double
        switch idle {
        case ..<900: score = 0
        case ..<3600: score = 15 + (idle - 900) / 2700 * 15
        case ..<21600: score = 30 + (idle - 3600) / 18000 * 20
        case ..<86400: score = 50 + (idle - 21600) / 64800 * 15
        case ..<259200: score = 65 + (idle - 86400) / 172800 * 15
        default: score = min(95, 80 + (idle - 259200) / 604800 * 15)
        }
        var reasons: [String] = []
        if idle >= 3600 {
            if item.lastActive == nil {
                reasons.append("No sign of use since it started, \(Self.ago(idle))")
            } else if item.activeSource == "no activity seen" {
                reasons.append("No sign of use for \(Self.span(idle))")
            } else {
                reasons.append("Last \(item.activeSource) \(Self.ago(idle))")
            }
        }
        if item.orphaned && !item.inTerminal && item.kind != .vm && item.kind != .container {
            score += 15
            reasons.append("Its terminal is gone, so nothing will stop it")
        }
        if item.kind == .vm, item.reasons.contains(where: { $0.hasPrefix("No containers") }) { score += 20 }
        if item.kind == .logs, idle > 3600 { score += 10; reasons.append("Following logs nobody's reading") }
        // Busy right now, or something is connected: not stale, whatever the clock says.
        if item.cpu > 5 { score = min(score, 20); reasons.append("Working right now (\(Int(item.cpu))% CPU)") }
        if item.activeSource == "has a live connection" { score = min(score, 15) }
        // Login services start again at login; never "ready to close" by age alone.
        if item.kind == .service { score = min(score, 55); reasons.append("Starts again at login") }
        // An agent waiting in an open tab is still yours.
        if item.kind == .agent && item.inTerminal { score = min(score, 45) }
        if max(item.memory, item.reserved) > 1_000_000_000 && score >= 50 {
            reasons.append("Holding \(Self.bytes(max(item.memory, item.reserved)))")
        }
        item.score = Int(max(0, min(100, score)))
        item.reasons = item.reasons.filter { !$0.isEmpty } + reasons
    }

    // MARK: VMs and containers

    private func vmsAndContainers(now: Date, connected: Set<Int>) -> [Item] {
        guard let colima = Self.which("colima") else { return [] }
        let list = Self.run(colima, ["list", "--json"], timeout: 8)
        var items: [Item] = []
        for line in list.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let vm = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profile = vm["name"] as? String, (vm["status"] as? String) == "Running" else { continue }
            let context = profile == "default" ? "colima" : "colima-\(profile)"
            var item = Item(id: "colima:\(profile)", kind: .vm, title: "Colima VM “\(profile)”", detail: "",
                            command: "colima start\(profile == "default" ? "" : " -p \(profile)")")
            item.reserved = vm["memory"] as? Int64 ?? Int64(vm["memory"] as? Int ?? 0)
            let cpus = vm["cpus"] as? Int ?? 0
            // Its age: the VM's host agent process.
            let agents = Self.run("/bin/ps", ["-axo", "pid=,etime=,command="], timeout: 4).split(separator: "\n")
                .filter { $0.contains("limactl hostagent") && $0.contains("/colima\(profile == "default" ? "" : "-\(profile)")/") }
            if let first = agents.first {
                let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count >= 2 { item.started = now.addingTimeInterval(-Self.duration(String(parts[1]))) }
                if let pid = Int32(parts.first ?? "") { item.pids = [pid] }
            }
            item.close = .colimaStop(profile)
            // Its containers, each its own item, and whether any is doing work.
            var containers: [Item] = []
            if let docker = Self.which("docker") {
                let ps = Self.run(docker, ["--context", context, "ps", "--format", "{{.ID}}|{{.Names}}|{{.Image}}|{{.RunningFor}}|{{.Ports}}"], timeout: 8)
                let stats = Self.run(docker, ["--context", context, "stats", "--no-stream", "--format", "{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}"], timeout: 12)
                var cpuByID: [String: (Double, Int64)] = [:]
                for row in stats.split(separator: "\n") {
                    let f = row.split(separator: "|").map(String.init)
                    guard f.count == 3 else { continue }
                    let cpu = Double(f[1].replacingOccurrences(of: "%", with: "")) ?? 0
                    cpuByID[String(f[0].prefix(12))] = (cpu, Self.parseBytes(f[2].components(separatedBy: " / ").first ?? ""))
                }
                for row in ps.split(separator: "\n") {
                    let f = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 4 else { continue }
                    var c = Item(id: "container:\(f[0])", kind: .container, title: f[1], detail: "", command: f[2])
                    c.started = now.addingTimeInterval(-Self.dockerAge(f[3]))
                    c.cpu = cpuByID[String(f[0].prefix(12))]?.0 ?? 0
                    c.memory = cpuByID[String(f[0].prefix(12))]?.1 ?? 0
                    c.close = .dockerStop(context: context, id: f[0])
                    c.reasons = ["In Colima VM “\(profile)”"]
                    // Host ports it publishes ("127.0.0.1:54330->5432/tcp"): in use while something is connected.
                    let published = f.count > 4 ? f[4].components(separatedBy: ", ").compactMap { entry -> Int? in
                        guard let host = entry.components(separatedBy: "->").first, entry.contains("->") else { return nil }
                        return Int(host.split(separator: ":").last ?? "")
                    } : []
                    c.ports = published
                    var signals: [(Date, String)] = []
                    if c.cpu > 1 { signals.append((now, "container busy")) }
                    if published.contains(where: connected.contains) { signals.append((now, "has a live connection")) }
                    track(&c, cpuTime: 0, signals: signals, now: now, burst: .infinity)
                    c.detail = "\(f[2])\(f.count > 4 && !f[4].isEmpty ? " · \(f[4])" : "")"
                    containers.append(c)
                }
            }
            // The VM is used when its containers are.
            var seen = history[item.id] ?? Seen(cpuTime: 0, lastActive: nil, firstSeen: now.timeIntervalSince1970)
            if containers.isEmpty {
                if seen.idleSince == nil { seen.idleSince = now.timeIntervalSince1970 }
                item.reasons = ["No containers running\(seen.idleSince.map { " (for at least \(Self.span(now.timeIntervalSince1970 - $0)))" } ?? "")"]
                item.lastActive = Date(timeIntervalSince1970: seen.lastActive ?? seen.idleSince ?? now.timeIntervalSince1970)
                item.activeSource = seen.lastActive == nil ? "no activity seen" : "had a busy container"
                if seen.lastActive == nil, let started = item.started { item.lastActive = started; item.activeSource = "started" }
            } else {
                seen.idleSince = nil
                let busy = containers.compactMap(\.lastActive).max()
                if let busy { seen.lastActive = busy.timeIntervalSince1970 }
                item.lastActive = busy ?? containers.compactMap(\.started).max()
                item.activeSource = busy != nil ? "had a busy container" : "started a container"
            }
            history[item.id] = seen
            item.detail = "\(cpus) CPUs · \(Self.bytes(item.reserved)) memory reserved · \(containers.count) container\(containers.count == 1 ? "" : "s")"
            if profile == "default" && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.ghostty-extreme/colima-started") {
                item.reasons.append("Started by a Tellurion Docker session")
            }
            items.append(item)
            items += containers
        }
        return items
    }

    /// Test-only sample data (see `refresh`).
    private static func sample() -> [Item] {
        let now = Date()
        func item(_ id: String, _ kind: Kind, _ title: String, _ detail: String, _ command: String, folder: String?,
                  memory: Int64, reserved: Int64 = 0, cpu: Double = 0, up: TimeInterval, idle: TimeInterval, source: String,
                  ports: [Int] = [], terminal: Bool = false, orphaned: Bool = false, close: CloseAction = .terminate([1])) -> Item {
            var i = Item(id: id, kind: kind, title: title, detail: detail, command: command)
            i.folder = folder; i.memory = memory; i.reserved = reserved; i.cpu = cpu; i.ports = ports
            i.started = now.addingTimeInterval(-up); i.lastActive = now.addingTimeInterval(-idle); i.activeSource = source
            i.inTerminal = terminal; i.orphaned = orphaned; i.close = close
            return i
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/Demo/"
        var items = [
            item("vm", .vm, "Colima VM “default”", "4 CPUs · 6.0 GB memory reserved · 0 containers", "colima start", folder: nil,
                 memory: 0, reserved: 6_442_450_944, up: 5 * 86400 + 11 * 3600, idle: 4 * 86400, source: "had a busy container",
                 close: .colimaStop("default")),
            item("pw", .browser, "Playwright browser", "atlas-api", "node ~/.cache/ms-playwright/mcp-chrome --headed", folder: home + "atlas-api",
                 memory: 581_000_000, up: 2 * 86400, idle: 2 * 86400, source: "used CPU", orphaned: true),
            item("logs", .logs, "docker logs -f", "atlas-api", "docker logs -f atlas-db", folder: home + "atlas-api",
                 memory: 24_000_000, up: 2 * 86400, idle: 2 * 86400, source: "printed to its terminal", orphaned: true),
            item("pg", .container, "atlas-db", "postgres:17 · 127.0.0.1:54330->5432/tcp", "postgres:17", folder: nil,
                 memory: 294_000_000, up: 13 * 86400, idle: 9 * 86400, source: "container busy", close: .dockerStop(context: "colima", id: "a1b2")),
            item("docs", .devServer, "Astro dev server", "pixel-docs · :4321", "astro dev --port 4321", folder: home + "pixel-docs",
                 memory: 212_000_000, up: 26 * 3600, idle: 19 * 3600, source: "has a live connection", ports: [4321]),
            item("codex", .agent, "Codex", "atlas-api", "codex", folder: home + "atlas-api",
                 memory: 184_000_000, up: 3 * 3600, idle: 2 * 3600 + 900, source: "typed in its terminal", terminal: true),
            item("next", .devServer, "Next.js dev server", "acme-shop · :3000 · in a Tellurion tab", "next dev", folder: home + "acme-shop",
                 memory: 1_400_000_000, cpu: 3, up: 4 * 3600, idle: 60, source: "has a live connection", ports: [3000], terminal: true),
            item("claude", .agent, "Claude Code", "acme-shop · in a Tellurion tab", "claude", folder: home + "acme-shop",
                 memory: 512_000_000, cpu: 9, up: 3 * 3600, idle: 5, source: "agent transcript updated", terminal: true),
            item("svc", .service, "dev.acme.preview-tunnel", "", "cloudflared tunnel run acme-preview", folder: nil,
                 memory: 41_000_000, up: 6 * 86400, idle: 6 * 86400, source: "", close: .launchdStop("dev.acme.preview-tunnel")),
        ]
        for index in items.indices {
            if items[index].kind == .vm { items[index].reasons = ["No containers running (for at least 4d 0h)"] }
            if items[index].kind == .container { items[index].reasons = ["In Colima VM “default”"] }
            shared.rate(&items[index], now: now)
        }
        return items.sorted { ($0.rating, $0.score, $0.memory) > ($1.rating, $1.score, $1.memory) }
    }

    // MARK: Closing

    /// Closes an item the polite way (SIGTERM, `colima stop`, `docker stop`), on a background queue.
    func close(_ item: Item, force: Bool = false, done: (() -> Void)? = nil) {
        // Sample items aren't this Mac's: closing one only takes it off the list.
        if Self.showsSample {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.closedSamples.insert(item.id)
                self.refresh()
                done?()
            }
            return
        }
        queue.async { [self] in
            switch item.close {
            case .terminate(let pids):
                // Children first, so a dev server's workers don't outlive it.
                for pid in pids.reversed() where pid > 1 && pid != ProcessInfo.processInfo.processIdentifier {
                    kill(pid, force ? SIGKILL : SIGTERM)
                }
            case .colimaStop(let profile):
                if let colima = Self.which("colima") { _ = Self.run(colima, ["stop", "-p", profile], timeout: 120) }
                if profile == "default" { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.ghostty-extreme/colima-started") }
            case .dockerStop(let context, let id):
                if let docker = Self.which("docker") { _ = Self.run(docker, ["--context", context, "stop", id], timeout: 60) }
            case .launchdStop(let label):
                _ = Self.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
            case .none:
                break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.refresh()
                done?()
            }
        }
    }

    private func save() {
        // Forget items not seen for a week.
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        history = history.filter { ($0.value.lastActive ?? $0.value.firstSeen) > cutoff || $0.key.hasPrefix("colima:") }
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
    }
}

// MARK: - Reading the system

extension Housekeeping {
    private static func processes(uid: uid_t) -> [Proc] {
        let output = run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,etime=,time=,rss=,%cpu=,tty=,command="], timeout: 6)
        var procs: [Proc] = []
        for line in output.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 9, let pid = Int32(f[0]), let ppid = Int32(f[1]), UInt32(f[2]) == uid else { continue }
            procs.append(Proc(pid: pid, ppid: ppid, elapsed: duration(f[3]), cpuTime: duration(f[4]),
                              rss: (Int64(f[5]) ?? 0) * 1024, cpu: Double(f[6]) ?? 0, tty: f[7], command: f[8]))
        }
        return procs
    }

    /// What a command is, or nil for ordinary processes.
    fileprivate static func classify(_ command: String) -> Kind? {
        let c = command.lowercased()
        let exe = (c.split(separator: " ").first.map(String.init) ?? "")
        let name = (exe as NSString).lastPathComponent
        func has(_ needles: String...) -> Bool { needles.contains { c.contains($0) } }
        // Never this app, Apple's processes, or ordinary GUI apps.
        if exe.hasPrefix("/system/") || exe.hasPrefix("/usr/libexec/") || exe.hasPrefix("/usr/sbin/") { return nil }
        if has("ghosttyextreme.app/", "ghostty.app/contents/macos/ghostty") { return nil }
        if has("limactl hostagent", "limactl usernet", "/_lima/") { return .vm }
        if has("playwright", "puppeteer", "chrome-headless", "--headless", "--remote-debugging-port", "chromedriver", "geckodriver",
               "ms-playwright") { return .browser }
        if exe.contains(".app/contents/") { return nil }
        if has("tail -f", "logs -f", "logs --follow", "wrangler tail", "vercel logs", "kubectl logs") { return .logs }
        if has("app-server daemon", " daemon pid-update", "--daemon") { return .service }
        if name == "claude" || has("@anthropic-ai/claude-code", "/claude-code/cli", ".local/bin/claude") { return .agent }
        if name == "codex" || has("/codex app-server", "codex-cli", "@openai/codex") || ["aider", "gemini", "opencode", "goose", "hermes", "agy", "copilot", "droid", "kiro-cli", "cursor-agent", "amp",
                       "crush", "qwen", "kimi", "vibe"].contains(name) {
            return .agent
        }
        if ["mysqld", "postgres", "redis-server", "mongod", "memcached", "clickhouse", "minio", "mariadbd"].contains(name)
            || has("elasticsearch") { return .database }
        if has("--watch", " watch ", "nodemon", "cargo watch", "chokidar") && !has(" dev") { return .watcher }
        if has("next dev", "next-server", "vite", "webpack serve", "webpack-dev-server", "wrangler dev", "workerd serve", "astro dev",
               "remix dev", "nuxt dev", "react-scripts start", "npm run dev", "npm run start", "pnpm dev", "pnpm run dev", "yarn dev",
               "bun dev", "bun run dev", "functions serve", "supabase start", "http.server", "uvicorn", "flask run", "rails s",
               "rails server", "artisan serve", "hugo server", "jekyll serve", "localhost-run", "expo start", "storybook",
               "firebase emulators", "vercel dev", "netlify dev", "deno task dev", "turbo dev", "turbo run dev") { return .devServer }
        return nil
    }

    fileprivate static func title(for command: String, kind: Kind) -> String {
        let c = command.lowercased()
        let pairs: [(String, String)] = [
            ("next dev", "Next.js dev server"), ("next-server", "Next.js server"), ("wrangler dev", "Wrangler dev (Workers)"),
            ("workerd", "Workers runtime (workerd)"), ("vite", "Vite dev server"), ("astro dev", "Astro dev server"),
            ("functions serve", "Supabase functions serve"), ("supabase start", "Supabase local stack"), ("uvicorn", "Uvicorn (Python)"),
            ("http.server", "Python http.server"), ("flask run", "Flask dev server"), ("expo start", "Expo"), ("storybook", "Storybook"),
            ("vercel dev", "Vercel dev"), ("localhost-run", "Localhost session"), ("codex app-server", "Codex app server"),
            ("playwright", "Playwright browser"), ("chrome-headless", "Headless Chrome"), ("--headless", "Headless Chrome"),
            ("docker logs", "docker logs -f"), ("wrangler tail", "wrangler tail"), ("tail -f", "tail -f"), ("mysqld", "MySQL"),
            ("postgres", "PostgreSQL"), ("redis-server", "Redis"), ("mongod", "MongoDB"),
        ]
        if c.contains("codex app-server") { return "Codex app server (daemon)" }
        if kind == .agent {
            if c.contains("codex") { return "Codex" }
            if c.contains("claude") { return "Claude Code" }
        }
        if let match = pairs.first(where: { c.contains($0.0) }) { return match.1 }
        let exe = command.split(separator: " ").first.map(String.init) ?? command
        return (exe as NSString).lastPathComponent
    }

    fileprivate static func describe(_ item: Item) -> String {
        var parts: [String] = []
        if let project = item.project { parts.append(project) }
        if !item.ports.isEmpty { parts.append(item.ports.prefix(3).map { ":\($0)" }.joined(separator: " ")) }
        if item.inTerminal { parts.append("in a Tellurion tab") }
        return parts.joined(separator: " · ")
    }

    /// pid -> TCP ports it listens on.
    private static func listeningPorts() -> [Int32: [Int]] {
        guard let lsof = which("lsof") else { return [:] }
        let out = run(lsof, ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], timeout: 6)
        var result: [Int32: [Int]] = [:]
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n"), let port = Int(line.split(separator: ":").last ?? "") { result[pid, default: []].append(port) }
        }
        return result
    }

    /// Local ports with an open connection right now (something is using that server).
    private static func connectedPorts() -> Set<Int> {
        guard let lsof = which("lsof") else { return [] }
        let out = run(lsof, ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fn"], timeout: 6)
        var ports = Set<Int>()
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            // n127.0.0.1:3000->127.0.0.1:52344: both ends are local ports.
            for end in line.dropFirst().components(separatedBy: "->") {
                if end.hasPrefix("127.0.0.1:") || end.hasPrefix("[::1]:") || end.hasPrefix("localhost:"),
                   let port = Int(end.split(separator: ":").last ?? "") { ports.insert(port) }
            }
        }
        return ports
    }

    private static func workingDirectories(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty, let lsof = which("lsof") else { return [:] }
        let out = run(lsof, ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")], timeout: 6)
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n") { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    /// A terminal's last input (access time) and last output (modify time).
    private static func ttyTimes(_ tty: String) -> (input: Date, output: Date)? {
        var info = stat()
        guard stat("/dev/\(tty)", &info) == 0 else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)),
                Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }

    /// When an agent working in `folder` last wrote its transcript.
    private static func transcriptActivity(folder: String, command: String) -> Date? {
        let fm = FileManager.default
        if command.lowercased().contains("claude") {
            let encoded = folder.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            let dir = NSHomeDirectory() + "/.claude/projects/" + encoded
            let files = (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".jsonl") } ?? []
            return files.compactMap { (try? fm.attributesOfItem(atPath: "\(dir)/\($0)"))?[.modificationDate] as? Date }.max()
        }
        return nil
    }

    /// Running launchd jobs in the user's session that aren't Apple's: pid -> label.
    private static func launchdServices() -> [Int32: String] {
        let out = run("/bin/launchctl", ["list"], timeout: 6)
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 3, let pid = Int32(f[0]) else { continue }
            let label = f[2]
            if label.hasPrefix("com.apple.") || label.hasPrefix("application.") || label.contains(".apple.") { continue }
            // Only the user's own agents (homebrew services, runners, scripts), not vendors' helpers.
            let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
            if FileManager.default.fileExists(atPath: plist) || label.hasPrefix("homebrew.mxcl.") { result[pid] = label }
        }
        return result
    }

    static func which(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", NSHomeDirectory() + "/.local/bin"]
            .map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = EventToken.scrubbed(env)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// "[[dd-]hh:]mm:ss[.cc]" -> seconds.
    static func duration(_ text: String) -> TimeInterval {
        var days = 0.0
        var rest = text
        if let dash = text.firstIndex(of: "-") { days = Double(text[..<dash]) ?? 0; rest = String(text[text.index(after: dash)...]) }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        let seconds = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86400 + seconds
    }

    /// Docker's "2 days ago" / "About an hour ago" -> seconds.
    private static func dockerAge(_ text: String) -> TimeInterval {
        let t = text.lowercased()
        let n = Double(t.split(separator: " ").first(where: { Double($0) != nil }) ?? "") ?? 1
        if t.contains("second") { return n }
        if t.contains("minute") { return n * 60 }
        if t.contains("hour") { return n * 3600 }
        if t.contains("day") { return n * 86400 }
        if t.contains("week") { return n * 604800 }
        if t.contains("month") { return n * 2_592_000 }
        return 0
    }

    private static func parseBytes(_ text: String) -> Int64 {
        let t = text.trimmingCharacters(in: .whitespaces)
        let number = Double(t.prefix { "0123456789.".contains($0) }) ?? 0
        let unit = t.drop { "0123456789.".contains($0) }.lowercased()
        let scale: Double = unit.hasPrefix("g") ? 1_073_741_824 : unit.hasPrefix("m") ? 1_048_576 : unit.hasPrefix("k") ? 1024 : 1
        return Int64(number * scale)
    }

    static func bytes(_ n: Int64) -> String {
        n >= 1_000_000_000 ? String(format: "%.1f GB", Double(n) / 1_073_741_824)
            : n >= 1_000_000 ? "\(n / 1_048_576) MB" : "\(max(0, n) / 1024) KB"
    }

    /// "2d 3h", "45m": a length of time.
    static func span(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d \(s % 86400 / 3600)h ago"
    }
}
#endif
