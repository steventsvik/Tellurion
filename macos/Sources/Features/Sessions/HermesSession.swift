#if os(macOS)
import AppKit
import Combine
import SwiftUI
import WebKit

/// Runs (or reuses) the local Hermes web server that powers Hermes tabs.
///
/// `hermes dashboard` serves Hermes's own web app — chat (the real Hermes TUI in a web
/// terminal), sessions, skills, models, cron and the rest — on 127.0.0.1. If one is
/// already running it's reused; one started here is stopped when the app quits.
final class HermesServer {
    static let shared = HermesServer()

    private(set) var baseURL = URL(string: "http://127.0.0.1:9119")!
    private var process: Process?
    private var state: State = .idle
    private var waiters: [(Bool) -> Void] = []

    private enum State { case idle, starting, ready, failed }

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.process?.terminate()
        }
    }

    /// Calls back on the main queue with whether the server is reachable.
    func ensureRunning(_ completion: @escaping (Bool) -> Void) {
        switch state {
        case .ready:
            completion(true)
            return
        case .starting:
            waiters.append(completion)
            return
        case .idle, .failed:
            break
        }
        state = .starting
        waiters.append(completion)
        Self.isHermesDashboard(baseURL) { [self] running in
            if running {
                finish(true)
            } else {
                start()
            }
        }
    }

    private func start() {
        let process = Process()
        // A login shell so `hermes` is on PATH even when the app was opened from the Dock.
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec hermes dashboard --no-open --skip-build --port \(baseURL.port ?? 9119)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            finish(false)
            return
        }
        self.process = process
        poll(attempt: 0)
    }

    private func poll(attempt: Int) {
        Self.isHermesDashboard(baseURL) { [self] running in
            if running { finish(true); return }
            guard attempt < 60, process?.isRunning == true else { finish(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.poll(attempt: attempt + 1) }
        }
    }

    private func finish(_ ok: Bool) {
        state = ok ? .ready : .failed
        let callbacks = waiters
        waiters.removeAll()
        callbacks.forEach { $0(ok) }
    }

    /// True if a Hermes dashboard (not some other service) answers at `url`.
    private static func isHermesDashboard(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 &&
                (data.flatMap { String(data: $0, encoding: .utf8) }?.contains("Hermes Agent") ?? false)
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}

/// Tracks which terminals are Hermes sessions (a classic tab, or a tile on a board) and owns
/// each one's web view.
final class HermesSessions: ObservableObject {
    static let shared = HermesSessions()

    /// The terminals showing Hermes, by surface.
    @Published private(set) var tabs: Set<ObjectIdentifier> = []
    private var views: [ObjectIdentifier: HermesWebView] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Ghostty focuses the tab's terminal when a window becomes key; hand the
        // keyboard to Hermes instead when its tab is the one showing.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow,
                      let controller = window.windowController as? TerminalController,
                      let view = self?.view(for: controller) else { return }
                for delay in [0.05, 0.3, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if window.isKeyWindow { window.makeFirstResponder(view) }
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Whether a classic tab is a Hermes session, or on a board, whether the tile with the
    /// cursor is.
    func isHermes(_ controller: BaseTerminalController) -> Bool {
        if controller is BoardController {
            return controller.focusedSurface.map(isHermes(surface:)) ?? false
        }
        return controller.surfaceTree.contains { isHermes(surface: $0) }
    }

    func isHermes(surface: Ghostty.SurfaceView) -> Bool {
        tabs.contains(ObjectIdentifier(surface))
    }

    /// Turns a freshly created terminal into a Hermes session.
    func adopt(_ surface: Ghostty.SurfaceView, in controller: BaseTerminalController) {
        let id = ObjectIdentifier(surface)
        tabs.insert(id)
        views[id] = HermesWebView()
        TerminalWindows.setTitle("Hermes", of: surface)
        VerticalTabsAgents.shared.setStaticAgent(.hermes, task: "Hermes", on: surface)
        // Forget it when it closes, or its window does.
        let forget: () -> Void = { [weak self] in
            self?.tabs.remove(id)
            self?.views.removeValue(forKey: id)
        }
        if let window = controller.window {
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { _ in forget() }
                .store(in: &cancellables)
        }
        controller.$surfaceTree
            .sink { [weak surface] tree in
                guard let surface, !tree.contains(surface) else { return }
                forget()
            }
            .store(in: &cancellables)
        VerticalTabs.setNeedsRefresh()
    }

    func view(for controller: BaseTerminalController) -> HermesWebView? {
        controller.surfaceTree.lazy.compactMap { self.view(for: $0) }.first
    }

    func view(for surface: Ghostty.SurfaceView) -> HermesWebView? {
        views[ObjectIdentifier(surface)]
    }
}

/// Hermes's web app for one tab.
final class HermesWebView: WKWebView {
    @Published private(set) var status: String? = "Starting Hermes…"

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        super.init(frame: .zero, configuration: configuration)
        setValue(false, forKey: "drawsBackground")
        HermesServer.shared.ensureRunning { [weak self] ok in
            guard let self else { return }
            if ok {
                self.status = nil
                self.load(URLRequest(url: HermesServer.shared.baseURL.appendingPathComponent("chat")))
            } else {
                self.status = "Couldn't start Hermes. Check that `hermes dashboard` works in a terminal."
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The Hermes tab's content: Hermes's own UI in place of the terminal.
struct HermesSessionView: View {
    let controller: TerminalController

    var body: some View {
        if let view = HermesSessions.shared.view(for: controller) {
            HermesSessionContent(webView: view)
        }
    }
}

/// Hermes's own UI in place of a terminal (a Hermes tab, or a Hermes tile on a board).
struct HermesSessionContent: View {
    @ObservedObject var webView: HermesWebView

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            HermesWebViewHost(webView: webView)
            if let status = webView.status {
                VStack(spacing: 12) {
                    VerticalTabAgentLogo(kind: .hermes, tint: .primary).frame(width: 44, height: 44)
                    if status.hasPrefix("Starting") { ProgressView().controlSize(.small) }
                    Text(status).foregroundColor(.secondary).font(.system(size: 13))
                }
            }
        }
    }
}

extension HermesWebView: ObservableObject {}

private struct HermesWebViewHost: NSViewRepresentable {
    let webView: HermesWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(webView, to: container)
    }

    private func attach(_ webView: HermesWebView, to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
#endif
