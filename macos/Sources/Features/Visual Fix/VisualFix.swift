#if os(macOS)
import AppKit
import Combine
import SwiftUI
import WebKit

// Visual Fix: preview a running app beside the terminal, point at anything on the page, say
// what should change, and hand it to the agent in the tab, with the element's details and a
// screenshot. Each request stays pinned to its element until the agent is done.

/// What the page reported about an element.
struct VisualFixElement: Equatable {
    let tag: String
    let text: String
    let selector: String
    let label: String
    let attributes: [String: String]
    /// In the page's CSS pixels, relative to its viewport.
    let rect: CGRect
    let components: [String]
    /// "file:line" of the code that renders it, when the page's framework says.
    let source: String?
    let styles: [String: String]
    let pageURL: String
    let pageTitle: String
    let viewport: CGSize

    init?(_ json: [String: Any]) {
        guard let tag = json["tag"] as? String, let selector = json["selector"] as? String else { return nil }
        self.tag = tag
        self.selector = selector
        text = json["text"] as? String ?? ""
        label = json["label"] as? String ?? tag
        attributes = json["attrs"] as? [String: String] ?? [:]
        rect = VisualFixElement.rect(json["rect"]) ?? .zero
        components = json["components"] as? [String] ?? []
        if let source = json["source"] as? [String: Any], let file = source["file"] as? String {
            self.source = (source["line"] as? Int).map { "\(file):\($0)" } ?? file
        } else {
            source = nil
        }
        styles = (json["styles"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let page = json["page"] as? [String: Any] ?? [:]
        pageURL = page["url"] as? String ?? ""
        pageTitle = page["title"] as? String ?? ""
        viewport = CGSize(width: page["width"] as? Double ?? 0, height: page["height"] as? Double ?? 0)
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let r = value as? [String: Any], let x = r["x"] as? Double, let y = r["y"] as? Double,
              let w = r["w"] as? Double, let h = r["h"] as? Double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The component chain, innermost first ("SaveButton › CheckoutForm").
    var componentPath: String? { components.isEmpty ? nil : components.joined(separator: " › ") }
}

/// The width the page is laid out at.
enum VisualFixDevice: String, CaseIterable, Identifiable {
    case desktop, tablet, phone

    var id: String { rawValue }
    var width: CGFloat {
        switch self {
        case .desktop: return 1280
        case .tablet: return 820
        case .phone: return 390
        }
    }
    var name: String { rawValue.capitalized }
    var icon: PixelIcon {
        switch self {
        case .desktop: return .desktop
        case .tablet: return .tablet
        case .phone: return .phone
        }
    }
}

/// One change sent to the agent, pinned to its element.
struct VisualFixRequest: Identifiable, Equatable {
    enum State: Equatable {
        /// Waiting for the agent to get to it (it was busy, or is starting).
        case queued
        case working
        /// The agent asked something or needs permission.
        case needsYou
        case done
    }

    let id: Int
    let element: VisualFixElement
    let text: String
    let agent: VerticalTabAgentKind
    let screenshot: String?
    var state: State
    /// Where its element is now, in CSS pixels (nil when it's off the page).
    var rect: CGRect?
    /// How many times the agent has to finish before this request is done: 2 when it
    /// was already busy with something else.
    var finishesLeft: Int
}

/// One tab's Visual Fix panel.
final class VisualFixSession: NSObject, ObservableObject {
    struct Hover: Equatable {
        let label: String
        let rect: CGRect
    }

    weak var controller: BaseTerminalController?
    let webView: WKWebView

    @Published private(set) var url: URL?
    @Published var device: VisualFixDevice = .desktop
    @Published private(set) var picking = true
    @Published private(set) var hover: Hover?
    @Published private(set) var selection: VisualFixElement?
    @Published private(set) var selectionRect: CGRect?
    @Published private(set) var requests: [VisualFixRequest] = []
    @Published private(set) var loading = false
    @Published private(set) var loadError: String?
    @Published private(set) var pageTitle = ""
    /// The request whose change just landed, for a moment (it's highlighted).
    @Published private(set) var justFinished: Int?
    @Published private(set) var sending = false
    /// CSS pixels to points: the page is laid out at the device's width and shown scaled
    /// by this (see `VisualFixWebViewHost`), so small text isn't inflated the way page zoom
    /// would inflate it.
    var zoom: CGFloat = 1

    private var nextNumber = 1
    private var targets: [Int: WeakSurface] = [:]
    private var lastActivity: [ObjectIdentifier: VerticalTabAgentActivity] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private final class WeakSurface {
        weak var surface: Ghostty.SurfaceView?
        init(_ surface: Ghostty.SurfaceView) { self.surface = surface }
    }

    /// Forwards page messages without the page's controller keeping the session alive.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var session: VisualFixSession?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            session?.received(message.body)
        }
    }

    init(controller: BaseTerminalController) {
        self.controller = controller
        let configuration = WKWebViewConfiguration()
        let proxy = MessageProxy()
        configuration.userContentController.add(proxy, contentWorld: .page, name: "gxFix")
        configuration.userContentController.addUserScript(WKUserScript(
            source: VisualFixProbe.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        proxy.session = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let surface = note.object as? Ghostty.SurfaceView else { return }
                self?.agentChanged(surface)
            }
            .store(in: &cancellables)
    }

    // MARK: Page

    func load(_ url: URL) {
        self.url = url
        loadError = nil
        selection = nil
        hover = nil
        webView.load(URLRequest(url: url))
    }

    func reload() {
        guard url != nil else { return }
        loadError = nil
        webView.evaluateJavaScript("window.__gxFix && __gxFix.saveScroll()") { [weak self] _, _ in
            self?.webView.reload()
        }
    }

    func setPicking(_ on: Bool) {
        picking = on
        if !on { hover = nil }
        run("__gxFix.setPicking(\(on))")
    }

    func selectParent() { run("__gxFix.parent()") }

    func cancelSelection() {
        selection = nil
        selectionRect = nil
        run("__gxFix.clear()")
    }

    /// Scrolls a request's element into view.
    func reveal(_ request: VisualFixRequest) {
        run("__gxFix.reveal(\(Self.js(request.element.selector)))")
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript("window.__gxFix && \(script)", completionHandler: nil)
    }

    private func received(_ body: Any) {
        // Only your own app's pages talk to Visual Fix. If the preview follows a link or a
        // login redirect to an outside site, that page gets no say in what's selected.
        guard let url = webView.url, Self.isLocal(url) else { return }
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            pageTitle = message["title"] as? String ?? ""
            // A (re)loaded page starts fresh: restore picking and pins.
            run("__gxFix.setPicking(\(picking))")
            for request in requests where request.state != .done {
                run("__gxFix.pin(\(request.id), \(Self.js(request.element.selector)))")
            }
        case "hover":
            if let rect = VisualFixElement.rect(message["rect"]) {
                hover = Hover(label: message["label"] as? String ?? hover?.label ?? "", rect: rect)
            } else {
                hover = nil
            }
        case "select":
            guard let info = message["info"] as? [String: Any], let element = VisualFixElement(info) else { return }
            selection = element
            selectionRect = element.rect
        case "rects":
            if let rect = VisualFixElement.rect(message["hover"]), let current = hover {
                hover = Hover(label: current.label, rect: rect)
            } else if message["hover"] is NSNull {
                hover = nil
            }
            selectionRect = VisualFixElement.rect(message["selected"])
            let pins = message["pins"] as? [String: Any] ?? [:]
            for index in requests.indices {
                requests[index].rect = VisualFixElement.rect(pins[String(requests[index].id)])
            }
        case "escape":
            if selection != nil { cancelSelection() }
        default:
            break
        }
    }

    // MARK: Sending

    /// The pane whose agent gets the request: an agent (Claude Code or Codex) working in
    /// the previewed app's project, preferring this tab's focused pane, then the rest of this
    /// tab, then other tabs. nil when none is, and a new one starts in the project.
    var targetSurface: Ghostty.SurfaceView? {
        guard let controller else { return nil }
        func hasAgent(_ surface: Ghostty.SurfaceView) -> Bool {
            let kind = VerticalTabsAgents.shared.info(for: surface)?.kind
            return kind == .claude || kind == .codex
        }
        let here = [controller.focusedSurface].compactMap { $0 } + Array(controller.surfaceTree)
        let elsewhere = TerminalWindows.all.filter { $0 !== controller }.flatMap { Array($0.surfaceTree) }
        let agents = (here + elsewhere).filter(hasAgent)
        // Without a known project (an app started outside Tellurion), use this tab's agent.
        guard let root = projectRoot.map(Self.canonical) else { return here.first(where: hasAgent) }
        return agents.first { surface in
            guard let pwd = surface.pwd.map(Self.canonical) else { return false }
            return pwd == root || pwd.hasPrefix(root + "/")
        }
    }

    static func canonical(_ path: String) -> String { ProjectPath.canonical(path) }

    /// The previewed app's project folder (its repository root, or the folder it runs in).
    var projectRoot: String? {
        projectFolder.map { LocalhostProject(folder: $0).root }
    }

    /// The project's name, for saying where requests go.
    var projectName: String? { projectRoot.map { ($0 as NSString).lastPathComponent } }

    /// Whether the agent pane is in another tab than this panel's.
    func isInAnotherTab(_ surface: Ghostty.SurfaceView) -> Bool {
        guard let controller else { return false }
        return !controller.surfaceTree.contains { $0 === surface }
    }

    /// Sends the selected element and `text` to the agent. `newAgent` is the agent to start
    /// when none is running in the tab.
    func send(_ text: String, newAgent: VerticalTabAgentKind) {
        guard let element = selection, let rect = selectionRect, !sending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending = true
        let number = nextNumber
        nextNumber += 1
        screenshot(of: rect, number: number) { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.sending = false
                self.deliver(number: number, element: element, text: trimmed, screenshot: path, newAgent: newAgent)
            }
        }
    }

