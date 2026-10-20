#if os(macOS)
import AppKit
import Combine
import GhosttyKit

/// Lets a paired phone use this Mac's terminal: it lists the tabs with their agents' status,
/// mirrors a tab's screen live, and types into it.
///
/// Security, in layers:
/// - The server listens on 127.0.0.1 only. Phones reach it through `tailscale serve`, which
///   is private to the user's tailnet (never Funnel) and adds the caller's Tailscale login.
/// - Requests must carry the Mac owner's Tailscale login, so other people on a shared
///   tailnet (and anything on this Mac that doesn't go through Tailscale) are turned away.
/// - Everything past pairing needs a device token. Pairing takes a one-time code from the
///   QR on the Mac, valid for 10 minutes. Tokens are stored hashed and revocable.
/// - It's off until the user turns it on, and shows who's connected.
final class PhoneServer: ObservableObject {
    static let shared = PhoneServer()

    static let enabledKey = "PhoneAccessEnabled"
    /// The local port `tailscale serve` forwards to.
    static let localPort: UInt16 = 47_811
    /// Test copies can talk to it from this Mac without Tailscale (GHOSTTY_EXTREME_PHONE_DEV=1).
    static let devMode = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_PHONE_DEV"] == "1"

    @Published private(set) var running = false
    /// The HTTPS port `tailscale serve` uses for it, once set up.
    @Published private(set) var servePort: Int?
    @Published private(set) var error: String?
    /// Phones connected right now, by device id.
    @Published private(set) var connected: [String: Int] = [:]

    private var http: PhoneHTTPServer?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var screenTimer: Timer?
    private var tabsTimer: Timer?
    /// Terminal windows that have closed. AppKit can keep a closed tab's window (and its
    /// terminal) around for a while; the phone shouldn't see it.
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()
    private var closeObserver: NSObjectProtocol?

