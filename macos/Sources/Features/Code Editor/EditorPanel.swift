#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// The code editor panels. Each terminal tab has its own editor — its own folder, open
/// files and Agent timeline, following only that tab's terminal. Its web view (a whole
/// WebKit page with Monaco) is only created when the editor is first opened; the Agent
/// timeline replays the current turn from the transcript, so opening the editor mid-prompt
/// still shows everything the agent did. Once opened, it keeps following its agent in the
/// background, and is released again when it's closed and the agent has left.
final class EditorPanel: ObservableObject {
    static let shared = EditorPanel()

    static let widthKey = "EditorPanelWidth"
    static let defaultWidth: Double = 720

    /// Tabs whose editor is currently open.
    @Published private(set) var visibleTabs: Set<ObjectIdentifier> = []

    private var sessions: [ObjectIdentifier: EditorSession] = [:]
    /// Terminal colors and font for the editors: nil until first needed, "" while loading.
    private(set) var themeJSON: String?
    private var followTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.themeJSON != nil else { return }
                self.loadTheme()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let controller = TerminalWindows.controller(of: note.object as? NSWindow) else { return }
                self?.sessions[ObjectIdentifier(controller)]?.follow()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let surface = note.object as? Ghostty.SurfaceView { self?.trackAgent(in: surface) }
                self?.followVisible()
            }
            .store(in: &cancellables)
    }

    func isVisible(_ controller: BaseTerminalController) -> Bool {
        visibleTabs.contains(ObjectIdentifier(controller))
    }

    func session(for controller: BaseTerminalController) -> EditorSession {
        let id = ObjectIdentifier(controller)
        if let session = sessions[id] { return session }
        let session = EditorSession(controller: controller)
        sessions[id] = session
        // The editor goes away with its tab.
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: controller.window)
            .sink { [weak self] _ in
                self?.sessions.removeValue(forKey: id)?.close()
                self?.visibleTabs.remove(id)
            }
            .store(in: &cancellables)
        return session
    }

    /// Opens this tab's editor, optionally on a specific folder.
    func show(from controller: BaseTerminalController?, folder: String? = nil) {
        guard ExtremeSettings.isOn(.editor) else { return }
        // Boards are for managing agents; their Agent Map shows where agents are working.
        guard let controller, !HermesSessions.shared.isHermes(controller), !(controller is BoardController) else { return }
        let session = session(for: controller)
        session.show(folder: folder)
        let id = ObjectIdentifier(controller)
        if !visibleTabs.contains(id), let window = controller.window { session.widen(window) }
        visibleTabs.insert(id)
        startFollowing()
        DispatchQueue.main.async { session.webView.focusEditor() }
    }

    func hide(returningFocusTo controller: BaseTerminalController?) {
        guard let controller else { return }
        let id = ObjectIdentifier(controller)
        sessions[id]?.hide()
        visibleTabs.remove(id)
        if let surface = controller.focusedSurface { Ghostty.moveFocus(to: surface) }
    }

    /// An agent's state changed in a pane: an editor that's been opened keeps following it
    /// while closed. Tabs whose editor was never opened get no web view at all.
    private func trackAgent(in surface: Ghostty.SurfaceView) {
        guard let controller = TerminalWindows.controller(of: surface.window),
              let session = sessions[ObjectIdentifier(controller)] else { return }
        guard let info = VerticalTabsAgents.shared.info(for: surface), info.kind != .hermes else {
            session.agentMayHaveLeft()
            return
        }
        guard session.hasWebView else { return }
        session.track()
        startFollowing()
    }

    func toggle(from controller: BaseTerminalController?) {
        // Off in Settings: it can still close, never open.
        guard ExtremeSettings.isOn(.editor) || controller.map(isVisible) == true else { return }
        guard let controller else { return }
        if isVisible(controller) { hide(returningFocusTo: controller) } else { show(from: controller) }
    }

    /// Keeps open editors on their own terminal's folder and agent. Only editors whose
    /// tab is on screen do any work.
    private func startFollowing() {
        guard followTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.followVisible() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func followVisible() {
        let active = sessions.filter { visibleTabs.contains($0.key) || $0.value.isTracking }
        if active.isEmpty {
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        for (id, session) in active {
            if visibleTabs.contains(id) { session.followIfOnScreen() } else { session.follow() }
        }
    }

    /// Terminal colors and font, shared by every editor.
    func loadTheme() {
        themeJSON = themeJSON ?? ""
        EditorTheme.load { [weak self] json in
            guard let self else { return }
            self.themeJSON = json
            self.sessions.values.forEach { $0.applyTheme(json) }
        }
    }

    /// The classic window or board in front, if any.
    static var frontController: BaseTerminalController? {
        TerminalWindows.controller(of: NSApp.keyWindow ?? NSApp.mainWindow)
    }
}

/// One tab's editor: a web view following that tab's terminal pane and its agent.
final class EditorSession {
    private weak var controller: BaseTerminalController?
    private var loadedWebView: EditorWebView?
    /// The editor page, created on first use.
    var webView: EditorWebView {
        if let loadedWebView { return loadedWebView }
        let webView = makeWebView()
        loadedWebView = webView
        return webView
    }
    var hasWebView: Bool { loadedWebView != nil }
    private let feed = AgentFeed()
    /// The tab's other agent panes, each with its own feed (see `followPeers`).
    private var peers: [ObjectIdentifier: Peer] = [:]
    private let watcher = AgentChangeWatcher()
    private var lastStatus: [String: String]?
    private var lastCheckpoints: [UUID] = []
    private var isVisible = false
    /// Following an agent in the background, while the editor is closed.
    private(set) var isTracking = false
    /// Finds the agent's transcript on disk when its hooks didn't say (see `AgentTranscripts`).
    private let transcripts = AgentTranscriptLookup()
    /// The transcript the editor last caught up with, so it only happens once per session.
    private var caughtUp: String?
    /// When the agent was last seen working; changes shortly after still animate.
    private var lastWorking: Date?
    /// How much the window was widened for this editor, so hiding can undo it.
    private var widenedBy: CGFloat = 0

    init(controller: BaseTerminalController) {
        self.controller = controller
        // Following only runs while there's a web view (see `follow`), but never make one here.
        feed.onItems = { [weak self] items, reset in
            guard let self else { return }
            self.loadedWebView?.sendAgentItems(items, reset: reset)
            // A reset clears the whole timeline: play the other agents' recent work again.
            if reset { self.peers.values.forEach { $0.replay() } }
        }
        watcher.onChange = { [weak self] change in
            guard let self else { return }
            self.loadedWebView?.sendAgentChange(change, live: self.agentIsActive)
        }
    }

    private func makeWebView() -> EditorWebView {
        let webView = EditorWebView()
        webView.onFileSaved = { [weak self] path, content in self?.watcher.noteOwnWrite(path: path, content: content) }
        webView.onClose = { [weak self] in EditorPanel.shared.hide(returningFocusTo: self?.controller) }
        webView.onRestore = { [weak self] id in
            guard let surface = self?.agentSurface,
                  let checkpoint = TurnCheckpoints.shared.list(for: surface).first(where: { $0.id.uuidString == id }) else { return }
            TurnCheckpoints.shared.confirmAndRestore(checkpoint, on: surface)
        }
        webView.setPanelVisible(false)
        let panel = EditorPanel.shared
        if let theme = panel.themeJSON {
            // Empty while the theme is still loading; loadTheme applies it when it arrives.
            if !theme.isEmpty { webView.setTheme(theme) }
        } else {
            panel.loadTheme()
        }
        return webView
    }

    func applyTheme(_ json: String) { loadedWebView?.setTheme(json) }

    /// Frees the editor page (its WebKit process and Monaco) while nothing needs it.
    private func releaseWebView() {
        guard !isVisible, let webView = loadedWebView else { return }
        loadedWebView = nil
        caughtUp = nil
        lastCheckpoints = []
        lastStatus = nil
        webView.removeFromSuperview()
        webView.close()
    }

    private var agentIsActive: Bool {
        guard let lastWorking else { return false }
        return Date().timeIntervalSince(lastWorking) < 20
    }

    func show(folder: String?) {
        isVisible = true
        // Catch up again: the agent may have moved on since the editor was last open.
        caughtUp = nil
        if let folder = folder ?? agentSurface?.pwd { webView.openFolder(folder) }
        webView.setPanelVisible(true)
        follow()
    }

    func hide() {
        isVisible = false
        loadedWebView?.setPanelVisible(false)
        caughtUp = nil
        // Keep following an agent in the background so reopening is instant; with no agent,
        // give the memory back.
        if agentSurface.flatMap({ VerticalTabsAgents.shared.info(for: $0) }) != nil {
            isTracking = true
        } else {
            stopFollowing()
            releaseWebView()
        }
        if let window = controller?.window { narrow(window) }
    }

    /// Starts following this tab's agent in the background.
    func track() {
        guard !isTracking else { return }
        isTracking = true
        follow()
    }

    /// The agent may have exited: stop background work once no pane has one.
    func agentMayHaveLeft() {
        guard !isVisible, agentSurface.flatMap({ VerticalTabsAgents.shared.info(for: $0) }) == nil else { return }
        stopFollowing()
        releaseWebView()
    }

    private func stopFollowing() {
        isTracking = false
        feed.stop()
        peers.values.forEach { $0.feed.stop() }
        peers.removeAll()
        watcher.stop()
        lastStatus = nil
        transcripts.reset()
    }

    func close() {
        feed.stop()
        peers.values.forEach { $0.feed.stop() }
        peers.removeAll()
        watcher.stop()
        loadedWebView?.close()
        loadedWebView = nil
    }

    func followIfOnScreen() {
        guard let window = controller?.window, window.occlusionState.contains(.visible) else { return }
        follow()
    }

    /// The tab's agent panes in split order, at most four (Hermes shows its own app). On a
    /// board, the tile with the cursor comes first, so the editor follows the agent you're in.
    private var agentSurfaces: [Ghostty.SurfaceView] {
        guard let controller else { return [] }
        var agents = controller.surfaceTree.filter {
            guard let info = VerticalTabsAgents.shared.info(for: $0) else { return false }
            return info.kind != .hermes
        }
        if let board = controller as? BoardController, let focused = board.focusedSurface ?? board.model.focused?.value,
           let index = agents.firstIndex(where: { $0 === focused }) {
            agents.insert(agents.remove(at: index), at: 0)
        }
        return Array(agents.prefix(4))
    }

    /// The main pane to follow: the first agent pane, so focusing another one doesn't
    /// restart the timeline. With one agent that's the one; the others follow as peers.
    private var agentSurface: Ghostty.SurfaceView? {
        guard let controller else { return nil }
        return agentSurfaces.first ?? controller.focusedSurface
    }

    /// Shows this tab's agent pane: its folder in the Explorer, its agent in the panel.
    func follow() {
        guard isVisible || isTracking, hasWebView, let surface = agentSurface else { return }
        if let pwd = surface.pwd, pwd != webView.currentFolder { webView.openFolder(pwd) }

        let info = VerticalTabsAgents.shared.info(for: surface)
        let transcriptPath = info.flatMap { transcripts.transcript(for: $0, in: surface.pwd) }
        if let info, let path = transcriptPath { feed.follow(path: path, kind: info.kind) }
        if let info, info.kind != .hermes, let pwd = surface.pwd {
            if info.activity == .working || info.activity == .needsPermission { lastWorking = Date() }
            let repo = VerticalTabsGit.repoRoot(containing: pwd)?.path
            watcher.watch(folder: pwd, repoRoot: repo, baseline: ReviewInbox.shared.baseline(for: surface))
            // Opened mid-session: show what the agent has changed so far.
            let session = transcriptPath ?? pwd
            if isVisible, caughtUp != session {
                caughtUp = session
                watcher.catchUp { [weak self] changes in
                    guard !changes.isEmpty else { return }
                    self?.webView.sendAgentCatchUp(changes)
                }
            }
        }
        var status: [String: String]?
        if let info {
            status = [
                "kind": info.localModel != nil ? "local" : info.kind.rawValue,
                "name": info.name,
                "activity": info.activity.label,
                "badge": String(describing: info.activity.badge),
                "task": info.task ?? "",
                "detail": info.detail ?? "",
                "live": transcriptPath == nil ? "no" : "yes",
            ]
        }
        sendCheckpoints(for: surface)
        followPeers(main: surface)
        guard status != lastStatus else { return }
        lastStatus = status
        webView.sendAgentStatus(status)
    }

    /// Another agent in the same tab: its timeline joins the main one as its own lane, so the
    /// map shows it as its own comet and the editor splits to show each agent's code side by
    /// side, at equal size.
    private final class Peer {
        let feed = AgentFeed()
        var name = ""
        var kind = ""
        private var path: String?
        private var agentKind: VerticalTabAgentKind = .unknown

        func follow(path: String, kind: VerticalTabAgentKind) {
            self.path = path
            agentKind = kind
            feed.follow(path: path, kind: kind)
        }

        /// Sends its recent work again (after the main timeline was cleared).
        func replay() {
            guard let path else { return }
            feed.stop()
            feed.follow(path: path, kind: agentKind)
        }
    }

    private func followPeers(main: Ghostty.SurfaceView) {
        let others = agentSurfaces.filter { $0 !== main }
        let keep = Set(others.map(ObjectIdentifier.init))
        for (id, peer) in peers where !keep.contains(id) {
            peer.feed.stop()
            peers.removeValue(forKey: id)
        }
        for surface in others {
            guard let info = VerticalTabsAgents.shared.info(for: surface), let path = info.transcriptPath else { continue }
            let id = ObjectIdentifier(surface)
            let peer = peers[id] ?? {
                let peer = Peer()
                peer.feed.onItems = { [weak self, weak peer] items, _ in
                    guard let self, let peer else { return }
                    // Its items are tagged so the page gives it its own lane, named and colored
                    // after the agent; its sub-agents become lanes of their own under its name.
                    let tagged: [AgentFeed.Item] = items.map { item in
                        var item = item
                        let sub = item["sub"] as? String
                        item["sub"] = sub.map { "\(peer.name) · \($0)" } ?? peer.name
                        item["peer"] = peer.name
                        item["peerKind"] = peer.kind
                        return item
                    }
                    // Never a reset: that would clear the main agent's timeline.
                    self.loadedWebView?.sendAgentItems(tagged, reset: false)
                }
                peers[id] = peer
                return peer
            }()
            peer.name = Self.peerName(info, among: others.compactMap { VerticalTabsAgents.shared.info(for: $0) }, main: main)
            peer.kind = info.localModel != nil ? "local" : info.kind.rawValue
            if peer.feed.path != path { peer.follow(path: path, kind: info.kind) }
        }
    }

    /// The agent's name, numbered when two panes run the same one ("Claude Code 2").
    private static func peerName(_ info: VerticalTabAgentInfo, among others: [VerticalTabAgentInfo],
                                 main: Ghostty.SurfaceView) -> String {
        let mainName = VerticalTabsAgents.shared.info(for: main)?.name
        let same = others.filter { $0.name == info.name }
        guard same.count > 1 || mainName == info.name else { return info.name }
        let index = (same.firstIndex { $0.transcriptPath == info.transcriptPath } ?? 0) + (mainName == info.name ? 2 : 1)
        return "\(info.name) \(index)"
    }

    /// Lets the timeline offer "Restore to before this" on each prompt that has a checkpoint.
    private func sendCheckpoints(for surface: Ghostty.SurfaceView) {
        let turns = TurnCheckpoints.shared.list(for: surface).filter { !$0.isRestorePoint }
        guard turns.map(\.id) != lastCheckpoints else { return }
        lastCheckpoints = turns.map(\.id)
        webView.sendCheckpoints(turns.map {
            ["id": $0.id.uuidString, "time": Int($0.time.timeIntervalSince1970 * 1000), "title": $0.title]
        })
    }

    /// Makes room for the panel when the screen has space. Tabs share their window's
    /// size, so this only happens for a window with a single tab.
    func widen(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), (window.tabGroup?.windows.count ?? 1) <= 1,
              let screen = window.screen ?? NSScreen.main else { return }
        let panel = CGFloat(UserDefaults.standard.object(forKey: EditorPanel.widthKey) as? Double ?? EditorPanel.defaultWidth) + 1
        let visible = screen.visibleFrame
        let extra = min(panel, visible.width - window.frame.width)
        guard extra > 0 else { return }
        window.grow(by: extra, onLeft: WindowLayout.isLeftOfTerminal(.editor), animate: true)
        widenedBy = extra
    }

    private func narrow(_ window: NSWindow) {
        guard widenedBy > 0, !window.styleMask.contains(.fullScreen) else { widenedBy = 0; return }
        window.grow(by: -widenedBy, onLeft: WindowLayout.isLeftOfTerminal(.editor), animate: true)
        widenedBy = 0
    }
}

