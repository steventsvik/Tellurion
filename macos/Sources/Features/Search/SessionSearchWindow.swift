#if os(macOS)
import AppKit
import SwiftUI

/// Search Sessions: one box over every Claude Code and Codex session on this Mac. It reads
/// the transcripts the agents already keep, only while its window is open and a search is
/// typed in; nothing is indexed, stored or sent anywhere.
enum SessionSearch {
    static let windowID = "session-search"

    /// What's remembered about each transcript between searches (its project, agent and
    /// first prompt), so results get their titles without opening files again.
    static let cache = SessionMetaCache(file: AgentTools.root.appendingPathComponent("session-search-cache.json"))
    fileprivate static let log = StoredFile.logger("SessionSearch")

    static func toggle() {
        guard TellurionSettings.isOn(.sessionSearch) || AgentToolWindows.isOpen(windowID) else { return }
        if AgentToolWindows.isOpen(windowID) {
            AgentToolWindows.close(id: windowID)
        } else {
            // Read before the window opens: the front tab is the one behind it.
            let folder = TerminalWindows.front?.focusedSurface?.pwd
            AgentToolWindows.show(id: windowID, title: "Search Sessions", size: NSSize(width: 940, height: 760)) {
                SessionSearchView(frontFolder: folder)
            }
        }
    }
}

/// Results as they come off the background threads, handed to the window a few times a
/// second instead of once per session.
private final class SessionSearchInbox {
    private let lock = NSLock()
    private var results: [SessionSearchResult] = []
    private var summary = SessionSearchSummary()
    private var waiting = false

    /// Both return whether a delivery needs to be scheduled.
    func add(_ result: SessionSearchResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
        return wait()
    }

    func note(_ summary: SessionSearchSummary) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.summary = summary
        return wait()
    }

    private func wait() -> Bool {
        if waiting { return false }
        waiting = true
        return true
    }

    func take() -> (results: [SessionSearchResult], summary: SessionSearchSummary) {
        lock.lock()
        defer { lock.unlock() }
        waiting = false
        return (results, summary)
    }
}

