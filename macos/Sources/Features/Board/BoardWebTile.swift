#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// A browser on the board: tabs, back and forward, an address bar, and a start page listing
/// the localhost servers running now. Its size can be set to a real screen or phone (the page
/// lays out at that size), and {} opens Web Inspector.
///
/// Sandboxed: web tiles keep their cookies and storage in a store of their own (not Safari's,
/// not the app's other web views), the page gets no bridge into the app, downloads are
/// refused, links that open new windows stay in the tile, and camera and microphone are
/// denied.
enum BoardWeb {
    static let size = CGSize(width: 900, height: 620)
    /// Web Inspector's panel under the page.
    static let inspector: CGFloat = 380
    /// The tile's chrome above the page: title bar, tabs and the address row.
    static let chrome: CGFloat = BoardNodeView.header + 30 + 34

    /// Viewports a tile can take: displays and phones, at their CSS sizes.
    static let viewports: [(group: String, name: String, size: CGSize)] = [
        ("Displays", "24 in monitor", CGSize(width: 1920, height: 1080)),
        ("Displays", "27 in monitor", CGSize(width: 2560, height: 1440)),
        ("Displays", "32 in 4K", CGSize(width: 3840, height: 2160)),
        ("Phones", "iPhone SE", CGSize(width: 375, height: 667)),
        ("Phones", "iPhone 14 Pro", CGSize(width: 393, height: 852)),
        ("Phones", "iPhone 14 Pro Max", CGSize(width: 430, height: 932)),
        ("Phones", "Pixel 7", CGSize(width: 412, height: 915)),
        ("Phones", "Galaxy S8+", CGSize(width: 360, height: 740)),
    ]

    static let quickOpen: [(name: String, url: String)] = [
        ("Google", "https://www.google.com"), ("GitHub", "https://github.com"), ("YouTube", "https://www.youtube.com"),
        ("MDN", "https://developer.mozilla.org"), ("npm", "https://www.npmjs.com"), ("Hacker News", "https://news.ycombinator.com"),
    ]

