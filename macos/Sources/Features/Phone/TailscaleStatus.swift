#if os(macOS)
import AppKit
import Combine

/// Where the user's Tailscale setup stands, as far as using Tellurion from a phone goes.
/// Read from `tailscale status --json`; nothing here changes Tailscale on its own. Each
/// step the setup panel offers runs only when the user presses its button.
struct TailscaleStatus: Equatable {
    enum State: Equatable {
        case notInstalled
        /// Installed, but its app (and so its background service) isn't running.
        case appNotRunning
        /// Logged in, switched off.
        case stopped
        case needsLogin
        /// Connecting, or another state Tailscale reports while it gets going.
        case starting
        case running
    }

    struct Device: Equatable, Identifiable {
        let name: String
        let os: String
        let online: Bool
        var id: String { name + os }
    }

    var state: State = .notInstalled
    /// This Mac's name on the tailnet, e.g. "studio.tail1234.ts.net".
    var dnsName: String?
    var ip: String?
    var magicDNS = false
    /// The tailnet can issue HTTPS certificates (needed for the phone web app to install and
    /// send notifications).
    var httpsEnabled = false
    /// Phones and tablets on the tailnet.
    var phones: [Device] = []
    /// Where to sign in, when Tailscale has one ready.
    var authURL: URL?
    /// The account this Mac is signed in with (e.g. "you@example.com").
    var loginName: String?

    /// Everything the phone needs is in place.
    var isReady: Bool { state == .running && magicDNS && httpsEnabled && !phones.isEmpty }

    /// The sidebar chip's one line.
    var summary: String {
        switch state {
        case .notInstalled: return "set up"
        case .appNotRunning, .stopped: return "Tailscale off"
        case .needsLogin: return "sign in to Tailscale"
        case .starting: return "connecting…"
        case .running:
            if !magicDNS || !httpsEnabled { return "turn on HTTPS" }
            if phones.isEmpty { return "add your phone" }
            let online = phones.filter(\.online)
            return online.isEmpty ? "ready · phone offline" : "ready · \(online[0].name)"
        }
    }
}

final class TailscaleMonitor: ObservableObject {
    static let shared = TailscaleMonitor()

    @Published private(set) var status = TailscaleStatus()
    /// A step is running (the buttons wait for it).
    @Published private(set) var busy = false
    @Published var error: String?

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.tailscale", qos: .utility)
    private var timer: Timer?
    private var fastUntil = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    static let appPath = "/Applications/Tailscale.app"
    static let adminDNS = URL(string: "https://login.tailscale.com/admin/dns")!
    static let download = URL(string: "https://tailscale.com/download")!

