#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import WebKit

/// The web view hosting the VS Code–style editor (macos/EditorWeb, built on Monaco).
///
/// One instance is shared by the whole app and moved into whichever window shows the
/// editor panel. It runs in WebKit's own process and is only created the first time the
/// panel opens, so the terminal pays nothing for it otherwise.
final class EditorWebView: WKWebView {
    static let scheme = "ghostty-editor"

    private let files = EditorFileBridge()
    private let navigationGuard = EditorNavigationGuard()
    private(set) var isReady = false
    /// Called (on a background queue) after the editor saves a file.
    var onFileSaved: ((String, String) -> Void)?
    /// Called when the page's close button is clicked.
    var onClose: (() -> Void)?
    /// Called with a checkpoint's id when "Restore to before this" is clicked in the timeline.
    var onRestore: ((String) -> Void)?
    private var pending: [String] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EditorAssetHandler(), forURLScheme: Self.scheme)
        // The editor's page has a bridge to your files: it must only ever show its own pages.
        super.init(frame: .zero, configuration: configuration)
        configuration.userContentController.addScriptMessageHandler(files, contentWorld: .page, name: "fs")
        files.onReady = { [weak self] in self?.didBecomeReady() }
        files.onWrite = { [weak self] path, content in self?.onFileSaved?(path, content) }
        files.onBrowser = { [weak self] body in self?.povBrowser(body) }
        files.onClose = { [weak self] in self?.onClose?() }
        files.onRestore = { [weak self] id in self?.onRestore?(id) }
        uiDelegate = self
        navigationDelegate = navigationGuard
        setValue(false, forKey: "drawsBackground")
        load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Stops the page and lets WebKit release it (and its web content process).
    func close() {
        stopLoading()
        configuration.userContentController.removeAllScriptMessageHandlers()
        pending.removeAll()
        onFileSaved = nil
        onClose = nil
        onRestore = nil
    }

    // MARK: Commands from the app

    /// The folder shown in the Explorer.
    var currentFolder: String? { files.root }

    func openFolder(_ path: String) {
        let root = (path as NSString).standardizingPath
        guard root != files.root else { return }
        files.root = root
        files.allowedRoots.insert(root)
        let branch = Self.branch(of: root) ?? ""
        run("app.openFolder(\(Self.js(root)), \(Self.js((root as NSString).lastPathComponent)), \(Self.js(branch)))")
    }

    func openFile(_ path: String, line: Int? = nil) {
        if files.root == nil { openFolder((path as NSString).deletingLastPathComponent) }
        run("app.openFile(\(Self.js(path)), \(line.map(String.init) ?? "undefined"))")
    }

    /// Whether the panel is on screen. While it isn't, the page only records what the agent
    /// does; when it appears, it reveals the agent's latest work.
    func setPanelVisible(_ visible: Bool) {
        run("app.setVisible(\(visible))")
    }

    func focusEditor() {
        window?.makeFirstResponder(self)
        run("app.focus()")
    }

    private func run(_ script: String) {
        if isReady { evaluateJavaScript(script) } else { pending.append(script) }
    }

    private func didBecomeReady() {
        isReady = true
        pending.forEach { evaluateJavaScript($0) }
        pending.removeAll()
    }

    // MARK: Keyboard

    /// Command-key shortcuts normally go to the app's menus first (⌘W would close the
    /// terminal tab). While the editor has focus, send them to the page instead so VS Code
    /// shortcuts work. App-level shortcuts and the clipboard (handled through the Edit
    /// menu, which WebKit supports) still go to the app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder === self || responder.isDescendant(of: self),
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let appLevel: Set<String> = ["q", "h", "t", "n", ",", "`", "c", "v", "x", "a", "m"]
        if flags.contains(.control) || appLevel.contains(key) {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    /// Streams the agent timeline to the page. Files the agent touches become readable
    /// so follow mode can open them even outside the Explorer's folder.
    func sendAgentItems(_ items: [AgentFeed.Item], reset: Bool) {
        for item in items {
            if let path = item["path"] as? String, path.hasPrefix("/") {
                files.allowedFiles.insert((path as NSString).standardizingPath)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        run("app.agentItems(\(json), \(reset))")
    }

    /// A file the agent changed on disk, with exactly which lines (see `AgentChangeWatcher`).
    /// `live` is false when no agent is working, so the page updates without animating.
    func sendAgentChange(_ change: AgentChangeWatcher.Change, live: Bool) {
        files.allowedFiles.insert((change.path as NSString).standardizingPath)
        var json = change.json
        json["live"] = live
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        run("app.agentChange(\(text))")
    }

    /// Everything the agent has changed so far this turn, for an editor opened mid-prompt.
    func sendAgentCatchUp(_ changes: [AgentChangeWatcher.Change]) {
        changes.forEach { files.allowedFiles.insert(($0.path as NSString).standardizingPath) }
        guard let data = try? JSONSerialization.data(withJSONObject: changes.prefix(60).map(\.json)),
              let text = String(data: data, encoding: .utf8) else { return }
        run("app.agentCatchUp(\(text))")
    }

    /// The turns that can be restored, for the timeline's prompts: [{id, time (ms), title}].
    func sendCheckpoints(_ checkpoints: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: checkpoints),
              let json = String(data: data, encoding: .utf8) else { return }
        run("app.setCheckpoints(\(json))")
    }

    func sendAgentStatus(_ status: [String: Any]?) {
        guard let status else { run("app.agentStatus(null)"); return }
        guard let data = try? JSONSerialization.data(withJSONObject: status),
              let json = String(data: data, encoding: .utf8) else { return }
        run("app.agentStatus(\(json))")
    }

    // MARK: AI POV browser

    /// A real browser laid over AI POV's browser pane, showing the page the agent visits.
    /// (Web pages mostly refuse to load inside another page, so this is a native view.)
    private var browser: WKWebView?
    private var browserURL: String?

    private func povBrowser(_ body: [String: Any]) {
        if body["hide"] as? Bool == true {
            browser?.isHidden = true
            return
        }
        guard let x = body["x"] as? Double, let y = body["y"] as? Double,
              let w = body["w"] as? Double, let h = body["h"] as? Double, w > 20, h > 20 else { return }
        let view: WKWebView
        if let browser {
            view = browser
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = WKWebView(frame: .zero, configuration: configuration)
            view.setValue(false, forKey: "drawsBackground")
            addSubview(view)
            browser = view
        }
        // Page coordinates are top-down; convert when this view isn't flipped.
        let top = isFlipped ? y : bounds.height - y - h
        view.frame = NSRect(x: x, y: top, width: w, height: h)
        view.isHidden = false
        if let url = body["url"] as? String, url != browserURL, let target = URL(string: url),
           target.scheme == "https" || target.scheme == "http" {
            browserURL = url
            view.load(URLRequest(url: target))
        }
    }

    /// Applies the terminal's colors and font (see `EditorTheme`).
    func setTheme(_ json: String) {
        run("app.setTheme(\(json))")
    }

    // MARK: Helpers

    static func branch(of root: String) -> String? {
        guard let repo = VerticalTabsGit.repoRoot(containing: root),
              let head = try? String(contentsOfFile: repo.gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("ref: refs/heads/") ? String(trimmed.dropFirst(16)) : String(trimmed.prefix(7))
    }

    static func js(_ string: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [string])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - Alerts and confirms from the page

extension EditorWebView: WKUIDelegate {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let parts = message.components(separatedBy: "\n\n")
        alert.messageText = parts.first ?? message
        if parts.count > 1 { alert.informativeText = "Your changes will be lost if you don't save them." }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

// MARK: - Serving the bundled page

/// Keeps the editor on its own pages. Its page can read and write your project's files, so
/// it never navigates anywhere else; web links open in your browser instead.
private final class EditorNavigationGuard: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == EditorWebView.scheme || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

/// Serves macos/EditorWeb from the app bundle under ghostty-editor://app/. A custom
/// scheme (rather than file://) lets Monaco start its web workers.
private final class EditorAssetHandler: NSObject, WKURLSchemeHandler {
    private let base = Bundle.main.resourceURL!.appendingPathComponent("EditorWeb")

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = base.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(base.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - File access for the page

/// Answers the page's `fs` requests. Access is limited to the open workspace folder.
private final class EditorFileBridge: NSObject, WKScriptMessageHandlerWithReply {
    var root: String?
    /// Every folder shown this session. Open tabs from earlier folders stay editable.
    var allowedRoots: Set<String> = []
    /// Files an agent touched, which follow mode may open.
    var allowedFiles: Set<String> = []
    var onReady: (() -> Void)?
    var onWrite: ((String, String) -> Void)?
    var onBrowser: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    var onRestore: ((String) -> Void)?

    private let maxFileSize = 8 * 1024 * 1024
    private let hidden: Set<String> = [".git", ".DS_Store", "node_modules", ".zig-cache", "zig-out", ".build", "build", "DerivedData"]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad request")
            return
        }
        if op == "log" {
            let line = "[editor] \(body["message"] ?? "")"
            NSLog("%@", line)
            TestHooks.note(line)
            replyHandler(true, nil)
            return
        }
        if op == "ready" {
            onReady?()
            replyHandler(true, nil)
            return
        }
        if op == "close" {
            onClose?()
            replyHandler(true, nil)
            return
        }
        if op == "browser" {
            onBrowser?(body)
            replyHandler(true, nil)
            return
        }
        if op == "restore" {
            // The app asks before changing any file.
            if let id = body["id"] as? String { onRestore?(id) }
            replyHandler(true, nil)
            return
        }
        // File work happens off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = handle(op, body)
            DispatchQueue.main.async { replyHandler(result, nil) }
        }
    }

    private func handle(_ op: String, _ body: [String: Any]) -> Any {
        switch op {
        case "list":
            guard let path = allowed(body["path"]) else { return [] as [Any] }
            return list(path)
        case "read":
            guard let path = allowed(body["path"]) else { return ["error": "Outside the open folder"] }
            return read(path)
        case "write":
            guard let path = allowed(body["path"]), let content = body["content"] as? String else {
                return ["error": "Outside the open folder"]
            }
            return write(path, content)
        case "stat":
            let paths = (body["paths"] as? [Any] ?? []).compactMap(allowed)
            var result: [String: Double] = [:]
            for path in paths { result[path] = mtime(path) }
            return result
        case "files":
            return allFiles()
        case "backend":
            guard let root, let action = body["action"] as? String else { return ["error": "No folder open"] }
            return BackendProbe.run(action, root: root, body: body)
        default:
            return ["error": "unknown op \(op)"]
        }
    }

    private func allowed(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let path = (raw as NSString).standardizingPath
        if allowedFiles.contains(path) { return path }
        // Case-insensitive: the shell's folder and the disk's can differ in case (projects vs Projects).
        let roots = allowedRoots.union(root.map { [$0] } ?? []).map { $0.lowercased() }
        let lower = path.lowercased()
        return roots.contains { lower == $0 || lower.hasPrefix($0 == "/" ? "/" : $0 + "/") } ? path : nil
    }

    private func list(_ path: String) -> [[String: Any]] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var entries: [[String: Any]] = []
        for name in names where !hidden.contains(name) {
            let full = path + "/" + name
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            entries.append(["name": name, "path": full, "isDir": isDir.boolValue])
        }
        return entries.sorted {
            let (a, b) = ($0["isDir"] as? Bool ?? false, $1["isDir"] as? Bool ?? false)
            if a != b { return a }
            return ($0["name"] as? String ?? "").localizedStandardCompare($1["name"] as? String ?? "") == .orderedAscending
        }
    }

    private func read(_ path: String) -> [String: Any] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return ["error": "Can't read \(path)"]
        }
        if (attributes[.size] as? Int ?? 0) > maxFileSize {
            return ["error": "\((path as NSString).lastPathComponent) is too large to open in the editor."]
        }
        guard let data = FileManager.default.contents(atPath: path) else { return ["error": "Can't read \(path)"] }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
            return ["error": "\((path as NSString).lastPathComponent) is a binary file."]
        }
        return ["content": text, "mtime": mtime(path) ?? 0]
    }

    private func write(_ path: String, _ content: String) -> [String: Any] {
        do {
            onWrite?(path, content)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return ["mtime": mtime(path) ?? 0]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func mtime(_ path: String) -> Double? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    /// Relative paths for quick open. Uses git (respects .gitignore) when possible.
    private func allFiles() -> [String] {
        guard let root else { return [] }
        if VerticalTabsGit.repoRoot(containing: root) != nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root] + AgentTools.gitGuards + ["ls-files", "--cached", "--others", "--exclude-standard"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) {
                    return output.split(separator: "\n").prefix(50_000).map(String.init)
                }
            }
        }
        // Not a repository: walk the folder, but cheaply. Hidden folders and bundles are
        // skipped, a home folder (or anything above it) is only read two levels deep, and
        // the walk stops at 20,000 files or 1.5 seconds. Answers are reused for a while, so
        // several editor pages asking at once (one per tab) walk it once.
        return Self.walkCache.value(for: root, ttl: 30) { Self.walk(root) }
    }

    private static let walkCache = WalkCache()

    private static func walk(_ root: String) -> [String] {
        let home = NSHomeDirectory()
        let shallow = root == home || home.hasPrefix(root + "/") || root == "/"
        let skip: Set<String> = ["node_modules", "Library", "Applications", "Pictures", "Movies", "Music", "build",
                                 "DerivedData", "zig-out", ".build", "dist", "Pods", "venv", ".venv", "__pycache__"]
        let base = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let deadline = Date().addingTimeInterval(1.5)
        var results: [String] = []
        let prefix = base.standardizedFileURL.path.count + 1
        while let url = enumerator.nextObject() as? URL, results.count < 20_000 {
            if results.count % 500 == 0 && Date() > deadline { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skip.contains(url.lastPathComponent) || (shallow && enumerator.level >= 2) { enumerator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true {
                let path = url.standardizedFileURL.path
                if path.count > prefix { results.append(String(path.dropFirst(prefix))) }
            }
        }
        return results
    }
}

/// Recent folder listings, shared by every editor page; concurrent requests for the same
/// folder wait for one walk.
private final class WalkCache {
    private var entries: [String: (Date, [String])] = [:]
    private var running: Set<String> = []
    private let condition = NSCondition()

    func value(for key: String, ttl: TimeInterval, _ compute: () -> [String]) -> [String] {
        condition.lock()
        while running.contains(key) { condition.wait() }
        if let (time, value) = entries[key], Date().timeIntervalSince(time) < ttl {
            condition.unlock()
            return value
        }
        running.insert(key)
        condition.unlock()
        let value = compute()
        condition.lock()
        entries[key] = (Date(), value)
        running.remove(key)
        condition.broadcast()
        condition.unlock()
        return value
    }
}
#endif