    /// One store for every web tile, kept between launches where macOS allows it.
    static let store: WKWebsiteDataStore = {
        if #available(macOS 14.0, *) {
            // A fixed id: the same store each launch, apart from every other web view.
            return WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6B1C2D9E-7A51-4E3B-9C0D-5F2A8E41B7D3")!)
        }
        return .nonPersistent()
    }()

    /// What a typed address means: a URL, a host ("localhost:3000"), or a search.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return url }
        if text.hasPrefix(":"), let port = Int(text.dropFirst()) { return URL(string: "http://localhost:\(port)") }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
        if !text.contains(" "), text.contains(".") || local {
            return URL(string: (local ? "http://" : "https://") + text)
        }
        var search = URLComponents(string: "https://www.google.com/search")
        search?.queryItems = [URLQueryItem(name: "q", value: text)]
        return search?.url
    }

    /// Local ports something is listening on, for the start page.
    static func livePorts() -> [Int] {
        let wanted = [3000, 3001, 4200, 5173, 8000, 8080]
        let open = Set(ProcessProbe.listeners().map(\.port))
        return wanted.filter(open.contains) + open.filter { !wanted.contains($0) && $0 >= 1024 && $0 < 10000 }.sorted().prefix(6)
    }

    /// The start page: "Open a page", live localhost ports, quick links. Plain HTML, no script.
    static func startPage(ports: [Int]) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        let chips = [3000, 3001, 4200, 5173, 8000, 8080].map { port in
            "<a class=\"chip\(ports.contains(port) ? " live" : "")\" href=\"http://localhost:\(port)/\">:\(port)</a>"
        } + ports.filter { ![3000, 3001, 4200, 5173, 8000, 8080].contains($0) }.map { port in
            "<a class=\"chip live\" href=\"http://localhost:\(port)/\">:\(port)</a>"
        }
        let quick = quickOpen.map { site in
            let host = URL(string: site.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
            return "<a class=\"site\" href=\"\(site.url)\"><b>\(escape(site.name))</b><span>\(escape(host))</span></a>"
        }.joined()
        let status = ports.isEmpty ? "<span class=\"dim\">none running</span>" : "<span class=\"ok\">● \(ports.count) live</span>"
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: dark; }
        body { margin: 0; background: #161514; color: #ece8e1; font: 13px -apple-system, system-ui; display: flex; justify-content: center; }
        main { width: min(520px, 90vw); padding: 48px 0; }
        h1 { font-size: 22px; font-weight: 650; margin: 0 0 26px; }
        h2 { font-size: 10.5px; letter-spacing: .08em; color: #8b867f; margin: 26px 0 10px; display: flex; justify-content: space-between; }
        .ok { color: #6fcf7f; letter-spacing: 0; } .dim { color: #6d6862; letter-spacing: 0; }
        .chips { display: flex; flex-wrap: wrap; gap: 8px; }
        .chip { padding: 6px 12px; border-radius: 999px; background: #232120; color: #b9b4ad; text-decoration: none; font: 12px ui-monospace, monospace; border: 1px solid #2e2b29; }
        .chip.live { color: #ece8e1; border-color: #3f6e47; }
        .chip.live::before { content: "● "; color: #6fcf7f; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
        .site { padding: 12px 14px; border-radius: 12px; background: #1f1d1c; border: 1px solid #2a2725; text-decoration: none; color: #ece8e1; display: flex; flex-direction: column; gap: 2px; }
        .site span { color: #8b867f; font-size: 11.5px; }
        .site:hover, .chip:hover { border-color: #f2602b; }
        p { color: #6d6862; margin-top: 26px; text-align: center; }
        </style></head><body><main>
        <h1>Open a page</h1>
        <h2><span>LOCALHOST</span>\(status)</h2>
        <div class="chips">\(chips.joined())</div>
        <h2><span>QUICK OPEN</span></h2>
        <div class="grid">\(quick)</div>
        <p>or type any address in the bar above</p>
        </main></body></html>
        """
    }
}

extension BoardController {
    /// A web tile around a board point (from the radial menu).
    func addWebTile(at point: CGPoint, url: String? = nil) {
        let id = addCard(.web, at: point, edit: false)
        updateCard(id) { card in
            card.tabs = [url ?? ""]
            card.tab = 0
        }
    }

    /// A web tile of a box dragged out with the web tool.
    func finishWebBox(from start: CGPoint, to end: CGPoint) {
        hideWebBox()
        model.tool = .select
        var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        // A click (or a tiny box): the usual size around it.
        if rect.width < 160 || rect.height < 120 {
            rect = CGRect(x: start.x - BoardWeb.size.width / 2, y: start.y - BoardWeb.size.height / 2,
                          width: BoardWeb.size.width, height: BoardWeb.size.height)
        }
        let id = addCard(.web, at: CGPoint(x: rect.midX, y: rect.midY), edit: false)
        model.frames[id] = rect
        updateCard(id) { card in
            card.tabs = [""]
            card.tab = 0
            card.frame = rect
        }
    }

    /// The dashed box while one is dragged out.
    func showWebBox(from start: CGPoint, to end: CGPoint) {
        groupsView?.showGuides([])
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        groupsView?.showBox(rect)
    }

    func hideWebBox() { groupsView?.showBox(nil) }

    /// The canvas's full menu, at a board point ("More" in the radial menu).
    func showCanvasMenu(at point: CGPoint) {
        guard let window, let view = window.contentView else { return }
        let menu = BoardDocumentView.canvasMenu(self, at: point)
        let at = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: at, in: view)
    }
}

/// What a web tile shows under its title bar: tabs, the address row, and the page.
final class WebContent: CardContent, WKNavigationDelegate, WKUIDelegate {
    private let state = WebTileState()
    private var chrome: NSView?
    /// One web view per tab; only the current one is shown.
    private var pages: [WKWebView] = []
    private var observations: [NSKeyValueObservation] = []
    private var applied: [String] = []

    override func apply(_ card: BoardCard) {
        attach()
        let tabs = card.tabs ?? [""]
        // Pages follow the card's tabs (added, closed); a page navigates on its own.
        while pages.count < tabs.count { pages.append(makePage()) }
        while pages.count > tabs.count { pages.removeLast().superview?.removeFromSuperview() }
        for (index, url) in tabs.enumerated() where index >= applied.count || applied[index] != url {
            load(url, in: pages[index])
        }
        applied = tabs
        state.tabs = tabs.indices.map { index in pages[index].title.flatMap { $0.isEmpty ? nil : $0 } ?? title(of: tabs[index]) }
        state.tab = min(card.tab ?? 0, max(tabs.count - 1, 0))
        state.viewport = card.viewport
        for (index, page) in pages.enumerated() { page.superview?.isHidden = index != state.tab }
        sync()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        chrome?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: BoardWeb.chrome - BoardNodeView.header)
        let top = BoardWeb.chrome - BoardNodeView.header
        // Each page sits in its own unflipped box, where WebKit docks the inspector under it.
        for page in pages { page.superview?.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top)) }
    }

    /// WebKit's docked inspector, when it's open.
    private var inspectorView: NSView? {
        current?.superview?.subviews.first { String(describing: type(of: $0)).contains("Inspector") }
    }

    override func beginTyping() {
        if let field = descendants.compactMap({ $0 as? NSTextField }).first(where: \.isEditable) { window?.makeFirstResponder(field) }
    }

    private var current: WKWebView? { pages.indices.contains(state.tab) ? pages[state.tab] : nil }

    private func attach() {
        guard chrome == nil, let board else { return }
        let host = NSHostingView(rootView: WebTileChrome(state: state, actions: WebTileActions(
            back: { [weak self] in self?.current?.goBack() },
            forward: { [weak self] in self?.current?.goForward() },
            reload: { [weak self] in
                guard let page = self?.current else { return }
                if page.isLoading { page.stopLoading() } else if page.url == nil { self?.showStart(in: page) } else { page.reload() }
            },
            go: { [weak self] text in self?.go(text) },
            select: { [weak self] index in board.updateCard(self?.cardID ?? UUID()) { $0.tab = index } },
            newTab: { [weak self] in
                board.updateCard(self?.cardID ?? UUID()) { card in
                    card.tabs = (card.tabs ?? [""]) + [""]
                    card.tab = (card.tabs?.count ?? 1) - 1
                }
            },
            closeTab: { [weak self] index in
                board.updateCard(self?.cardID ?? UUID()) { card in
                    var tabs = card.tabs ?? [""]
                    guard tabs.count > 1, tabs.indices.contains(index) else { return }
                    tabs.remove(at: index)
                    card.tabs = tabs
                    card.tab = min(card.tab ?? 0, tabs.count - 1)
                }
            },
            inspect: { [weak self] in self?.inspect() },
            viewport: { [weak self] name in self?.setViewport(name) })))
        host.sizingOptions = []
        addSubview(host)
        chrome = host
    }

    private func makePage() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BoardWeb.store
        // No script message handlers: the page can't reach the app.
        configuration.userContentController = WKUserContentController()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.navigationDelegate = self
        page.uiDelegate = self
        page.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { page.isInspectable = true }
        let box = NSView()
        box.autoresizesSubviews = true
        page.frame = box.bounds
        page.autoresizingMask = [.width, .height]
        box.addSubview(page)
        addSubview(box, positioned: .below, relativeTo: chrome)
        observations.append(page.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.sync() }
        })
        observations.append(page.observe(\.title, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.titleChanged() }
        })
        observations.append(page.observe(\.url, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.urlChanged(page) }
        })
        return page
    }

    private func load(_ url: String, in page: WKWebView) {
        if let target = URL(string: url), url.hasPrefix("http") {
            if page.url != target { page.load(URLRequest(url: target)) }
        } else {
            showStart(in: page)
        }
    }

    private func showStart(in page: WKWebView) {
        DispatchQueue.global(qos: .userInitiated).async {
            let html = BoardWeb.startPage(ports: BoardWeb.livePorts())
            DispatchQueue.main.async { page.loadHTMLString(html, baseURL: nil) }
        }
    }

    private func go(_ text: String) {
        guard let url = BoardWeb.url(from: text), let board else { return }
        let index = state.tab
        board.updateCard(cardID) { card in
            var tabs = card.tabs ?? [""]
            if tabs.indices.contains(index) { tabs[index] = url.absoluteString } else { tabs.append(url.absoluteString) }
            card.tabs = tabs
        }
        current?.load(URLRequest(url: url))
        window?.makeFirstResponder(current)
    }

    private func title(of url: String) -> String {
        URL(string: url)?.host ?? "New tab"
    }

    /// The page's own address changed (a link, a redirect): the tab remembers it.
    private func urlChanged(_ page: WKWebView) {
        guard let board, let index = pages.firstIndex(of: page), let url = page.url?.absoluteString, url.hasPrefix("http") else { return }
        sync()
        if applied.indices.contains(index) { applied[index] = url }
        board.updateCard(cardID) { card in
            var tabs = card.tabs ?? [""]
            guard tabs.indices.contains(index), tabs[index] != url else { return }
            tabs[index] = url
            card.tabs = tabs
        }
    }

    private func titleChanged() {
        state.tabs = pages.indices.map { index in
            pages[index].title.flatMap { $0.isEmpty ? nil : $0 } ?? title(of: applied.indices.contains(index) ? applied[index] : "")
        }
        if let title = current?.title, !title.isEmpty {
            board?.updateCard(cardID) { $0.title = title }
        }
    }

    private func sync() {
        guard let page = current else { return }
        let address = page.url?.absoluteString ?? ""
        if state.address != address, !state.editing { state.address = address.hasPrefix("http") ? address : "" }
        state.progress = page.isLoading ? page.estimatedProgress : 0
        state.loading = page.isLoading
        state.canGoBack = page.canGoBack
        state.canGoForward = page.canGoForward
    }

    /// A viewport preset: the tile takes that size (plus its chrome), or fits again.
    func setViewport(_ name: String?) {
        guard let board, var frame = board.model.frames[cardID] else { return }
        if let name, let preset = BoardWeb.viewports.first(where: { $0.name == name }) {
            frame.size = CGSize(width: preset.size.width, height: preset.size.height + BoardWeb.chrome)
        } else {
            frame.size = BoardWeb.size
        }
        board.setFrames([cardID: frame], animated: true, undoAction: "Viewport")
        board.updateCard(cardID) { $0.viewport = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { board.zoom(toNode: self.cardID) }
    }

    /// Web Inspector for the page.
    func inspect() {
        guard let page = current, let board else { return }
        // WebKit's own inspector, docked in the tile, which grows to make room for it.
        guard let inspector = page.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: Selector(("show"))), inspector.responds(to: Selector(("close"))) else {
            NSSound.beep()
            return
        }
        let open = inspectorView != nil
        if var frame = board.model.frames[cardID] {
            frame.size.height = max(BoardWeb.size.height, frame.height + (open ? -BoardWeb.inspector : BoardWeb.inspector))
            board.setFrames([cardID: frame], animated: true, undoAction: nil)
        }
        inspector.perform(Selector((open ? "close" : "show")))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.needsLayout = true }
    }

    // MARK: Sandbox

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob"].contains(scheme) || action.request.url == nil {
            decisionHandler(action.shouldPerformDownload ? .cancel : .allow)
            return
        }
        // mailto:, other apps' links and files: not in a tile.
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // What the page can't show would be a download: refused.
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A new window opens in this tab instead.
        if let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { sync() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync() }
}

final class WebTileState: ObservableObject {
    @Published var tabs: [String] = []
    @Published var tab = 0
    @Published var address = ""
    @Published var editing = false
    @Published var progress: Double = 0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var viewport: String?
}

struct WebTileActions {
    let back: () -> Void
    let forward: () -> Void
    let reload: () -> Void
    let go: (String) -> Void
    let select: (Int) -> Void
    let newTab: () -> Void
    let closeTab: (Int) -> Void
    let inspect: () -> Void
    let viewport: (String?) -> Void
}

/// The tabs and the address row.
private struct WebTileChrome: View {
    @ObservedObject var state: WebTileState
    let actions: WebTileActions
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(state.tabs.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        Text(state.tabs[index]).font(Extreme.font(11, weight: index == state.tab ? .semibold : .regular))
                            .foregroundColor(index == state.tab ? Extreme.text : Extreme.muted).lineLimit(1)
                        if state.tabs.count > 1 {
                            Button { actions.closeTab(index) } label: {
                                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundColor(Extreme.dim)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9).frame(maxWidth: 180).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(index == state.tab ? Extreme.raised : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { actions.select(index) }
                }
                Button(action: actions.newTab) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundColor(Extreme.muted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New tab")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 30)
            HStack(spacing: 6) {
                navButton("chevron.left", "Back", enabled: state.canGoBack, action: actions.back)
                navButton("chevron.right", "Forward", enabled: state.canGoForward, action: actions.forward)
                navButton(state.loading ? "xmark" : "arrow.clockwise", state.loading ? "Stop" : "Reload", enabled: true, action: actions.reload)
                TextField("localhost:3000 · url", text: $typed, onEditingChanged: { editing in
                    state.editing = editing
                    if editing { typed = state.address }
                }, onCommit: {
                    actions.go(typed)
                })
                .textFieldStyle(.plain)
                .font(Extreme.font(12))
                .foregroundColor(Extreme.text)
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.ink))
                .onChange(of: state.address) { address in if !state.editing { typed = address } }
                if let viewport = state.viewport {
                    Text(viewport).font(Extreme.font(10.5, weight: .semibold)).foregroundColor(Extreme.core)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Extreme.core.opacity(0.14)))
                        .lineLimit(1).fixedSize()
                }
                Menu {
                    Button("Fit Tile") { actions.viewport(nil) }
                    Divider()
                    ForEach(["Displays", "Phones"], id: \.self) { group in
                        Section(group) {
                            ForEach(BoardWeb.viewports.filter { $0.group == group }, id: \.name) { preset in
                                Button("\(preset.name)   \(Int(preset.size.width)) × \(Int(preset.size.height))") { actions.viewport(preset.name) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "display").font(.system(size: 11)).foregroundColor(Extreme.muted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Viewport")
                navButton("curlybraces", "Web Inspector", enabled: true, action: actions.inspect)
            }
            .padding(.horizontal, 8).frame(height: 34)
            // The load bar.
            GeometryReader { geo in
                Rectangle().fill(Extreme.core).frame(width: geo.size.width * state.progress, height: 2)
                    .opacity(state.loading ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: state.progress)
            }
            .frame(height: 0)
        }
        .background(Extreme.panel)
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(enabled ? Extreme.text.opacity(0.85) : Extreme.dim)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif
