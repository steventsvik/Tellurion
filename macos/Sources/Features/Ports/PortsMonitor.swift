#if os(macOS)
import AppKit
import Combine

/// A TCP port something of the user's is listening on.
struct PortEntry: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        /// Started from a project folder: a dev server, database, worker.
        case dev
        /// Forwarded from a container or VM (Docker, Colima, OrbStack).
        case container
        /// Apps and background services.
        case other

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let port: Int
    let pid: Int32
    /// The command that was actually run (`npm run dev`), which stopping ends.
    let rootPID: Int32
    let processName: String
    let command: String
    let cwd: String?
    let memory: Int64
    let kind: Kind
    /// The localhost session that owns it, if any.
    var sessionID: String?

    var id: String { "\(pid):\(port)" }

    var project: LocalhostProject? {
        guard let cwd, cwd != NSHomeDirectory(), cwd != "/" else { return nil }
        return LocalhostProject(folder: cwd)
    }

    var title: String {
        if kind == .container {
            let text = (processName + " " + command).lowercased()
            if text.contains("colima") || text.contains("lima") { return "Colima" }
            if text.contains("orbstack") { return "OrbStack" }
            return "Docker"
        }
        return project?.name ?? processName
    }
    var url: URL? { URL(string: "http://localhost:\(port)") }
    var framework: LocalhostFramework { LocalhostFramework.detect(command: command, cwd: cwd) }
}

/// Keeps the sidebar's list of listening ports current, and stops what the user asks.
///
/// Scans with `ProcessProbe` (a couple of milliseconds, no subprocesses) every few seconds,
/// only while a sidebar shows the list and the app is active.
final class PortsMonitor: ObservableObject {
    static let shared = PortsMonitor()

    @Published private(set) var entries: [PortEntry] = []
    /// Ports being stopped, so their rows can say so.
    @Published private(set) var stopping: Set<String> = []
    /// A command that just failed because its port was taken.
    @Published private(set) var conflict: Conflict?

    struct Conflict: Equatable {
        let port: Int
        let command: String
        let at: Date
    }

    private var watchers = 0
    private var timer: Timer?
    private var scanning = false
    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.ports", qos: .utility)
    /// What doesn't change for a process, keyed by pid and start time.
    private struct Detail {
        let rootPID: Int32
        let name: String
        let command: String
        let cwd: String?
    }

    private var details: [String: Detail] = [:]
    private static let interval: TimeInterval = 3

    /// Processes whose listening ports are forwarded from a container or VM.
    private static let containerProcesses: Set<String> = [
        "ssh", "limactl", "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "docker-proxy",
        "colima", "OrbStack Helper", "orbstack", "qemu-system-aarch64", "gvproxy",
    ]

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.updateTimer(scanNow: true) }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.updateTimer(scanNow: false) }
            .store(in: &cancellables)
    }

    var devEntries: [PortEntry] { entries.filter { $0.kind == .dev } }

    /// A sidebar started (true) or stopped (false) showing the list.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        updateTimer(scanNow: on)
    }

    private func updateTimer(scanNow: Bool) {
        let wanted = watchers > 0 && NSApp.isActive && TellurionSettings.isOn(.ports)
        if wanted, timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
        if wanted && scanNow { refresh() }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let known = details
        queue.async { [weak self] in
            var details = known
            let entries = Self.scan(details: &details)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.details = details
                let sessions = LocalhostSessions.shared.sessions
                let owned = entries.map { entry -> PortEntry in
                    var entry = entry
                    entry.sessionID = sessions.first { $0.ports.contains(entry.port) }?.id
                    return entry
                }
                if self.entries != owned { self.entries = owned }
                if let conflict = self.conflict, !owned.contains(where: { $0.port == conflict.port }) {
                    // Whatever held the port is gone.
                    self.conflict = nil
                }
            }
        }
    }

    private static func scan(details: inout [String: Detail]) -> [PortEntry] {
        let listeners = ProcessProbe.listeners()
        var live: Set<String> = []
        var entries: [PortEntry] = []
        for listener in listeners {
            guard let info = ProcessProbe.bsdInfo(listener.pid) else { continue }
            let key = "\(listener.pid)@\(info.start.timeIntervalSince1970)"
            live.insert(key)
            if details[key] == nil {
                // Walk up to the command the user (or agent) ran: `npm run dev`, not the
                // `node vite` it started. Stops below the shell, the agent or launchd.
                var root = info
                while root.ppid > 1, let parent = ProcessProbe.bsdInfo(root.ppid),
                      !LocalhostSessions.boundaries.contains(parent.name.lowercased()),
                      !parent.name.lowercased().hasPrefix("ghostty") {
                    root = parent
                }
                var command = ProcessProbe.commandLine(root.pid).map(LocalhostSessions.prettyCommand) ?? root.name
                // `/Applications/…/Python -m http.server` → `Python -m http.server`.
                if command.hasPrefix("/") {
                    let space = command.firstIndex(of: " ") ?? command.endIndex
                    command = (String(command[..<space]) as NSString).lastPathComponent + command[space...]
                }
                details[key] = Detail(rootPID: root.pid, name: info.name, command: command,
                                      cwd: ProcessProbe.cwd(root.pid) ?? ProcessProbe.cwd(listener.pid))
            }
            guard let detail = details[key] else { continue }
            let kind: PortEntry.Kind
            if containerProcesses.contains(detail.name) || containerProcesses.contains(where: { detail.name.hasPrefix($0) }) {
                kind = .container
            } else if let cwd = detail.cwd, cwd != "/" {
                kind = .dev
            } else {
                kind = .other
            }
            entries.append(PortEntry(port: listener.port, pid: listener.pid, rootPID: detail.rootPID,
                                     processName: detail.name, command: detail.command, cwd: detail.cwd,
                                     memory: ProcessProbe.memory(listener.pid), kind: kind, sessionID: nil))
        }
        details = details.filter { live.contains($0.key) }
        return entries.sorted { ($0.kind, $0.port) < ($1.kind, $1.port) }
    }

    // MARK: Stopping

    /// Ends the server: its localhost session, or else the command that started it (Ctrl-C's
    /// signal first, then a forced stop if it's still listening three seconds later).
    func stop(_ entry: PortEntry) {
        if let id = entry.sessionID, let session = LocalhostSessions.shared.sessions.first(where: { $0.id == id }) {
            LocalhostSessions.shared.stop(session)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
            return
        }
        guard entry.kind != .container, entry.pid > 1, entry.rootPID > 1, entry.pid != getpid() else { return }
        stopping.insert(entry.id)
        // A server that's its own job (started at a shell prompt) gets Ctrl-C's signal as a
        // group, so helpers it started stop too. Only then: a server an agent started can
        // share the agent's group, and that must never be interrupted.
        if getpgid(entry.rootPID) == entry.rootPID { killpg(entry.rootPID, SIGINT) }
        kill(entry.rootPID, SIGTERM)
        if entry.pid != entry.rootPID { kill(entry.pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if ProcessProbe.isAlive(entry.pid),
               ProcessProbe.listeners().contains(where: { $0.pid == entry.pid && $0.port == entry.port }) {
                kill(entry.pid, SIGKILL)
                if ProcessProbe.isAlive(entry.rootPID) { kill(entry.rootPID, SIGKILL) }
            }
            self.stopping.remove(entry.id)
            self.refresh()
        }
        refresh()
    }

    // MARK: Port conflicts

    /// Called with a failed command's output. "Port 3000 is in use" and friends raise a
    /// notice in the sidebar naming what holds the port.
    func commandFailed(_ command: String, output: String) {
        guard TellurionSettings.isOn(.ports),
              let port = Self.conflictPort(in: output) ?? Self.conflictPort(command: command, output: output) else { return }
        conflict = Conflict(port: port, command: command, at: Date())
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let conflict = self?.conflict, Date().timeIntervalSince(conflict.at) >= 119 { self?.conflict = nil }
        }
    }

    func dismissConflict() { conflict = nil }

    private static let conflictPatterns: [NSRegularExpression] = [
        #"EADDRINUSE[^\n]*?:(\d{2,5})\b"#,
        #"address already in use[^\n]*?:(\d{2,5})\b"#,
        #"[Pp]ort (\d{2,5}) is (?:already )?(?:in use|allocated|taken|being used)"#,
        #"[Aa]lready in use[^\n]*?[Pp]ort (\d{2,5})"#,
        #"bind[^\n]*?:(\d{2,5})[^\n]*?address already in use"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Some servers say the address is in use without naming the port (Python's
    /// http.server, many frameworks); then it's read from the command: `--port 3000`,
    /// `-p 3000`, `PORT=3000`, `:3000`, or a bare number like `http.server 8000`.
    static func conflictPort(command: String, output: String) -> Int? {
        let text = output.suffix(8000).lowercased()
        guard text.contains("address already in use") || text.contains("eaddrinuse") else { return nil }
        let patterns = [#"(?:--port[= ]|-p[= ]?|PORT=|:)(\d{2,5})\b"#, #"(?:^|\s)(\d{2,5})(?:\s|$)"#]
        let range = NSRange(command.startIndex..., in: command)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: command, range: range),
                  let portRange = Range(match.range(at: 1), in: command), let port = Int(command[portRange]),
                  (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }

    static func conflictPort(in output: String) -> Int? {
        let tail = String(output.suffix(8000))
        let range = NSRange(tail.startIndex..., in: tail)
        for pattern in conflictPatterns {
            guard let match = pattern.firstMatch(in: tail, range: range), match.numberOfRanges > 1,
                  let portRange = Range(match.range(at: 1), in: tail), let port = Int(tail[portRange]),
                  (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }
}
#endif