final class SessionSearchModel: ObservableObject {
    enum AgentChoice: String, CaseIterable, Identifiable {
        case all, claude, codex
        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "All agents"
            case .claude: return VerticalTabAgentKind.claude.displayName
            case .codex: return VerticalTabAgentKind.codex.displayName
            }
        }
    }

    enum TimeChoice: String, CaseIterable, Identifiable {
        case any, week, month
        var id: Self { self }
        var title: String {
            switch self {
            case .any: return "Any time"
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            }
        }
        var days: Double? {
            switch self {
            case .any: return nil
            case .week: return 7
            case .month: return 30
            }
        }
    }

    enum ProjectChoice: Hashable {
        case all, front
        case folder(String)
    }

    /// Sessions shown before "Show more".
    static let page = 200

    @Published var text = "" { didSet { if text != oldValue { changed(after: 0.25) } } }
    @Published var agent = AgentChoice.all { didSet { if agent != oldValue { changed() } } }
    @Published var time = TimeChoice.any { didSet { if time != oldValue { changed() } } }
    @Published var project = ProjectChoice.all { didSet { if project != oldValue { changed() } } }
    @Published var kinds = SearchLineKind.standard { didSet { if kinds != oldValue { changed() } } }
    @Published private(set) var results: [SessionSearchResult] = []
    @Published private(set) var summary = SessionSearchSummary()
    @Published private(set) var searching = false
    /// A search for what's in the box has run to its end.
    @Published private(set) var finished = false
    /// Projects with sessions, most recent first, for the picker.
    @Published private(set) var projects: [LocalhostProject] = []

    /// The project of the tab the window was opened from.
    let front: LocalhostProject?
    private var limit = SessionSearchModel.page
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var token: SessionSearchToken?

    init(frontFolder: String?) {
        front = frontFolder.map { LocalhostProject(folder: $0) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let folders = SessionSearchEngine.folders(roots: .standard, cache: SessionSearch.cache)
            var seen: Set<String> = []
            let projects = folders.map { LocalhostProject(folder: $0) }.filter { seen.insert($0.root).inserted }
            SessionSearch.save()
            DispatchQueue.main.async { self?.projects = projects }
        }
    }

    deinit {
        pending?.cancel()
        token?.cancel()
    }

    var hasQuery: Bool { !SessionSearchQuery(text).isEmpty }

    /// The window closed: nothing goes on reading.
    func stop() {
        pending?.cancel()
        token?.cancel()
        generation += 1
        searching = false
    }

    func showMore() {
        limit += Self.page
        start()
    }

    func toggle(_ kind: SearchLineKind) {
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
    }

    /// The box or a filter changed. Whatever was running stops now; the new search starts
    /// once the typing pauses.
    private func changed(after delay: TimeInterval = 0) {
        pending?.cancel()
        token?.cancel()
        limit = Self.page
        finished = false
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var filters: SessionSearchFilters {
        var filters = SessionSearchFilters(kinds: kinds)
        switch agent {
        case .all: break
        case .claude: filters.agent = "claude"
        case .codex: filters.agent = "codex"
        }
        switch project {
        case .all: break
        case .front: filters.project = front?.root
        case .folder(let folder): filters.project = folder
        }
        filters.since = time.days.map { Date(timeIntervalSinceNow: -$0 * 86_400) }
        return filters
    }

    private func start() {
        token?.cancel()
        generation += 1
        let generation = self.generation
        let request = SessionSearchEngine.Request(query: SessionSearchQuery(text), filters: filters, limit: limit)
        guard !request.query.isEmpty, !kinds.isEmpty else {
            token = nil
            results = []
            summary = SessionSearchSummary()
            searching = false
            finished = false
            return
        }
        let token = SessionSearchToken()
        self.token = token
        searching = true
        finished = false
        let inbox = SessionSearchInbox()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deliver = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.take(inbox, generation: generation, done: false) }
            }
            SessionSearchEngine.search(request, roots: .standard, cache: SessionSearch.cache, token: token,
                                       onProgress: { if inbox.note($0) { deliver() } },
                                       onResult: { if inbox.add($0) { deliver() } })
            SessionSearch.save()
            DispatchQueue.main.async { self?.take(inbox, generation: generation, done: !token.isCancelled) }
        }
    }

    /// On the main thread: shows what's been found so far, unless a newer search took over.
    private func take(_ inbox: SessionSearchInbox, generation: Int, done: Bool) {
        guard generation == self.generation else { return }
        let found = inbox.take()
        results = found.results
        summary = found.summary
        if done {
            searching = false
            finished = true
        }
    }
}

extension SessionSearch {
    /// Its entry in the command palette.
    static var paletteOption: CommandOption {
        CommandOption(title: "Search Sessions",
                      description: "Find a prompt, an agent's message, a command or an edited file in any Claude Code or Codex session",
                      leadingIcon: "magnifyingglass") {
            if !AgentToolWindows.isOpen(windowID) { toggle() }
        }
    }

    /// Keeps the cache if it changed. Off the main thread.
    fileprivate static func save() {
        guard let save = cache.pendingSave() else { return }
        StoredFile.write(save.data, to: save.file, what: "the session search cache", log: log)
    }
}

struct SessionSearchView: View {
    @StateObject private var model: SessionSearchModel
    @FocusState private var focused: Bool