    /// The `tailscale` command: on PATH (Homebrew or the app's own CLI link), else inside the app.
    /// Run it with `run(_:)`: the app's binary only acts as the CLI when told to.
    static var binary: String? {
        ToolPath.find("tailscale") ?? [appPath + "/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private init() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
        schedule()
    }

    /// Checks every minute while the app is active, and every 3 seconds for a while after a
    /// step (or while the setup panel is open), so the panel follows along.
    private func schedule() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive || Date() < self.fastUntil else { return }
            let fast = Date() < self.fastUntil || AgentToolWindows.isOpen(PhoneSetup.windowID)
            if fast || Int(Date().timeIntervalSince1970) % 60 < 3 { self.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        queue.async {
            let status = Self.read()
            DispatchQueue.main.async {
                if status != self.status { self.status = status }
            }
        }
    }

    /// Keep checking quickly for the next two minutes (a step is under way elsewhere).
    func watch() {
        fastUntil = Date().addingTimeInterval(120)
        refresh()
    }

    private static func run(_ binary: String, _ args: [String]) -> AgentTools.Result {
        ToolPath.run(binary, args, in: NSHomeDirectory(), environment: ["TAILSCALE_BE_CLI": "1"])
    }

    // MARK: Reading

    private static func read() -> TailscaleStatus {
        var status = TailscaleStatus()
        guard let binary else { return status }
        let result = Self.run(binary, ["status", "--json"])
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else {
            // No service to talk to: the app isn't running (or isn't set up yet).
            status.state = .appNotRunning
            return status
        }
        switch json["BackendState"] as? String {
        case "Running": status.state = .running
        case "Stopped": status.state = .stopped
        case "NeedsLogin", "NeedsMachineAuth": status.state = .needsLogin
        default: status.state = .starting
        }
        status.authURL = (json["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let me = json["Self"] as? [String: Any] ?? [:]
        if let userID = me["UserID"] as? NSNumber, let users = json["User"] as? [String: [String: Any]] {
            status.loginName = users[userID.stringValue]?["LoginName"] as? String
        }
        status.dnsName = (me["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        status.ip = (me["TailscaleIPs"] as? [String])?.first { !$0.contains(":") }
        status.magicDNS = (json["CurrentTailnet"] as? [String: Any])?["MagicDNSEnabled"] as? Bool ?? false
        status.httpsEnabled = !((json["CertDomains"] as? [String]) ?? []).isEmpty
        let peers = (json["Peer"] as? [String: [String: Any]] ?? [:]).values
        status.phones = peers
            .filter { ["iOS", "android"].contains($0["OS"] as? String ?? "") }
            .map { peer in
                let host = peer["HostName"] as? String ?? ""
                // iPhones report "localhost" as their host name; the DNS name is the real one.
                let dns = (peer["DNSName"] as? String)?.split(separator: ".").first.map(String.init)
                let name = host.isEmpty || host == "localhost" ? (dns ?? "Phone") : host
                return TailscaleStatus.Device(name: name, os: peer["OS"] as? String ?? "", online: peer["Online"] as? Bool ?? false)
            }
            .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
        return status
    }

    // MARK: Steps (each runs only from its button)

    /// Installs Tailscale with Homebrew in a new tab, or opens the download page.
    func install() {
        if let brew = ToolPath.find("brew") {
            SetupChecks.openTab(running: "\(AgentTools.shellQuote(brew)) install --cask tailscale && open -a Tailscale")
        } else {
            NSWorkspace.shared.open(Self.download)
        }
        watch()
    }

    /// Opens the Tailscale app, which starts its background service.
    func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.appPath))
        watch()
    }

    /// Switches Tailscale on (`tailscale up`). Signing in happens in the browser.
    func connect() {
        guard let binary = Self.binary else { return }
        if status.state == .needsLogin, let url = status.authURL {
            NSWorkspace.shared.open(url)
            watch()
            return
        }
        busy = true
        error = nil
        queue.async {
            // `up` waits for sign-in when it's needed; don't hold the button for that.
            let result = Self.run(binary, ["up", "--timeout=15s"])
            let text = (result.output + "\n" + result.error)
            let login = text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("https://login.tailscale.com/") }
            DispatchQueue.main.async {
                self.busy = false
                if let login, let url = URL(string: String(login)) {
                    NSWorkspace.shared.open(url)
                } else if !result.ok, !text.contains("timeout") {
                    self.error = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                }
                self.watch()
            }
        }
    }

    // MARK: Serve (phone access)

    enum ServeResult {
        case success(Int)
        case failure(String)
    }

    /// HTTPS ports tried for the phone, in order (one the user already serves something on is skipped).
    private static let servePorts = [443, 8443, 10443]

    /// The HTTPS port already forwarding to `localPort`, if any.
    func servedPort(localPort: UInt16, completion: @escaping (Int?) -> Void) {
        guard let binary = Self.binary else { completion(nil); return }
        queue.async {
            let port = Self.serveConfig(binary).ports[Self.target(localPort)]
            DispatchQueue.main.async { completion(port) }
        }
    }

    /// Puts `tailscale serve` in front of the local phone server (HTTPS, tailnet only).
    func serve(localPort: UInt16, completion: @escaping (ServeResult) -> Void) {
        guard let binary = Self.binary else { completion(.failure("Tailscale isn't installed.")); return }
        busy = true
        queue.async {
            let config = Self.serveConfig(binary)
            let target = Self.target(localPort)
            var result: ServeResult
            if let port = config.ports[target] {
                result = .success(port)
            } else if let port = Self.servePorts.first(where: { !config.used.contains($0) }) {
                let run = Self.run(binary, ["serve", "--bg", "--yes", "--https=\(port)", target], timeout: 20)
                let text = run.output + "\n" + run.error
                if run.ok, Self.serveConfig(binary).ports[target] == port {
                    result = .success(port)
                } else if let link = text.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("https://login.tailscale.com/") }),
                          let url = URL(string: String(link)) {
                    // Serve has to be allowed for the tailnet first; Tailscale gives a link.
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                    result = .failure("Allow Tailscale Serve in the page that just opened, then turn phone access on again.")
                } else {
                    result = .failure(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
                }
            } else {
                result = .failure("HTTPS ports 443, 8443 and 10443 are all in use by other Tailscale Serve entries.")
            }
            DispatchQueue.main.async {
                self.busy = false
                completion(result)
            }
        }
    }

    /// Removes the `tailscale serve` entry for the phone server (and nothing else).
    func unserve(localPort: UInt16) {
        guard let binary = Self.binary else { return }
        queue.async {
            if let port = Self.serveConfig(binary).ports[Self.target(localPort)] {
                _ = Self.run(binary, ["serve", "--https=\(port)", "off"], timeout: 15)
            }
        }
    }

    private static func target(_ localPort: UInt16) -> String { "http://127.0.0.1:\(localPort)" }

    /// Which HTTPS ports serve something, and which of them proxy where.
    private static func serveConfig(_ binary: String) -> (used: Set<Int>, ports: [String: Int]) {
        let result = run(binary, ["serve", "status", "--json"], timeout: 10)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] else { return ([], [:]) }
        let used = Set((json["TCP"] as? [String: Any] ?? [:]).keys.compactMap(Int.init))
        var ports: [String: Int] = [:]
        for (hostPort, value) in json["Web"] as? [String: Any] ?? [:] {
            guard let port = hostPort.split(separator: ":").last.flatMap({ Int($0) }),
                  let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any],
                  let proxy = (handlers["/"] as? [String: Any])?["Proxy"] as? String else { continue }
            ports[proxy.hasSuffix("/") ? String(proxy.dropLast()) : proxy] = port
        }
        return (used, ports)
    }

    /// Runs the CLI, giving up after `timeout` seconds (some commands wait for the user).
    private static func run(_ binary: String, _ args: [String], timeout: TimeInterval) -> AgentTools.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["TAILSCALE_BE_CLI"] = "1"
        process.environment = EventToken.scrubbed(environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return AgentTools.Result(status: -1, output: "", error: "\(error)") }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return AgentTools.Result(status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
                                 error: String(decoding: errData, as: UTF8.self))
    }

    /// Opens the admin page where MagicDNS and HTTPS certificates are switched on.
    func openHTTPSSettings() {
        NSWorkspace.shared.open(Self.adminDNS)
        watch()
    }
}
#endif