/// A tab's editor as placed in its window's layout: a resize handle and its web view.
struct EditorPanelColumn: View {
    let controller: BaseTerminalController
    /// The most room the window has for the editor right now.
    var maxWidth: CGFloat = .infinity
    @AppStorage(EditorPanel.widthKey) private var width: Double = EditorPanel.defaultWidth
    @ObservedObject private var layout = WindowLayout.shared

    var body: some View {
        // The handle is on the side facing the terminal.
        let left = layout.isLeftOfTerminal(.editor)
        let handle = ColumnResizeHandle(color: Color.primary.opacity(0.1), width: $width,
                                        range: 320...max(320, min(1600, Double(maxWidth))), onTrailingEdge: left)
        HStack(spacing: 0) {
            if !left { handle }
            EditorWebViewHost(webView: EditorPanel.shared.session(for: controller).webView)
                .frame(width: min(CGFloat(width), maxWidth))
            if left { handle }
        }
    }
}

/// Hosts one tab's editor web view.
private struct EditorWebViewHost: NSViewRepresentable {
    let webView: EditorWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }

    private func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

// MARK: - Menu

extension EditorPanel {
    /// Adds "Open Code Editor" / "Close Code Editor" (⌃⌘E) to the View menu.
    static func installMenuItem(in menu: NSMenu, at index: Int) {
        let item = NSMenuItem(title: "Open Code Editor", action: #selector(EditorMenuTarget.toggle(_:)), keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = EditorMenuTarget.shared
        menu.insertItem(item, at: index)
    }
}

final class EditorMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = EditorMenuTarget()

    @objc func toggle(_ sender: Any?) {
        EditorPanel.shared.toggle(from: EditorPanel.frontController)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = EditorPanel.frontController, !(controller is BoardController) else { return false }
        let open = EditorPanel.shared.isVisible(controller)
        menuItem.title = open ? "Close Code Editor" : "Open Code Editor"
        menuItem.state = .off
        // Hermes tabs show Hermes's own app; there's no terminal folder to edit.
        return !HermesSessions.shared.isHermes(controller)
    }
}
#endif