    init(frontFolder: String?) {
        _model = StateObject(wrappedValue: SessionSearchModel(frontFolder: frontFolder))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            Divider().overlay(Tellurion.line)
            content
            Divider().overlay(Tellurion.line)
            footer
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { focused = true }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(Tellurion.gold)
            TextField("Search every session", text: $model.text)
                .textFieldStyle(.plain)
                .font(Tellurion.font(15))
                .foregroundColor(Tellurion.text)
                .focused($focused)
            if model.searching { PixelSpinner(color: Tellurion.gold, pixel: 3.5) }
            if !model.text.isEmpty {
                Button { model.text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Tellurion.dim) }
                    .buttonStyle(.plain)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(shape.fill(Tellurion.panel))
        .overlay(shape.strokeBorder(focused ? Tellurion.gold.opacity(0.55) : Tellurion.line, lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.agent) {
                ForEach(SessionSearchModel.AgentChoice.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 130)
            Picker("", selection: $model.project) {
                Text("All projects").tag(SessionSearchModel.ProjectChoice.all)
                if let front = model.front {
                    Text(verbatim: "This tab: " + SearchSnippets.clean(front.name, limit: 40)).tag(SessionSearchModel.ProjectChoice.front)
                }
                Divider()
                ForEach(model.projects, id: \.root) { project in
                    Text(verbatim: SearchSnippets.clean(project.name, limit: 40)).tag(SessionSearchModel.ProjectChoice.folder(project.root))
                }
            }
            .frame(width: 190)
            Picker("", selection: $model.time) {
                ForEach(SessionSearchModel.TimeChoice.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 130)
            Spacer(minLength: 8)
            ForEach(SearchLineKind.allCases) { kind in
                SessionSearchChip(title: kind.title, on: model.kinds.contains(kind)) { model.toggle(kind) }
                    .help(kind == .output ? "What tools printed and what edits put in files. There's a lot of it, so it's off until you want it."
                          : "Search \(kind.title.lowercased())")
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if !model.hasQuery {
            SessionSearchHint(title: "Search every session",
                              lines: ["Words must all be on the same line: retry backoff",
                                      "\"Quoted words\" stay together, and -word leaves lines out",
                                      "file:Queue.swift keeps to edits and commands on that file",
                                      "All lowercase ignores case; one capital makes it exact"])
        } else if model.kinds.isEmpty {
            SessionSearchHint(title: "Nothing to search", lines: ["Turn on at least one of the kinds above."])
        } else if model.results.isEmpty {
            if model.finished {
                SessionSearchHint(title: "No matches", lines: [
                    "Searched \(Self.count(model.summary.sessions, "session")).",
                    model.kinds.contains(.output) ? "Try fewer words, or a wider time or project."
                        : "Tool output isn't searched until you turn it on above.",
                ])
            } else {
                SessionSearchHint(title: "Searching…", lines: [])
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.results) { SessionSearchRow(result: $0) }
                    if model.summary.capped, !model.searching {
                        Button("Show more") { model.showMore() }
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(verbatim: footnote).lineLimit(1)
            Spacer(minLength: 8)
            if model.summary.cutFiles > 0 {
                Text(verbatim: "\(Self.count(model.summary.cutFiles, "large transcript")) searched only in the latest 64 MB")
                    .lineLimit(1)
                    .help("A transcript larger than 64 MB is searched from its end, where its latest work is.")
            }
        }
        .font(Tellurion.font(10.5))
        .foregroundColor(Tellurion.muted)
        .padding(.horizontal, 18)
        .frame(height: 30)
    }

    private var footnote: String {
        guard model.hasQuery, !model.kinds.isEmpty else { return "Claude Code and Codex sessions on this Mac. Nothing leaves it." }
        let summary = model.summary
        let found = "\(Self.count(summary.matches, "match", plural: "matches")) in \(Self.count(summary.results, "session"))"
        let searched = "searched \(Self.count(summary.sessions, "session"))"
        if model.searching { return found + " · " + searched + " so far" }
        return found + " · " + searched + (summary.capped ? " · there may be more" : "")
    }

    fileprivate static func count(_ number: Int, _ noun: String, plural: String? = nil) -> String {
        "\(number) " + (number == 1 ? noun : plural ?? noun + "s")
    }
}

private struct SessionSearchChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Tellurion.font(10.5, weight: .semibold))
                .foregroundColor(on ? Tellurion.gold : Tellurion.dim)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(shape.fill(on ? Tellurion.gold.opacity(0.12) : Tellurion.panel))
                .overlay(shape.strokeBorder(on ? Tellurion.gold.opacity(0.5) : Tellurion.line, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

private struct SessionSearchHint: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(Tellurion.font(16)).foregroundColor(Tellurion.text)
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line).font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One session with matches: what it was, a few of its matching lines, and what to do with it.
private struct SessionSearchRow: View {
    let result: SessionSearchResult
    @State private var expanded = false

    /// Snippets shown until "more matches" is clicked.
    private static let brief = 3

    private var session: ActivitySession {
        ActivitySession(id: result.meta.session, agent: result.meta.agent, codexProvider: result.meta.codexProvider,
                        codexModel: result.meta.codexModel, cwd: result.meta.cwd)
    }

    private var canResume: Bool { result.meta.cwd != nil && UUID(uuidString: result.meta.session) != nil }

    var body: some View {
        let session = session
        let shown = expanded ? result.snippets : Array(result.snippets.prefix(Self.brief))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentBadge(kind: session.kind, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: result.meta.title ?? "Untitled session")
                        .font(Tellurion.font(12)).foregroundColor(Tellurion.text).lineLimit(1)
                    Text(verbatim: [SearchSnippets.clean(session.project, limit: 60), session.kind.displayName,
                                    result.modified.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · "))
                        .font(Tellurion.font(10.5)).foregroundColor(Tellurion.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if canResume {
                    Button("Resume") { resume(session) }
                        .help("Continue this session in a new tab")
                }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([result.transcript]) }
                    .help("Show this session's transcript in Finder")
            }
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { SessionSearchSnippetRow(snippet: $0) }
            }
            if result.matches > Self.brief {
                Button(expanded ? "Show fewer" : moreLabel) { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(Tellurion.font(10.5, weight: .semibold))
                    .foregroundColor(Tellurion.gold)
                    .disabled(result.snippets.count <= Self.brief)
                if expanded, result.matches > result.snippets.count {
                    Text(verbatim: "The first \(result.snippets.count) are shown.")
                        .font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tellurionPanel()
    }

    private var moreLabel: String {
        let rest = result.matches - Self.brief
        return "\(rest)\(result.more ? "+" : "") more \(rest == 1 ? "match" : "matches")"
    }

    /// The same as Resume in the activity window: a new tab in the session's folder, on the
    /// provider it ran on.
    private func resume(_ session: ActivitySession) {
        guard let cwd = session.cwd,
              let owner = TerminalWindows.front ?? TerminalWindows.all.first else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        var backend = AgentResume.Backend.plain
        if session.onVenice {
            // Back on Venice, or not at all: plain Codex would send this work to another provider.
            let venice = VeniceAccount.shared
            guard let model = session.codexModel else { return venice.showProblem("This session doesn't say which Venice model it used.") }
            let isPrivate = venice.models.first { $0.id == model }?.isPrivate ?? true
            guard venice.prepareUseOrShowProblem(modelName: model, isPrivate: isPrivate) else { return }
            config.environmentVariables.merge(VeniceCodex.environment(model: model)) { $1 }
            backend = .venice(model: nil)
        } else if session.onLocal, let provider = session.codexProvider {
            // Back on the model on this Mac, or at least on its host: never on another provider.
            config.environmentVariables.merge(LocalCodex.environment(model: session.codexModel ?? "", provider: provider)) { $1 }
            backend = .local(provider: provider, model: session.codexModel)
        }
        // Nothing is typed for an id that isn't a session's.
        guard let line = AgentResume.line(session.kind, session: session.id, on: backend) else { return }
        config.initialInput = line
        if let surface = TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config) {
            TerminalWindows.controller(for: surface)?.window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// One matching line. What it shows came out of a transcript, so it's drawn as plain text:
/// nothing in it is read as formatting or as a link.
private struct SessionSearchSnippetRow: View {
    let snippet: SearchSnippet
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(snippet.kind.label.uppercased())
                .font(Tellurion.font(9, weight: .semibold)).kerning(0.8)
                .foregroundColor(Tellurion.dim)
                .frame(width: 48, alignment: .leading)
            text
                .font(snippet.kind == .command || snippet.kind == .edit ? Tellurion.mono(11) : Tellurion.font(11.5, weight: .regular))
                .foregroundColor(Tellurion.text.opacity(0.85))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Tellurion.muted)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Copy this snippet")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Tellurion.text.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }

    private var text: Text {
        snippet.pieces.reduce(Text(verbatim: "")) { whole, piece in
            whole + (piece.lit ? Text(verbatim: piece.text).foregroundColor(Tellurion.gold).bold() : Text(verbatim: piece.text))
        }
    }
}
#endif