    @MainActor
    private func deliver(number: Int, element: VisualFixElement, text: String, screenshot: String?, newAgent: VerticalTabAgentKind) {
        guard let controller else { return }
        let target = targetSurface
        let info = target.flatMap { VerticalTabsAgents.shared.info(for: $0) }
        let agent = info?.kind ?? newAgent
        let prompt = Self.prompt(number: number, element: element, text: text, screenshot: screenshot, device: device)
        var surface: Ghostty.SurfaceView?

        if let target, let model = target.surfaceModel {
            // Paste into the running agent and submit; a busy agent queues it.
            model.sendText(prompt)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
            surface = target
        } else if let anchor = controller.focusedSurface,
                  let file = AgentTools.writePrompt(prompt, folder: "visual-fix", name: "\(AgentTools.timestamp())-\(number).md") {
            // Start it in the app's project, so it works on the right code.
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = projectRoot ?? anchor.pwd
            config.initialInput = AgentTools.agentCommand(agent, promptFile: file)
            surface = controller.newSplit(at: anchor, direction: .down, baseConfig: config)
        }

        let busy = info?.activity == .working || info?.activity == .needsPermission
        let request = VisualFixRequest(
            id: number, element: element, text: text, agent: agent, screenshot: screenshot,
            state: busy || info == nil ? .queued : .working, rect: selectionRect, finishesLeft: busy ? 2 : 1)
        if let surface {
            targets[number] = WeakSurface(surface)
            lastActivity[ObjectIdentifier(surface)] = info?.activity
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
            requests.append(request)
            selection = nil
            selectionRect = nil
        }
        run("__gxFix.clear()")
        run("__gxFix.pin(\(number), \(Self.js(element.selector)))")
    }