    private init() {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                               queue: .main) { [weak self] note in
            if let window = note.object as? NSWindow { self?.closedWindows.add(window) }
        }
    }

    /// Classic windows and boards that are open now.
    private var openControllers: [BaseTerminalController] {
        TerminalWindows.all.filter { controller in
            guard let window = controller.window else { return false }
            return !closedWindows.contains(window)
        }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The address phones use, when it's set up.
    var url: URL? {
        if Self.devMode { return URL(string: "http://127.0.0.1:\(Self.localPort)/") }
        guard let host = TailscaleMonitor.shared.status.dnsName, let port = servePort else { return nil }
        return URL(string: port == 443 ? "https://\(host)/" : "https://\(host):\(port)/")
    }

    /// Starts the server at launch if the user left phone access on.
    func startIfEnabled() {
        guard ExtremeSettings.isOn(.phone) else { return }
        // A test copy in dev mode serves on this Mac only, without touching Tailscale.
        if Self.devMode {
            start()
            servePort = Int(Self.localPort)
            // Tests pair without the window: GHOSTTY_EXTREME_PHONE_DEV_CODE is the pairing code.
            if let code = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_PHONE_DEV_CODE"], !code.isEmpty {
                PhoneDevices.shared.useTestPairingCode(code)
            }
            return
        }
        // Test copies only: GHOSTTY_EXTREME_PHONE_TEST=on|off presses Turn on / Turn off at launch.
        if Bundle.main.bundleIdentifier == "com.steventsvik.ghostty-extreme.test",
           let test = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_PHONE_TEST"] {
            if test == "on" { turnOn() } else if test == "off" { turnOff() }
            return
        }
        guard Self.isEnabled else { return }
        start()
    }

    // MARK: On and off

    /// Turns phone access on: the local server, then `tailscale serve` in front of it.
    func turnOn() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        start()
        TailscaleMonitor.shared.serve(localPort: Self.localPort) { [weak self] result in
            switch result {
            case .success(let port): self?.servePort = port
            case .failure(let message): self?.error = message
            }
        }
    }

    /// Turns it off: disconnects every phone, stops the server and removes the
    /// `tailscale serve` entry.
    func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        stop()
        TailscaleMonitor.shared.unserve(localPort: Self.localPort)
        servePort = nil
        PhoneDevices.shared.cancelPairing()
    }

    private func start() {
        guard http == nil else { return }
        let server = PhoneHTTPServer(port: Self.localPort)
        server.handleRequest = { [weak self] in self?.handle($0) ?? .text("Gone", status: 503) }
        server.acceptSocket = { [weak self] request, socket in self?.accept(request, socket) ?? false }
        do {
            try server.start()
            http = server
            running = true
            error = nil
        } catch {
            self.error = "Couldn't listen on port \(Self.localPort): \(error.localizedDescription)"
        }
        if servePort == nil {
            TailscaleMonitor.shared.servedPort(localPort: Self.localPort) { [weak self] in self?.servePort = $0 }
        }
    }

    private func stop() {
        for client in clients.values { client.socket.close() }
        clients = [:]
        connected = [:]
        http?.stop()
        http = nil
        running = false
        updateTimers()
    }

    func disconnect(device id: String) {
        for client in clients.values where client.device?.id == id { client.socket.close() }
    }

    // MARK: Who's asking

    /// The Tailscale login on a request, when it came through `tailscale serve` from the
    /// Mac owner's own account. Nil means turn it away.
    private func caller(_ request: PhoneHTTPServer.Request) -> String? {
        let login = request.headers["tailscale-user-login"]
        if let login, let owner = TailscaleMonitor.shared.status.loginName, login.caseInsensitiveCompare(owner) == .orderedSame {
            return login
        }
        if Self.devMode, login == nil { return "dev" }
        return nil
    }

    // MARK: HTTP

    private func handle(_ request: PhoneHTTPServer.Request) -> PhoneHTTPServer.Response {
        guard caller(request) != nil else {
            return .text("This Tellurion only answers its owner's Tailscale devices.", status: 403)
        }
        switch (request.method, request.path) {
        case ("POST", "/api/pair"):
            return pair(request)
        case ("GET", "/api/ping"):
            return .json(["ok": true])
        case ("GET", _):
            return PhoneWebFiles.response(for: request.path)
        default:
            return .text("Not found", status: 404)
        }
    }

    private func pair(_ request: PhoneHTTPServer.Request) -> PhoneHTTPServer.Response {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let code = body["code"] as? String else { return .json(["error": "Missing code"], status: 400) }
        let name = body["name"] as? String ?? "Phone"
        switch PhoneDevices.shared.pair(code: code, name: name, login: request.headers["tailscale-user-login"]) {
        case .paired(let token, let device):
            return .json(["token": token, "device": device.id, "mac": Host.current().localizedName ?? "Mac"])
        case .invalid:
            return .json(["error": "That pairing code isn't valid any more. Show a new one on your Mac."], status: 401)
        case .locked:
            return .json(["error": "Too many wrong codes. Show a new one on your Mac."], status: 429)
        }
    }

    // MARK: WebSocket

    private final class Client {
        let socket: PhoneSocket
        var device: PhoneDevice?
        /// The surface it's watching.
        var watching: UUID?
        var lastScreen = ""
        var lastTabs = ""
        init(socket: PhoneSocket) { self.socket = socket }
    }

    private func accept(_ request: PhoneHTTPServer.Request, _ socket: PhoneSocket) -> Bool {
        guard request.path == "/api/ws", caller(request) != nil, originAllowed(request.headers["origin"]) else { return false }
        let client = Client(socket: socket)
        let id = ObjectIdentifier(client)
        clients[id] = client
        socket.onMessage = { [weak self, weak client] text in
            guard let self, let client else { return }
            self.receive(text, from: client)
        }
        socket.onClose = { [weak self] in self?.dropClient(id) }
        // It has a few seconds to say who it is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak client] in
            if let client, client.device == nil { client.socket.close() }
        }
        return true
    }

    /// Browsers send their page's origin; it must be this server's own address.
    private func originAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        if Self.devMode, origin.hasPrefix("http://127.0.0.1:") || origin.hasPrefix("http://localhost:") { return true }
        guard let url else { return false }
        let own = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        return origin.caseInsensitiveCompare(own) == .orderedSame
    }

    private func dropClient(_ id: ObjectIdentifier) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if let device = client.device {
            connected[device.id, default: 1] -= 1
            if connected[device.id] ?? 0 <= 0 { connected.removeValue(forKey: device.id) }
        }
        updateTimers()
    }

    private func receive(_ text: String, from client: Client) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = message["t"] as? String else { return }

        guard let device = client.device else {
            // The first message must be the device's token.
            guard type == "hello", let token = message["token"] as? String,
                  let device = PhoneDevices.shared.device(for: token) else {
                client.socket.send(Self.json(["t": "error", "code": "unpaired", "message": "This phone isn't paired any more."]))
                client.socket.close()
                return
            }
            client.device = device
            connected[device.id, default: 0] += 1
            PhoneDevices.shared.touch(device.id)
            client.socket.send(Self.json(["t": "hello", "mac": Host.current().localizedName ?? "Mac", "device": device.name,
                                          "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]))
            client.lastTabs = tabsMessage()
            client.socket.send(client.lastTabs)
            updateTimers()
            return
        }
        PhoneDevices.shared.touch(device.id)

        switch type {
        case "watch":
            client.watching = (message["id"] as? String).flatMap(UUID.init(uuidString:))
            client.lastScreen = ""
            updateTimers()
            pushScreens()
        case "unwatch":
            client.watching = nil
            updateTimers()
        case "text":
            guard let surface = surface(message["id"]), let text = message["text"] as? String, !text.isEmpty else { return }
            // Messages arrive on the main queue.
            MainActor.assumeIsolated { Self.type(text, on: surface) }
        case "key":
            guard let surface = surface(message["id"]), let key = message["key"] as? String else { return }
            let mods = message["mods"] as? [String] ?? []
            MainActor.assumeIsolated { Self.press(key, mods: mods, on: surface) }
        case "ping":
            client.socket.send(Self.json(["t": "pong"]))
        case "unpair":
            // The phone asked to be forgotten.
            PhoneDevices.shared.remove(device.id)
        default:
            break
        }
    }

    // MARK: Tabs

    private func surface(_ id: Any?) -> Ghostty.SurfaceView? {
        guard let text = id as? String, let uuid = UUID(uuidString: text) else { return nil }
        for controller in openControllers {
            if let match = controller.surfaceTree.first(where: { $0.id == uuid }) { return match }
        }
        return nil
    }

    private func tabsMessage() -> String {
        var tabs: [[String: Any]] = []
        let key = TerminalWindows.controller(of: NSApp.keyWindow)
        for controller in openControllers {
            for surface in controller.surfaceTree {
                let server = LocalhostSessions.shared.session(for: surface)
                var tab: [String: Any] = [
                    "id": surface.id.uuidString,
                    "title": TerminalWindows.title(of: surface, in: controller as? BoardController) ?? surface.title,
                    "pwd": surface.pwd.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "",
                    "focused": controller === key && controller.focusedSurface === surface,
                ]
                if let pwd = surface.pwd { tab["project"] = LocalhostProject(folder: pwd).name }
                if let server { tab["localhost"] = server.url?.absoluteString ?? "" }
                if let info = VerticalTabsAgents.shared.info(for: surface) {
                    tab["agent"] = info.kind.rawValue
                    tab["agentName"] = info.kind.displayName
                    tab["activity"] = Self.activity(info.activity)
                    if let task = info.task { tab["task"] = String(task.prefix(200)) }
                    if let detail = info.detail { tab["detail"] = String(detail.prefix(200)) }
                }
                tabs.append(tab)
            }
        }
        return Self.json(["t": "tabs", "tabs": tabs])
    }

    private static func activity(_ activity: VerticalTabAgentActivity) -> String {
        switch activity {
        case .ready: return "ready"
        case .working: return "working"
        case .needsPermission: return "permission"
        case .needsInput: return "input"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    // MARK: Screens

    private func updateTimers() {
        let authed = clients.values.contains { $0.device != nil }
        let watching = clients.values.contains { $0.watching != nil }
        if watching, screenTimer == nil {
            // 10 times a second, sent only when the screen changed.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pushScreens() }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            screenTimer = timer
        } else if !watching {
            screenTimer?.invalidate()
            screenTimer = nil
        }
        if authed, tabsTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.pushTabs() }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            tabsTimer = timer
        } else if !authed {
            tabsTimer?.invalidate()
            tabsTimer = nil
        }
    }

    private func pushTabs() {
        let message = tabsMessage()
        for client in clients.values where client.device != nil && client.lastTabs != message {
            client.lastTabs = message
            client.socket.send(message)
        }
    }

    private func pushScreens() {
        var cache: [UUID: String] = [:]
        for client in clients.values {
            guard let id = client.watching, !client.socket.isBackedUp else { continue }
            let message: String
            if let cached = cache[id] {
                message = cached
            } else {
                guard let surface = surface(id.uuidString), let built = Self.screenMessage(surface) else { continue }
                cache[id] = built
                message = built
            }
            guard message != client.lastScreen else { continue }
            client.lastScreen = message
            client.socket.send(message)
        }
    }

    private static func screenMessage(_ surface: Ghostty.SurfaceView) -> String? {
        guard let cSurface = surface.surface else { return nil }
        var mirror = ghostty_mirror_s()
        guard ghostty_surface_read_mirror(cSurface, &mirror) else { return nil }
        defer { ghostty_surface_free_mirror(&mirror) }
        let vt = mirror.text.map { String(cString: $0) } ?? ""
        return json([
            "t": "screen", "id": surface.id.uuidString, "vt": vt,
            "cols": Int(mirror.cols), "rows": Int(mirror.rows),
            "x": Int(mirror.cursor_x), "y": Int(mirror.cursor_y), "cursor": mirror.cursor_visible,
            "alt": mirror.alternate,
            "bg": String(format: "#%06x", mirror.background), "fg": String(format: "#%06x", mirror.foreground),
        ])
    }

    // MARK: Keys

    /// Presses a key in the surface: "enter", "tab", "escape", "backspace", "arrowUp"… or a
    /// letter, digit or space with modifiers ("c" with ["ctrl"] for Ctrl-C, "1" to pick the
    /// first option in an agent's menu).
    @MainActor
    private static func press(_ name: String, mods names: [String], on surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel, let key = key(named: name) else { return }
        var mods: Ghostty.Input.Mods = []
        if names.contains("ctrl") { mods.insert(.ctrl) }
        if names.contains("alt") { mods.insert(.alt) }
        if names.contains("shift") { mods.insert(.shift) }
        let text: String?
        switch key {
        case .enter: text = "\r"
        case .tab: text = "\t"
        case .escape: text = "\u{1b}"
        case .backspace: text = "\u{7f}"
        default: text = mods.isEmpty && name.count == 1 ? name : nil
        }
        let codepoint = name.count == 1 ? name.lowercased().unicodeScalars.first!.value : 0
        model.sendKeyEvent(.init(key: key, action: .press, text: mods.contains(.ctrl) ? nil : text,
                                 mods: mods, unshiftedCodepoint: codepoint))
        model.sendKeyEvent(.init(key: key, action: .release, mods: mods, unshiftedCodepoint: codepoint))
    }

    /// Types text the way a keyboard would, so programs see keystrokes rather than a paste
    /// (vim runs ":q!" instead of inserting it). Several lines, long text and characters a
    /// US keyboard doesn't have go in as a paste.
    @MainActor
    private static func type(_ text: String, on surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel else { return }
        if text.contains(where: \.isNewline) || text.count > 300 {
            model.sendText(text)
            return
        }
        var pending = ""
        for char in text {
            guard let (key, shift) = usKey(for: char) else {
                pending.append(char)
                continue
            }
            if !pending.isEmpty { model.sendText(pending); pending = "" }
            let mods: Ghostty.Input.Mods = shift ? [.shift] : []
            let unshifted = shift ? (usUnshifted[key] ?? char) : char
            let codepoint = unshifted.unicodeScalars.first?.value ?? 0
            model.sendKeyEvent(.init(key: key, action: .press, text: String(char), mods: mods, consumedMods: mods,
                                     unshiftedCodepoint: codepoint))
            model.sendKeyEvent(.init(key: key, action: .release, mods: mods, unshiftedCodepoint: codepoint))
        }
        if !pending.isEmpty { model.sendText(pending) }
    }

    private static let usShifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    private static let usPunctuation: [Character: Ghostty.Input.Key] = [
        "-": .minus, "=": .equal, "[": .bracketLeft, "]": .bracketRight, "\\": .backslash, ";": .semicolon,
        "'": .quote, ",": .comma, ".": .period, "/": .slash, "`": .backquote, " ": .space,
    ]

    /// The unshifted character on each key, for shifted punctuation.
    private static let usUnshifted: [Ghostty.Input.Key: Character] = {
        var map: [Ghostty.Input.Key: Character] = [:]
        for (char, key) in usPunctuation { map[key] = char }
        for digit in "0123456789" { if let key = Ghostty.Input.Key(rawValue: "digit\(digit)") { map[key] = digit } }
        return map
    }()

    /// The key and Shift state that types a character on a US keyboard.
    private static func usKey(for char: Character) -> (Ghostty.Input.Key, Bool)? {
        guard char.isASCII else { return nil }
        if char.isLetter, let key = Ghostty.Input.Key(rawValue: char.lowercased()) { return (key, char.isUppercase) }
        if char.isNumber, let key = Ghostty.Input.Key(rawValue: "digit\(char)") { return (key, false) }
        if let key = usPunctuation[char] { return (key, false) }
        if let base = usShifted[char], let found = usKey(for: base) { return (found.0, true) }
        return nil
    }

    private static func key(named name: String) -> Ghostty.Input.Key? {
        guard name.count == 1, let char = name.first, char.isASCII else { return Ghostty.Input.Key(rawValue: name) }
        if char.isLetter { return Ghostty.Input.Key(rawValue: name.lowercased()) }
        if char.isNumber { return Ghostty.Input.Key(rawValue: "digit" + name) }
        if char == " " { return .space }
        return nil
    }

    /// Sorted keys, so the same content always gives the same text (messages are only sent
    /// when the text changed).
    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The phone web app's files, from the app bundle.
enum PhoneWebFiles {
    private static let base = Bundle.main.resourceURL!.appendingPathComponent("PhoneWeb", isDirectory: true)

    static func response(for path: String) -> PhoneHTTPServer.Response {
        let relative = path == "/" ? "index.html" : String(path.drop { $0 == "/" })
        // Only plain names inside the folder.
        guard !relative.contains(".."), !relative.contains("\\"),
              relative.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil else {
            return .text("Not found", status: 404)
        }
        let file = base.appendingPathComponent(relative)
        guard file.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file) else {
            return .text("Not found", status: 404)
        }
        var response = PhoneHTTPServer.Response(status: 200, body: data)
        response.headers["Content-Type"] = contentType(file.pathExtension)
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Content-Security-Policy"] =
            "default-src 'self'; connect-src 'self' wss:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
        return response
    }

    private static func contentType(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
#endif
