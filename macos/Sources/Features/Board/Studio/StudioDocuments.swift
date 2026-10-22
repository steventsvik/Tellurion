#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Documents written about a project by your Claude Code or Codex: pick a template (Project
/// overview, Architecture…) or ask for anything; it reads the project (read-only) and writes
/// the document, which you watch arrive as a finished page. Each one is kept in the project's
/// library (~/.ghostty-extreme/docs, never inside the project), can be put on the board as a
/// document card, and exported as a PDF.
enum StudioDocs {
    struct Template: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let ask: String
    }

    enum Effort: String, CaseIterable, Identifiable {
        case quick, balanced, thorough

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var model: String { self == .thorough ? "opus" : "sonnet" }
        var guidance: String {
            switch self {
            case .quick: return "Be quick: skim the README and the main entry points. About 400 words."
            case .balanced: return "Read the important files. About 900 to 1300 words."
            case .thorough: return "Read widely and check details in the code. About 2000 words, with examples."
            }
        }
    }

    static let templates: [Template] = [
        Template(id: "overview", title: "Project overview", subtitle: "What this repo is, at a glance", symbol: "doc.richtext",
                 ask: "Write a project overview: what it is, the problem it solves, who it's for, how it's organized, the tech stack (as a table: Layer, Technology, Notes) and how to run it."),
        Template(id: "onboarding", title: "Onboarding guide", subtitle: "Get a new contributor productive", symbol: "person.badge.plus",
                 ask: "Write an onboarding guide for a new contributor: setup, how to run and test, the codebase tour, conventions, and a first task to try."),
        Template(id: "architecture", title: "Architecture", subtitle: "Modules, layers and data flow", symbol: "square.stack.3d.up",
                 ask: "Write an architecture document: the main modules and layers, how data flows through them, key decisions and their trade-offs."),
        Template(id: "readme", title: "README", subtitle: "A polished front-page README", symbol: "text.book.closed",
                 ask: "Write a polished README: a one-line pitch, features, install, usage with examples, configuration, and contributing."),
        Template(id: "api", title: "API reference", subtitle: "Public surface and how to call it", symbol: "curlybraces",
                 ask: "Write an API reference for the project's public surface: each function, endpoint or command, its parameters, what it returns, and an example."),
        Template(id: "data", title: "Data model", subtitle: "Entities, fields and relationships", symbol: "cylinder.split.1x2",
                 ask: "Document the data model: each entity, its fields (as tables) and how entities relate."),
        Template(id: "security", title: "Security overview", subtitle: "Trust boundaries and risks", symbol: "lock.shield",
                 ask: "Write a security overview: trust boundaries, where input comes from, secrets handling, risky areas, and recommendations."),
    ]

    static let instructions = """
    You write documentation about the software project in the current folder, for the people \
    who work on it. You can read its files (read-only); look at what you need before writing. \
    Answer with the document only, in GitHub-flavored Markdown, starting with a level-one \
    heading that names it. Use short paragraphs, headings, lists, tables where they help, \
    fenced code blocks with their language, and callouts like "> [!NOTE]" or "> [!TIP]" for \
    things worth noticing. Be specific to this project; name real files and commands. Don't \
    describe what you did or how you wrote it.
    """

    /// Where a project's documents are kept: in Tellurion's folder, never inside the project.
    static func library(for project: String) -> URL {
        let name = (project as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        var hash: UInt64 = 1469598103934665603
        for byte in project.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return AgentTools.root.appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("\(name)-\(String(hash % 0xFFFFFF, radix: 16))", isDirectory: true)
    }

    static func saved(in project: String) -> [URL] {
        let folder = library(for: project)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    /// Saves a markdown file as a paginated PDF (asks where).
    static func exportPDF(markdown: String, title: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        let save: (URL) -> Void = { url in PDFExporter.shared.export(html: MarkdownHTML.page(markdown, title: title), to: url) }
        if let window {
            panel.beginSheetModal(for: window) { response in if response == .OK, let url = panel.url { save(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            save(url)
        }
    }
}

/// Prints an HTML page to a PDF file, page by page, from an off-screen web view.
final class PDFExporter: NSObject, WKNavigationDelegate {
    static let shared = PDFExporter()
    private var jobs: [(view: WKWebView, window: NSWindow, url: URL)] = []

    func export(html: String, to url: URL) {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 1100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
        view.navigationDelegate = self
        window.contentView = view
        jobs.append((view, window, url))
        view.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let index = jobs.firstIndex(where: { $0.view === webView }) else { return }
        let job = jobs.remove(at: index)
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = job.url
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        operation.runModal(for: job.window, delegate: nil, didRun: nil, contextInfo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = job }
    }
}

/// The Documents panel's state for one board.
final class StudioDocuments: ObservableObject {
    @Published var project: String?
    @Published var engine: HeadlessAgent.Engine = .claude
    @Published var effort: StudioDocs.Effort = .balanced
    @Published var template: StudioDocs.Template? = StudioDocs.templates.first
    @Published var ask = ""
    @Published private(set) var markdown = ""
    @Published private(set) var phase: HeadlessAgent.Phase?
    @Published private(set) var started: Date?
    @Published private(set) var error: String?
    /// The saved file for what's shown.
    @Published private(set) var file: URL?
    @Published private(set) var library: [URL] = []

    private var run: HeadlessAgent.Run?

    var running: Bool { phase != nil }

    func open(project: String?) {
        if self.project == nil || project != nil { self.project = project }
        refresh()
    }

    func refresh() {
        library = project.map(StudioDocs.saved(in:)) ?? []
    }

    func lastRun(_ effort: StudioDocs.Effort) -> TimeInterval? {
        let value = UserDefaults.standard.double(forKey: "StudioDocsTime." + effort.rawValue)
        return value > 0 ? value : nil
    }

    /// Writes the chosen template, or what was asked.
    func generate(custom: Bool = false) {
        guard let project, !running else { return }
        let request = custom ? ask.trimmingCharacters(in: .whitespacesAndNewlines) : (template?.ask ?? "")
        guard !request.isEmpty else { return }
        let id = custom ? "custom-" + AgentTools.timestamp() : (template?.id ?? "doc")
        markdown = ""
        error = nil
        file = nil
        phase = .thinking
        started = Date()
        let effort = self.effort, engine = self.engine
        let prompt = request + "\n\n" + effort.guidance
        // Callbacks from a run that was stopped (or replaced) are ignored.
        var current: HeadlessAgent.Run?
        let ask = HeadlessAgent.Ask(instructions: StudioDocs.instructions, prompt: prompt, folder: project,
                                    model: engine == .claude ? effort.model : nil)
        current = HeadlessAgent.stream(engine, ask, progress: { [weak self] phase, text in
            DispatchQueue.main.async {
                guard let self, let current, self.run === current else { return }
                self.phase = phase
                self.markdown = text
            }
        }, done: { [weak self] result in
            guard let self, let current, self.run === current else { return }
            let seconds = Date().timeIntervalSince(self.started ?? Date())
            self.phase = nil
            self.run = nil
            switch result {
            case .success(let text):
                self.markdown = Self.clean(text)
                UserDefaults.standard.set(seconds, forKey: "StudioDocsTime." + effort.rawValue)
                self.save(as: id)
            case .failure(HeadlessAgent.StreamError.stopped):
                break
            case .failure(let failure):
                self.error = failure.localizedDescription
            }
        })
        run = current
    }

    func stop() {
        run?.stop()
        run = nil
        phase = nil
    }

    func show(_ url: URL) {
        stop()
        markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        file = url
        error = nil
    }

    /// Strips a code fence some answers wrap the whole document in, and a short remark
    /// before the document's first heading.
    static func clean(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```") {
            text = text.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        let lines = text.components(separatedBy: "\n")
        // Only a few lines of plain text: never code, or a heading inside a code block.
        if let first = lines.prefix(6).firstIndex(where: { $0.hasPrefix("#") }), first > 0,
           !lines[..<first].contains(where: { $0.hasPrefix("```") }) {
            text = lines[first...].joined(separator: "\n")
        }
        return text
    }

    private func save(as id: String) {
        guard let project, !markdown.isEmpty else { return }
        let folder = StudioDocs.library(for: project)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(id + ".md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        file = url
        refresh()
    }
}

extension BoardController {
    /// The project documents are written about: the focused tile's, else the board's folder.
    var documentsProject: String? {
        let pwd = (focusedSurface ?? model.focused?.value)?.pwd
        return pwd.flatMap(BoardProjects.project(of:)) ?? workspace.folder.flatMap(BoardProjects.project(of:)) ?? workspace.folder
    }

    func showDocuments() {
        guard ExtremeSettings.isOn(.documents) else { return }
        documents.open(project: documentsProject)
        withAnimation(.easeOut(duration: 0.18)) { model.showDocuments = true }
    }

    /// A document card for a markdown file.
    func placeDocument(_ url: URL, at point: CGPoint? = nil) {
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let id = addCard(.document, at: point, edit: false)
        updateCard(id) { card in
            card.file = url.path
            card.title = MarkdownHTML.title(markdown) ?? url.deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - The panel

struct StudioDocumentsView: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel
    @ObservedObject var docs: StudioDocuments

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { close() }
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Rectangle().fill(Extreme.line).frame(width: 1)
                page
            }
            .frame(maxWidth: 1180, maxHeight: 780)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Extreme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Extreme.lineStrong))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(40)
        }
        .onExitCommand { close() }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { model.showDocuments = false }
    }

    // MARK: Left

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Documents").font(Extreme.font(17, weight: .semibold)).foregroundColor(Extreme.text)
                    Text("Generate a document from your repo, with your CLI.").font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                }
                projectRow
                HStack(spacing: 6) {
                    ForEach(HeadlessAgent.Engine.allCases) { engine in
                        Button { docs.engine = engine } label: {
                            HStack(spacing: 5) {
                                VerticalTabAgentLogo(kind: engine.kind, tint: Extreme.text).frame(width: 13, height: 13)
                                Text(engine.title).font(Extreme.font(11.5, weight: .medium))
                            }
                            .foregroundColor(Extreme.text)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(docs.engine == engine ? Extreme.raised : .clear))
                            .overlay(Capsule().strokeBorder(docs.engine == engine ? Extreme.core : Extreme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(StudioDocs.Effort.allCases) { effort in
                        Button { docs.effort = effort } label: {
                            VStack(spacing: 1) {
                                Text(effort.title).font(Extreme.font(11.5, weight: .semibold))
                                Text(docs.lastRun(effort).map(Self.clock) ?? "not timed").font(Extreme.mono(10)).opacity(0.7)
                            }
                            .foregroundColor(docs.effort == effort ? Extreme.ink : Extreme.text)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 8).fill(docs.effort == effort ? Extreme.core : Extreme.raised))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ExtremeSectionLabel("Documents")
                VStack(spacing: 2) {
                    ForEach(StudioDocs.templates) { template in templateRow(template) }
                }
                ExtremeSectionLabel("Ask for anything")
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("e.g. a migration plan from REST to GraphQL…", text: $docs.ask, axis: .vertical)
                        .textFieldStyle(.plain).font(Extreme.font(12)).lineLimit(2...5)
                    Button { docs.generate(custom: true) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundColor(Extreme.ink)
                            .frame(width: 26, height: 26).background(Circle().fill(Extreme.core))
                    }
                    .buttonStyle(.plain)
                    .disabled(docs.ask.trimmingCharacters(in: .whitespaces).isEmpty || docs.running || docs.project == nil)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Extreme.raised))
                if !docs.library.isEmpty {
                    ExtremeSectionLabel("Library")
                    VStack(spacing: 2) {
                        ForEach(docs.library, id: \.self) { url in
                            Button { docs.show(url) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundColor(Extreme.muted)
                                    Text(url.deletingPathExtension().lastPathComponent).font(Extreme.font(12)).foregroundColor(Extreme.text).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 6).fill(docs.file == url ? Extreme.raised : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var projectRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundColor(Extreme.dim)
            Text(docs.project.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Choose a project")
                .font(Extreme.mono(11)).foregroundColor(Extreme.muted).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Change…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    docs.project = url.path
                    docs.refresh()
                }
            }
            .controlSize(.small)
        }
    }

    private func templateRow(_ template: StudioDocs.Template) -> some View {
        let done = docs.library.contains { $0.deletingPathExtension().lastPathComponent == template.id }
        let on = docs.template == template
        return Button { docs.template = template } label: {
            HStack(spacing: 9) {
                Image(systemName: template.symbol).font(.system(size: 12)).foregroundColor(on ? Extreme.core : Extreme.muted).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(template.title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                    Text(template.subtitle).font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
                }
                Spacer()
                if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(.green) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Extreme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Right

    private var page: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MarkdownHTML.title(docs.markdown) ?? docs.template?.title ?? "Document")
                        .font(Extreme.font(14, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                    if !docs.running, !docs.markdown.isEmpty {
                        let stats = MarkdownHTML.stats(docs.markdown)
                        Text("\(stats.words) words · ~\(stats.minutes) min read").font(Extreme.font(11)).foregroundColor(Extreme.dim)
                    }
                }
                Spacer()
                if let phase = docs.phase { statusChip(phase) }
                if docs.running {
                    Button { docs.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").font(Extreme.font(11.5, weight: .semibold)).foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                } else if !docs.markdown.isEmpty {
                    toolbar
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(Extreme.muted)
                        .frame(width: 26, height: 26).background(Circle().fill(Extreme.raised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18).frame(height: 60)
            Rectangle().fill(Extreme.line).frame(height: 1)
            if docs.markdown.isEmpty && !docs.running {
                emptyPage
            } else {
                DocumentWebView(markdown: docs.markdown, follow: docs.running)
            }
        }
    }

    private func statusChip(_ phase: HeadlessAgent.Phase) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(Self.phaseText(phase, docs.engine) + " · ").font(Extreme.font(11.5, weight: .medium)).foregroundColor(Extreme.text)
                + Text(docs.started ?? Date(), style: .timer).font(Extreme.font(11.5, weight: .medium).monospacedDigit()).foregroundColor(Extreme.text)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Extreme.raised))
    }

    static func phaseText(_ phase: HeadlessAgent.Phase, _ engine: HeadlessAgent.Engine) -> String {
        switch phase {
        case .thinking: return "Thinking with \(engine.title)"
        case .reading: return "Reading the project"
        case .writing: return "Writing with \(engine.title)"
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            icon("doc.on.doc", "Copy as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(docs.markdown, forType: .string)
            }
            icon("arrow.clockwise", "Write it again") { docs.generate() }
            icon("rectangle.on.rectangle", "Place on the board") {
                if let file = docs.file {
                    controller.placeDocument(file)
                    close()
                }
            }
            Button {
                StudioDocs.exportPDF(markdown: docs.markdown, title: MarkdownHTML.title(docs.markdown) ?? "Document", from: controller.window)
            } label: {
                Text("Export PDF").font(Extreme.font(11.5, weight: .semibold)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(Extreme.core))
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium)).foregroundColor(Extreme.text)
                .frame(width: 28, height: 26).background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var emptyPage: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: docs.template?.symbol ?? "doc.text").font(.system(size: 30, weight: .light)).foregroundColor(Extreme.muted)
            Text(docs.template?.title ?? "Document").font(Extreme.font(16, weight: .semibold)).foregroundColor(Extreme.text)
            Text(docs.template?.subtitle ?? "").font(Extreme.font(12)).foregroundColor(Extreme.muted)
            if let error = docs.error {
                Text(error).font(Extreme.font(11.5)).foregroundColor(.red).multilineTextAlignment(.center).padding(.horizontal, 60)
            }
            Button { docs.generate() } label: {
                Label("Generate with \(docs.engine.title)", systemImage: "sparkle")
                    .font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.ink)
                    .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Extreme.core))
            }
            .buttonStyle(.plain)
            .disabled(docs.project == nil)
            Text("Saved to this project's library when it finishes.").font(Extreme.font(11)).foregroundColor(Extreme.dim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A markdown page in a web view: its own HTML only, no page script. While a document is
/// still arriving, it keeps the newest text in view.
struct DocumentWebView: NSViewRepresentable {
    let markdown: String
    var follow = false

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.shown != markdown else { return }
        coordinator.shown = markdown
        let html = MarkdownHTML.page(markdown)
        guard follow, coordinator.loaded else {
            coordinator.follow = follow
            view.loadHTMLString(html, baseURL: nil)
            return
        }
        // Keeps up with new text only if you were at the bottom; reading further up stays put.
        view.evaluateJavaScript("window.innerHeight + window.scrollY >= document.body.scrollHeight - 80") { result, _ in
            coordinator.follow = result as? Bool ?? true
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: String?
        var follow = false
        var loaded = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if follow { webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)") }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Web links open in your browser; links within the page move within it.
            if action.navigationType == .linkActivated, let url = action.request.url {
                let scheme = url.scheme?.lowercased()
                if scheme == "http" || scheme == "https" { NSWorkspace.shared.open(url) }
                decisionHandler(scheme == "about" && url.fragment != nil ? .allow : .cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Document cards

/// A document on the board: a markdown file shown as a page.
final class DocumentContent: CardContent {
    private var host: NSView?
    private var shown: String?

    override func apply(_ card: BoardCard) {
        let markdown = card.file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "# Missing\n\nThe file was moved or deleted."
        guard markdown != shown else { return }
        shown = markdown
        host?.removeFromSuperview()
        let view = NSHostingView(rootView: DocumentWebView(markdown: markdown))
        view.sizingOptions = []
        addSubview(view)
        host = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
    }
}
#endif