    /// The folder the previewed app's server runs in.
    private var projectFolder: String? {
        guard let port = url?.port else { return nil }
        if let session = LocalhostSessions.shared.sessions.first(where: { $0.ports.contains(port) }) { return session.cwd }
        return LocalhostSessions.shared.others.first { $0.ports.contains(port) }?.cwd
    }

    static func prompt(number: Int, element: VisualFixElement, text: String, screenshot: String?, device: VisualFixDevice) -> String {
        var attributes = element.attributes.filter { $0.key != "class" }
            .sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value)\"" }.joined()
        if let classes = element.attributes["class"] { attributes = " class=\"\(AgentTools.clip(classes, 120))\"" + attributes }
        var lines = [
            "Visual fix #\(number): I pointed at an element in the running app at \(element.pageURL)"
                + " (\(device.name.lowercased()) layout, \(Int(device.width))px wide).",
            "",
            "Element: <\(element.tag)\(attributes)>" + (element.text.isEmpty ? "" : " \"\(element.text)\""),
            "CSS selector: \(element.selector)",
        ]
        if let path = element.componentPath { lines.append("Rendered by: \(path)" + (element.source.map { " (\($0))" } ?? "")) }
        else if let source = element.source { lines.append("Source: \(source)") }
        let styles = ["size", "font", "color", "background", "padding", "radius"]
            .compactMap { key in element.styles[key].map { "\(key) \($0)" } }
        if !styles.isEmpty { lines.append("Looks like: " + styles.joined(separator: "; ")) }
        if let screenshot { lines.append("Screenshot (element outlined in gold): \(screenshot)") }
        lines += [
            "",
            "Change: \(text)",
            "",
            "Find the code that renders this element and make the change. The dev server reloads on its own, so "
                + "don't restart it. Keep the change to this element unless it clearly needs more.",
        ]
        return lines.joined(separator: "\n")
    }

    /// A picture of the element with some of its surroundings, outlined in gold.
    private func screenshot(of cssRect: CGRect, number: Int, completion: @escaping (String?) -> Void) {
        // The web view's own coordinates are the page's CSS pixels.
        let element = cssRect
        let bounds = webView.bounds
        let area = element.insetBy(dx: -40, dy: -40).intersection(bounds)
        guard !area.isEmpty else { completion(nil); return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = area
        // Retina detail, so small text in the picture stays readable for the agent.
        configuration.snapshotWidth = NSNumber(value: Double(area.width * 2))
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image else { completion(nil); return }
            let outlined = NSImage(size: image.size, flipped: true) { rect in
                image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                let scale = rect.width / area.width
                let box = CGRect(x: (element.minX - area.minX) * scale, y: (element.minY - area.minY) * scale,
                                 width: element.width * scale, height: element.height * scale).insetBy(dx: -2, dy: -2)
                NSColor(red: 0.87, green: 0.72, blue: 0.43, alpha: 1).setStroke()
                let path = NSBezierPath(rect: box)
                path.lineWidth = 3
                path.stroke()
                return true
            }
            guard let tiff = outlined.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { completion(nil); return }
            let dir = AgentTools.root.appendingPathComponent("visual-fix", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(AgentTools.timestamp())-\(number).png")
            completion((try? png.write(to: file)) != nil ? file.path : nil)
        }
    }

    // MARK: Following the agent

    private func agentChanged(_ surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        let activity = VerticalTabsAgents.shared.info(for: surface)?.activity
        let previous = lastActivity[key]
        lastActivity[key] = activity
        guard activity != previous else { return }
        for index in requests.indices where requests[index].state != .done && targets[requests[index].id]?.surface === surface {
            var request = requests[index]
            switch activity {
            case .working, .needsPermission:
                if request.finishesLeft == 1 { request.state = activity == .working ? .working : .needsYou }
            case .needsInput:
                if request.finishesLeft == 1 { request.state = .needsYou }
            case .done, .failed:
                guard previous == .working || previous == .needsPermission || previous == .needsInput else { break }
                request.finishesLeft -= 1
                if request.finishesLeft <= 0 {
                    request.state = .done
                    finished(request)
                }
            default:
                break
            }
            requests[index] = request
        }
    }

    /// The agent is done with a request: show the page as it is now, and mark it for a moment.
    private func finished(_ request: VisualFixRequest) {
        run("__gxFix.unpin(\(request.id))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.reload()
            withAnimation(.easeOut(duration: 0.3)) { self.justFinished = request.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if self.justFinished == request.id { withAnimation(.easeOut(duration: 0.4)) { self.justFinished = nil } }
            }
        }
    }

    func dismiss(_ request: VisualFixRequest) {
        run("__gxFix.unpin(\(request.id))")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { requests.removeAll { $0.id == request.id } }
    }

    /// The pane a request went to, for "Go to agent" and review.
    func surface(for request: VisualFixRequest) -> Ghostty.SurfaceView? { targets[request.id]?.surface }

    private static func js(_ string: String) -> String { EditorWebView.js(string) }
}

extension VisualFixSession {
    /// A dev server on this Mac or the local network: localhost, loopback, private and
    /// link-local addresses, `.local` and `.localhost` names.
    static func isLocal(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host?.lowercased() else { return false }
        if ["localhost", "127.0.0.1", "::1", "0.0.0.0", "[::1]"].contains(host) { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return host.hasPrefix("fe80:") || host.hasPrefix("fd") }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

extension VisualFixSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        loadError = nil
        hover = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        if let current = webView.url, current.host == "localhost" || current.host == "127.0.0.1" { url = current }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        loadError = "Can't reach \(url?.host ?? "the app")\(url?.port.map { ":\($0)" } ?? ""). Is the server running?"
    }
}

// MARK: - Panels

/// The Visual Fix panels, one per terminal tab.
final class VisualFixPanel: ObservableObject {
    static let shared = VisualFixPanel()
    static let widthKey = "VisualFixWidth"
    static let defaultWidth: Double = 760

    @Published private(set) var visibleTabs: Set<ObjectIdentifier> = []
    private var sessions: [ObjectIdentifier: VisualFixSession] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var widened: [ObjectIdentifier: CGFloat] = [:]

    func isVisible(_ controller: BaseTerminalController) -> Bool { visibleTabs.contains(ObjectIdentifier(controller)) }

    func session(for controller: BaseTerminalController) -> VisualFixSession {
        let id = ObjectIdentifier(controller)
        if let session = sessions[id] { return session }
        let session = VisualFixSession(controller: controller)
        sessions[id] = session
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: controller.window)
            .sink { [weak self] _ in
                self?.sessions.removeValue(forKey: id)
                self?.visibleTabs.remove(id)
            }
            .store(in: &cancellables)
        return session
    }

    /// Opens the panel in `controller`'s tab, on `url` or the best running app.
    func show(from controller: BaseTerminalController?, url: URL? = nil) {
        guard ExtremeSettings.isOn(.visualFix) else { return }
        guard let picked = controller ?? Self.frontController else { return }
        let controller = Self.panelTab(for: picked)
        let session = session(for: controller)
        if let url = url ?? (session.url == nil ? Self.bestURL(for: controller) : nil), url != session.url { session.load(url) }
        let id = ObjectIdentifier(controller)
        if !visibleTabs.contains(id), let window = controller.window { widen(window, id: id) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { _ = visibleTabs.insert(id) }
        // Opened from a tool window (like the Localhost manager): bring the tab forward so the
        // panel is seen.
        if let window = controller.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(session.webView)
        }
    }

    func hide(_ controller: BaseTerminalController) {
        let id = ObjectIdentifier(controller)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { _ = visibleTabs.remove(id) }
        if let window = controller.window { narrow(window, id: id) }
        if let surface = controller.focusedSurface { Ghostty.moveFocus(to: surface) }
    }

    func toggle(_ controller: BaseTerminalController?) {
        guard ExtremeSettings.isOn(.visualFix) || controller.map(isVisible) == true else { return }
        guard let controller = controller ?? Self.frontController else { return }
        if isVisible(controller) { hide(controller) } else { show(from: controller) }
    }

    /// The terminal tab in front: the key window's, or else the frontmost tab on screen
    /// (from a tool window like the Localhost manager). A server's own tab is skipped, since
    /// the agent lives elsewhere.
    static var frontController: BaseTerminalController? {
        if let key = EditorPanel.frontController, LocalhostSessions.shared.session(for: key) == nil { return key }
        let onScreen = NSApp.orderedWindows.compactMap { window -> BaseTerminalController? in
            guard window.isVisible, window.tabGroup.map({ $0.selectedWindow === window }) ?? true else { return nil }
            return TerminalWindows.controller(of: window)
        }
        return onScreen.first { LocalhostSessions.shared.session(for: $0) == nil } ?? onScreen.first
            ?? EditorPanel.frontController
    }

    /// Where the panel opens for `controller`: that tab, unless it's a server's own localhost
    /// tab (Fix on its card, or ⌃⌘V while looking at its output). Then it's the tab of an
    /// agent working on the server's project, else that project's tab, else another tab in
    /// front; requests go to the agent, and a new one would otherwise start in the server's tab.
    static func panelTab(for controller: BaseTerminalController) -> BaseTerminalController {
        guard let server = LocalhostSessions.shared.session(for: controller) else { return controller }
        let root = ProjectPath.canonical(server.project.root)
        func inProject(_ surface: Ghostty.SurfaceView) -> Bool {
            guard let pwd = surface.pwd.map(ProjectPath.canonical) else { return false }
            return pwd == root || pwd.hasPrefix(root + "/")
        }
        func hasAgent(_ surface: Ghostty.SurfaceView) -> Bool { VerticalTabsAgents.shared.info(for: surface) != nil }
        // Tabs in the server tab's own window first, so the panel stays where the user is.
        let group = controller.window?.tabGroup?.windows.compactMap { TerminalWindows.controller(of: $0) } ?? []
        let tabs = (group + TerminalWindows.all.filter { tab in !group.contains { $0 === tab } })
            .filter { LocalhostSessions.shared.session(for: $0) == nil }
        return tabs.first { $0.surfaceTree.contains { inProject($0) && hasAgent($0) } }
            ?? tabs.first { $0.surfaceTree.contains(where: inProject) }
            ?? frontController.flatMap { LocalhostSessions.shared.session(for: $0) == nil ? $0 : nil }
            ?? tabs.first
            ?? controller
    }

    /// The live localhost app for this tab's project, or else the most recent one.
    static func bestURL(for controller: BaseTerminalController) -> URL? {
        let live = LocalhostSessions.shared.sessions.filter { $0.state == .live && $0.url != nil }
        if let pwd = controller.focusedSurface?.pwd {
            let root = LocalhostProject(folder: pwd).root
            if let match = live.last(where: { $0.project.root == root }) { return match.url }
        }
        return live.last?.url ?? LocalhostSessions.shared.others.first?.url
    }

    /// Makes room for the panel when the screen has space (single-tab windows only, as tabs
    /// share their window's size).
    private func widen(_ window: NSWindow, id: ObjectIdentifier) {
        guard !window.styleMask.contains(.fullScreen), (window.tabGroup?.windows.count ?? 1) <= 1,
              let screen = window.screen ?? NSScreen.main else { return }
        let panel = CGFloat(UserDefaults.standard.object(forKey: Self.widthKey) as? Double ?? Self.defaultWidth) + 1
        let visible = screen.visibleFrame
        let extra = min(panel, visible.width - window.frame.width)
        guard extra > 0 else { return }
        window.grow(by: extra, onLeft: WindowLayout.isLeftOfTerminal(.visualFix), animate: true)
        widened[id] = extra
    }

    private func narrow(_ window: NSWindow, id: ObjectIdentifier) {
        guard let extra = widened.removeValue(forKey: id), !window.styleMask.contains(.fullScreen) else { return }
        window.grow(by: -extra, onLeft: WindowLayout.isLeftOfTerminal(.visualFix), animate: true)
    }
}
#endif
