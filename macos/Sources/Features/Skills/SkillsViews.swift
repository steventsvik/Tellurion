#if os(macOS)
import AppKit
import SwiftUI

/// The Skills window: every skill installed for any agent, with updates, and skills.sh's
/// leaderboards to find new ones.
enum SkillsWindow {
    static let windowID = "skills"

    static func show(folder: String? = nil) {
        guard ExtremeSettings.isOn(.skills) else { return }
        AgentToolWindows.show(id: windowID, title: "Skills", size: NSSize(width: 1040, height: 700)) {
            SkillsWindowView(project: folder)
        }
    }

    /// For the focused terminal of the frontmost window (a tab, or a tile on a board).
    static func showForFrontTab() {
        show(folder: TerminalWindows.front?.focusedSurface?.pwd)
    }
}

@MainActor
final class SkillsModel: ObservableObject {
    enum Tab: String, CaseIterable { case installed = "Installed", discover = "Discover" }

    /// The front tab's project (its repository, or its folder), for project skills and installs.
    @Published private(set) var project: String?
    @Published var tab: Tab = .installed

    // Installed
    @Published private(set) var installed: [InstalledSkill] = []
    @Published private(set) var statuses: [String: SkillUpdateStatus] = [:]
    @Published private(set) var scanned = false
    @Published private(set) var checking = false
    @Published var selection: String?
    @Published var search = ""
    @Published var onlyUpdates = false
    @Published private(set) var preview = ""

    // Discover
    @Published var board: SkillDirectory.Board = .trending { didSet { if board != oldValue { loadBoard() } } }
    @Published private(set) var listing: [ListedSkill] = []
    @Published private(set) var loadingList = true
    @Published private(set) var listError: String?
    @Published var query = ""
    @Published private(set) var searching = false
    @Published var showOfficial = UserDefaults.standard.bool(forKey: "SkillsShowOfficial") {
        didSet { UserDefaults.standard.set(showOfficial, forKey: "SkillsShowOfficial") }
    }
    @Published var picked: ListedSkill? { didSet { if picked != oldValue { loadDetail() } } }
    @Published private(set) var summary: String?
    @Published private(set) var summaryLoaded = false
    @Published private(set) var audits: [SkillAudit]?
    @Published var agents: Set<SkillAgent> {
        didSet { UserDefaults.standard.set(agents.map(\.rawValue), forKey: "SkillsInstallAgents") }
    }
    @Published var inProject = false

    /// Owners skills.sh marks official anywhere, so search results can be filtered too.
    private var officialOwners: Set<String> = []
    private var boards: [SkillDirectory.Board: [ListedSkill]] = [:]
    private var searchTask: Task<Void, Never>?

    /// Update checks from the last 15 minutes, by skill and origin, so reopening the window
    /// doesn't ask GitHub again.
    private static var checked: [String: SkillUpdateStatus] = [:]
    private static var checkedAt = Date.distantPast

    init(project: String?) {
        self.project = project == NSHomeDirectory() ? nil : project
        let saved = (UserDefaults.standard.array(forKey: "SkillsInstallAgents") as? [String] ?? []).compactMap(SkillAgent.init(rawValue:))
        agents = Set(saved.isEmpty ? SkillAgent.allCases.filter(\.isPresent) : saved)
        // SwiftUI creates this while it builds the window, when changing published values
        // isn't allowed; start loading once that's done.
        DispatchQueue.main.async {
            self.loadBoard()
            // The repository's root, found off the main thread: git can take a moment.
            Task.detached(priority: .userInitiated) {
                let root = project.map { AgentTools.repoRoot(of: $0) ?? $0 }
                await MainActor.run {
                    self.project = root == NSHomeDirectory() ? nil : root
                    self.reload()
                }
            }
        }
    }

    // MARK: Installed

    var selected: InstalledSkill? { installed.first { $0.id == selection } }

    var updateCount: Int { installed.filter { statuses[$0.id] == .available }.count }

    /// Updates `npx skills update` can do in one go.
    var registryUpdates: Int {
        installed.filter { statuses[$0.id] == .available && $0.source != nil && !$0.project }.count
    }

    func skills(in group: SkillGroup) -> [InstalledSkill] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return installed.filter { skill in
            skill.group == group
                && (!onlyUpdates || statuses[skill.id] == .available)
                && (query.isEmpty || (skill.name + " " + skill.summary + " " + (skill.source ?? "")).lowercased().contains(query))
        }
    }

    func reload() {
        let project = project
        Task.detached(priority: .userInitiated) {
            let skills = SkillInventory.scan(project: project)
            await MainActor.run {
                self.installed = skills
                self.scanned = true
                if self.selection == nil || !skills.contains(where: { $0.id == self.selection }) {
                    // Start on one the user chose, not one an agent shipped with.
                    self.select(skills.first { if case .bundled = $0.origin { return false } else { return true } } ?? skills.first)
                } else {
                    self.loadPreview()
                }
                self.checkUpdates(force: false)
            }
        }
    }

    func select(_ skill: InstalledSkill?) {
        selection = skill?.id
        loadPreview()
    }

    private func loadPreview() {
        guard let skill = selected else { preview = ""; return }
        let text = (try? String(contentsOfFile: skill.skillFile, encoding: .utf8)) ?? ""
        let body = SkillInventory.body(text)
        // Some skills inline whole references; a few screens is plenty to read here.
        preview = body.count > 40_000 ? String(body.prefix(40_000)) + "\n\n… (Open SKILL.md for the rest)" : body
    }

    private static func cacheKey(_ skill: InstalledSkill) -> String { skill.id + "|" + String(describing: skill.origin) }

    /// Checks every skill not checked recently (all of them when `force`).
    func checkUpdates(force: Bool) {
        guard !checking else { return }
        if force || Date().timeIntervalSince(Self.checkedAt) > 15 * 60 { Self.checked = [:] }
        var todo: [InstalledSkill] = []
        for skill in installed {
            if let known = Self.checked[Self.cacheKey(skill)] { statuses[skill.id] = known } else { todo.append(skill) }
        }
        guard !todo.isEmpty else { return }
        checking = true
        for skill in todo { statuses[skill.id] = .checking }
        Task {
            let result = await SkillInventory.checkUpdates(todo)
            if Self.checked.isEmpty { Self.checkedAt = Date() }
            for skill in todo {
                let status = result[skill.id] ?? .unknown
                statuses[skill.id] = status
                // A failure is worth asking again next time.
                if case .failed = status { continue }
                Self.checked[Self.cacheKey(skill)] = status
            }
            checking = false
        }
    }

    func update(_ skill: InstalledSkill) {
        guard let command = SkillInventory.updateCommand(skill) else { return }
        Self.checked.removeValue(forKey: Self.cacheKey(skill))
        SetupChecks.openTab(running: command)
    }

    func updateAll() {
        for skill in installed where skill.source != nil { Self.checked.removeValue(forKey: Self.cacheKey(skill)) }
        SetupChecks.openTab(running: SkillInventory.updateAllCommand)
    }

    var canRemove: Bool {
        guard let skill = selected else { return false }
        switch skill.origin {
        case .registry, .git, .local: return true
        case .plugin, .bundled, .hermesHub: return false
        }
    }

    func remove() {
        guard let skill = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(skill.name)”?"
        if case .registry = skill.origin {
            alert.informativeText = "Runs `npx skills remove` in a new tab, which unlinks it from every agent."
        } else {
            alert.informativeText = "Its folder goes to the Trash, so you can put it back from there."
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if case .registry = skill.origin {
            SetupChecks.openTab(running: SkillInventory.removeCommand(skill))
            return
        }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: skill.id)]) { _, _ in
            // A link to it elsewhere would point at nothing.
            if skill.folder != skill.id { try? FileManager.default.removeItem(atPath: skill.folder) }
            DispatchQueue.main.async { self.reload() }
        }
    }

    /// Opens Discover searching for `skill`, to find where it came from.
    func findSource(_ skill: InstalledSkill) {
        tab = .discover
        query = skill.name
        runSearch()
    }

    // MARK: Discover

    var visibleListing: [ListedSkill] {
        showOfficial ? listing : listing.filter { !$0.official && !officialOwners.contains($0.owner) }
    }

    var hiddenOfficial: Int { listing.count - visibleListing.count }

    func loadBoard(force: Bool = false) {
        guard query.trimmingCharacters(in: .whitespaces).count < 2 else { return }
        let board = board
        if !force, let cached = boards[board] {
            listing = cached
            listError = nil
            pickFirst()
            return
        }
        loadingList = true
        listError = nil
        Task {
            let result = await SkillDirectory.board(board)
            guard board == self.board, query.trimmingCharacters(in: .whitespaces).count < 2 else { return }
            loadingList = false
            switch result {
            case .success(let skills):
                boards[board] = skills
                officialOwners.formUnion(skills.filter(\.official).map(\.owner))
                listing = skills
                pickFirst()
            case .failure(let failure):
                listing = []
                listError = failure.message
            }
        }
    }

    /// Searches after a short pause in typing; an empty search goes back to the leaderboard.
    func queryChanged() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.count < 2 {
            searching = false
            loadBoard()
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            runSearch()
        }
    }

    func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return }
        searching = true
        listError = nil
        Task {
            let result = await SkillDirectory.search(text)
            guard text == query.trimmingCharacters(in: .whitespaces) else { return }
            searching = false
            switch result {
            case .success(let skills):
                listing = skills
                if skills.isEmpty { listError = "Nothing on skills.sh matches “\(text)”." }
                pickFirst()
            case .failure(let failure):
                listing = []
                listError = failure.message
            }
        }
    }

    private func pickFirst() {
        if let picked, visibleListing.contains(picked) { return }
        picked = visibleListing.first
    }

    private func loadDetail() {
        summary = nil
        summaryLoaded = false
        audits = nil
        guard let skill = picked else { return }
        Task {
            async let text = SkillDirectory.summary(skill)
            async let reviews = SkillDirectory.audits(skill)
            let (s, a) = await (text, reviews)
            guard skill == picked else { return }
            summary = s
            summaryLoaded = true
            audits = a
        }
    }

    /// The installed copy of a listed skill, if any.
    func installedCopy(of skill: ListedSkill) -> InstalledSkill? {
        installed.first { $0.source == skill.source && ($0.name == skill.name || ($0.folder as NSString).lastPathComponent == skill.skillId) }
    }

    /// A skill with the same name but no recorded source, which may or may not be this one.
    func sameName(as skill: ListedSkill) -> InstalledSkill? {
        guard installedCopy(of: skill) == nil else { return nil }
        return installed.first { $0.source == nil && ($0.name == skill.name || ($0.folder as NSString).lastPathComponent == skill.skillId) }
    }

    func installCommand(_ skill: ListedSkill) -> String {
        SkillInventory.installCommand(source: skill.source, skill: skill.skillId,
                                      agents: SkillAgent.allCases.filter { agents.contains($0) },
                                      project: inProject ? project : nil)
    }

    func install(_ skill: ListedSkill) {
        SetupChecks.openTab(running: installCommand(skill))
    }
}

private struct SkillsWindowView: View {
    @StateObject private var model: SkillsModel

    init(project: String?) {
        _model = StateObject(wrappedValue: SkillsModel(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ExtremeWindowTitle(icon: .skills, title: "Skills", subtitle: subtitle)
                Spacer()
                Picker("", selection: $model.tab) {
                    ForEach(SkillsModel.Tab.allCases, id: \.self) { tab in
                        Text(tab == .installed && model.updateCount > 0 ? "Installed · \(model.updateCount)" : tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .labelsHidden()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Extreme.line).frame(height: 1)
            switch model.tab {
            case .installed: InstalledPane(model: model)
            case .discover: DiscoverPane(model: model)
            }
        }
        .frame(minWidth: 860, idealWidth: 1040, maxWidth: .infinity, minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        // Installs and updates run in a tab; coming back here shows the result.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.title == "Skills", model.scanned { model.reload() }
        }
    }

    private var subtitle: String {
        guard model.scanned else { return "Looking…" }
        let count = model.installed.count
        let agents = Set(model.installed.map(\.group)).count
        return "\(count) installed in \(agents) \(agents == 1 ? "place" : "places")" + (model.checking ? " · checking for updates…" : "")
    }
}

// MARK: Installed

private struct InstalledPane: View {
    @ObservedObject var model: SkillsModel
    @State private var folded: Set<SkillGroup> = []
    /// Sections showing the skills that came with their agent (Hermes and Cursor ship
    /// dozens, so they start hidden).
    @State private var showBuiltIn: Set<SkillGroup> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list.frame(width: 330)
                Rectangle().fill(Extreme.line).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Extreme.line).frame(height: 1)
            footer.padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search installed skills", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .font(Extreme.font(12))
                Toggle("Updates", isOn: $model.onlyUpdates)
                    .toggleStyle(.button)
                    .font(Extreme.font(11))
                    .help("Only skills with an update")
            }
            .padding(10)
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(SkillGroup.allCases, id: \.self) { group in
                        let skills = model.skills(in: group)
                        if !skills.isEmpty { section(group, skills).id(group) }
                    }
                    if model.scanned, SkillGroup.allCases.allSatisfy({ model.skills(in: $0).isEmpty }) {
                        Text(model.onlyUpdates ? "Everything's up to date." : "No skills match.")
                            .font(Extreme.font(11)).foregroundColor(Extreme.dim)
                            .padding(.horizontal, 6)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            .onChange(of: model.scanned) { _ in
                if let group = model.selected?.group { scroller.scrollTo(group, anchor: .top) }
            }
            }
        }
        .background(Extreme.panel)
    }

    private func section(_ group: SkillGroup, _ skills: [InstalledSkill]) -> some View {
        let filtering = !model.search.isEmpty || model.onlyUpdates
        let folded = self.folded.contains(group) && !filtering
        let builtIn = skills.filter(Self.isBuiltIn)
        let shown = filtering || showBuiltIn.contains(group) ? skills : skills.filter { !Self.isBuiltIn($0) }
        let updates = skills.filter { model.statuses[$0.id] == .available }.count
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if self.folded.contains(group) { self.folded.remove(group) } else { self.folded.insert(group) }
            } label: {
                ExtremeSectionLabel(group.title) {
                    HStack(spacing: 6) {
                        if updates > 0 {
                            Text("\(updates) new").font(Extreme.font(10, weight: .semibold)).foregroundColor(Extreme.gold)
                        }
                        Text("\(skills.count)").font(Extreme.font(10)).foregroundColor(Extreme.dim)
                        Image(systemName: folded ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .bold)).foregroundColor(Extreme.dim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? "Show" : "Hide")
            if !folded {
                ForEach(shown) { skill in row(skill).id(skill.id) }
                if !builtIn.isEmpty, !filtering { builtInToggle(group, builtIn) }
            }
        }
    }

    private static func isBuiltIn(_ skill: InstalledSkill) -> Bool {
        if case .bundled = skill.origin { return true } else { return false }
    }

    private func builtInToggle(_ group: SkillGroup, _ builtIn: [InstalledSkill]) -> some View {
        let open = showBuiltIn.contains(group)
        var owner = group.title
        if case .bundled(let name)? = builtIn.first?.origin { owner = name }
        return Button {
            if open { showBuiltIn.remove(group) } else { showBuiltIn.insert(group) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                Text(open ? "Hide the \(builtIn.count) that come with \(owner)" : "\(builtIn.count) more come with \(owner)")
            }
            .font(Extreme.font(10.5))
            .foregroundColor(Extreme.dim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ skill: InstalledSkill) -> some View {
        let selected = model.selection == skill.id
        return Button { model.select(skill) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name).font(Extreme.font(12, weight: .semibold))
                        .foregroundColor(selected ? Extreme.gold : Extreme.text).lineLimit(1)
                    if skill.project {
                        Text("project").font(Extreme.font(9.5)).foregroundColor(Extreme.muted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Extreme.raised))
                    }
                    Spacer(minLength: 4)
                    StatusMark(status: model.statuses[skill.id] ?? .unknown)
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(2)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Extreme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skill.name), \(skill.summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        if let skill = model.selected {
            let status = model.statuses[skill.id] ?? .unknown
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(Extreme.font(17, weight: .semibold)).foregroundColor(Extreme.text)
                    if !skill.summary.isEmpty {
                        Text(skill.summary).font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(4)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(chips(skill), id: \.self) { chip($0) }
                }
                statusLine(skill, status)
                VStack(alignment: .leading, spacing: 3) {
                    Text((skill.folder as NSString).abbreviatingWithTildeInPath)
                        .font(Extreme.mono(10.5)).foregroundColor(Extreme.dim)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text("Read by " + ([skill.group] + skill.alsoIn).map(\.readBy).joined(separator: "; "))
                        .font(Extreme.font(10.5)).foregroundColor(Extreme.dim).lineLimit(2)
                }
                ScrollView {
                    Text(model.preview.isEmpty ? "This SKILL.md has no instructions." : model.preview)
                        .font(Extreme.mono(11.5))
                        .foregroundColor(Extreme.text.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Extreme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.skillFile)])
                    }
                    Button("Open SKILL.md") { NSWorkspace.shared.open(URL(fileURLWithPath: skill.skillFile)) }
                    if model.canRemove { Button("Remove…") { model.remove() } }
                    Spacer()
                    if status == .available || (skill.root != nil && skill.source != nil), SkillInventory.updateCommand(skill) != nil {
                        Button("Update") { model.update(skill) }
                            .buttonStyle(ExtremeButtonStyle(prominent: true))
                            .help(SkillInventory.updateCommand(skill) ?? "")
                    } else if case .plugin = skill.origin {
                        Button("Update Plugin") { model.update(skill) }
                            .help(SkillInventory.updateCommand(skill) ?? "")
                    } else if case .hermesHub = skill.origin {
                        Button("Update in Hermes") { model.update(skill) }
                            .help(SkillInventory.updateCommand(skill) ?? "")
                    }
                }
            }
            .padding(16)
        } else {
            Text(model.scanned ? "No skills installed yet. Find some in Discover." : "Looking…")
                .font(Extreme.font(12)).foregroundColor(Extreme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chips(_ skill: InstalledSkill) -> [String] {
        var result: [String] = []
        switch skill.origin {
        case .registry(let source, _, _, _): result.append(source)
        case .git(let remote): result.append(Self.shortRemote(remote))
        case .plugin(let id, let version): result.append(version.isEmpty ? id : "\(id) \(version)")
        case .bundled(let owner): result.append("Comes with \(owner)")
        case .hermesHub(let source): result.append("Hermes skills hub · \(source)")
        case .local: result.append("No source recorded")
        }
        result.append(skill.project ? "This project" : "All projects")
        if let modified = skill.modified {
            result.append("Changed " + modified.formatted(date: .abbreviated, time: .omitted))
        }
        return result
    }

    private static func shortRemote(_ remote: String) -> String {
        var s = remote
        for prefix in ["https://github.com/", "git@github.com:"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.hasSuffix(".git") ? String(s.dropLast(4)) : s
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Extreme.font(10.5))
            .foregroundColor(Extreme.text.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Extreme.raised))
            .overlay(Capsule().strokeBorder(Extreme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func statusLine(_ skill: InstalledSkill, _ status: SkillUpdateStatus) -> some View {
        HStack(spacing: 6) {
            StatusMark(status: status)
            Text(Self.describe(status)).font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
            if status == .untracked {
                Button("Find on skills.sh") { model.findSource(skill) }
                    .buttonStyle(.link)
                    .font(Extreme.font(11.5))
                    .help("Reinstalling it from skills.sh lets the app check it for updates")
            }
        }
    }

    static func describe(_ status: SkillUpdateStatus) -> String {
        switch status {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking for updates…"
        case .current: return "Up to date"
        case .available: return "A newer version is available"
        case .managed(let why): return why
        case .untracked: return "Nothing records where it came from, so it can't be checked for updates"
        case .failed(let why): return "Couldn't check: \(why)"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.updateCount == 0
                 ? "Skills from npx skills and git are checked against their source when this window opens."
                 : "\(model.updateCount) \(model.updateCount == 1 ? "skill has" : "skills have") an update. Updates run in a new tab so you can see what changes.")
                .lineLimit(2)
            Spacer()
            Button(model.checking ? "Checking…" : "Check for Updates") { model.checkUpdates(force: true) }
                .disabled(model.checking)
            if model.registryUpdates > 1 {
                Button("Update All (\(model.registryUpdates))") { model.updateAll() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .help(SkillInventory.updateAllCommand)
            }
        }
        .font(Extreme.font(10.5))
        .foregroundColor(Extreme.muted)
    }
}

/// A small mark for a skill's update status in lists.
private struct StatusMark: View {
    let status: SkillUpdateStatus

    var body: some View {
        switch status {
        case .checking: PixelSpinner(pixel: 3)
        case .available:
            Text("UPDATE").font(Extreme.font(9, weight: .bold)).kerning(0.6).foregroundColor(Extreme.ink)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Extreme.gold))
        case .current: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Extreme.live)
        case .failed: Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundColor(Extreme.warn)
        case .unknown, .managed, .untracked: EmptyView()
        }
    }
}

// MARK: Discover

private struct DiscoverPane: View {
    @ObservedObject var model: SkillsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list.frame(width: 380)
                Rectangle().fill(Extreme.line).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Extreme.line).frame(height: 1)
            HStack(spacing: 6) {
                Text("From skills.sh, the open directory that npx skills installs from. Skills are other people's code and instructions: read them before you trust them.")
                    .lineLimit(2)
                Spacer()
                Link("skills.sh ↗", destination: URL(string: "https://skills.sh")!)
            }
            .font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }
    }

    private var searchingText: Bool { model.query.trimmingCharacters(in: .whitespaces).count >= 2 }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search skills.sh", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(Extreme.font(12))
                .onChange(of: model.query) { _ in model.queryChanged() }
                .onSubmit { model.runSearch() }
            HStack(spacing: 8) {
                Picker("", selection: $model.board) {
                    ForEach(SkillDirectory.Board.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(searchingText)
                Toggle("Official", isOn: $model.showOfficial)
                    .toggleStyle(.checkbox)
                    .font(Extreme.font(11))
                    .help("Also show skills from the companies behind the tools (Anthropic, Vercel, Cloudflare…)")
            }
            Text(searchingText ? "Results for “\(model.query.trimmingCharacters(in: .whitespaces))”" : model.board.detail)
                .font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.loadingList || model.searching {
                        HStack(spacing: 8) { PixelSpinner(pixel: 3); Text("Loading…") }
                            .font(Extreme.font(11)).foregroundColor(Extreme.muted).padding(8)
                    } else if let error = model.listError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(Extreme.font(11)).foregroundColor(Extreme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if !searchingText { Button("Try Again") { model.loadBoard(force: true) } }
                        }
                        .padding(8)
                    } else {
                        ForEach(Array(model.visibleListing.enumerated()), id: \.element.id) { index, skill in
                            row(skill, rank: searchingText ? nil : index + 1)
                        }
                        if model.hiddenOfficial > 0 {
                            Text("\(model.hiddenOfficial) official \(model.hiddenOfficial == 1 ? "skill" : "skills") hidden")
                                .font(Extreme.font(10.5)).foregroundColor(Extreme.dim).padding(8)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Extreme.panel)
    }

    private func row(_ skill: ListedSkill, rank: Int?) -> some View {
        let selected = model.picked == skill
        return Button { model.picked = skill } label: {
            HStack(spacing: 8) {
                if let rank {
                    Text("\(rank)").font(Extreme.mono(10.5)).foregroundColor(Extreme.dim).frame(width: 26, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(skill.name).font(Extreme.font(12, weight: .semibold))
                            .foregroundColor(selected ? Extreme.gold : Extreme.text).lineLimit(1)
                        if model.installedCopy(of: skill) != nil {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 9.5)).foregroundColor(Extreme.live)
                                .help("Installed")
                        }
                    }
                    Text(skill.source).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    if let change = skill.change, !searchingText, model.board == .hot {
                        Text("+\(Self.count(change))").font(Extreme.mono(11)).foregroundColor(Extreme.live)
                    }
                    Text(Self.count(skill.installs)).font(Extreme.mono(11)).foregroundColor(Extreme.text.opacity(0.75))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Extreme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skill.name) from \(skill.source), \(skill.installs) installs")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func count(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: return "\(n / 1000)K"
        case 1000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let skill = model.picked {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(skill.name).font(Extreme.font(18, weight: .semibold)).foregroundColor(Extreme.text)
                            if skill.official || model.installedCopy(of: skill) != nil {
                                Text(model.installedCopy(of: skill) != nil ? "INSTALLED" : "OFFICIAL")
                                    .font(Extreme.font(9, weight: .bold)).kerning(0.6)
                                    .foregroundColor(model.installedCopy(of: skill) != nil ? Extreme.live : Extreme.muted)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .overlay(Capsule().strokeBorder(Extreme.line, lineWidth: 1))
                            }
                        }
                        HStack(spacing: 10) {
                            Text(skill.source).font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                            if let repo = skill.repo { Link(SkillInventory.isGitHub(skill.source) ? "GitHub ↗" : "Website ↗", destination: repo).font(Extreme.font(11.5)) }
                            if let page = skill.page { Link("skills.sh ↗", destination: page).font(Extreme.font(11.5)) }
                        }
                    }
                    Group {
                        if let summary = model.summary {
                            Text(summary).foregroundColor(Extreme.text.opacity(0.9))
                        } else {
                            Text(model.summaryLoaded ? "No description published for it." : "Loading description…")
                                .foregroundColor(Extreme.dim)
                        }
                    }
                    .font(Extreme.font(12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    if let other = model.sameName(as: skill) {
                        Text("You have a skill called “\(other.name)” with no recorded source (\((other.folder as NSString).abbreviatingWithTildeInPath)). Installing this one makes it trackable.")
                            .font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stats(skill)
                    audits
                    installBox(skill)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(model.loadingList ? "Loading…" : "Pick a skill to see what it does.")
                .font(Extreme.font(12)).foregroundColor(Extreme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stats(_ skill: ListedSkill) -> some View {
        HStack(alignment: .bottom, spacing: 18) {
            stat(Self.count(skill.installs), searchingText || model.board == .allTime ? "installs" : (model.board == .trending ? "installs today" : "installs this hour"))
            if let change = skill.change, model.board == .hot, !searchingText {
                stat("+\(Self.count(change))", "vs. this hour yesterday")
            }
            if let weeks = skill.weeklyInstalls, weeks.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    Sparkline(values: weeks).frame(width: 120, height: 26)
                    Text("last 8 weeks").font(Extreme.font(10)).foregroundColor(Extreme.dim)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Extreme.mono(18)).foregroundColor(Extreme.text)
            Text(label).font(Extreme.font(10)).foregroundColor(Extreme.dim)
        }
    }

    @ViewBuilder
    private var audits: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtremeSectionLabel("Security reviews")
            if let audits = model.audits {
                if audits.isEmpty {
                    Text("Nobody has reviewed this skill yet.").font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                }
                ForEach(audits) { audit in
                    HStack(alignment: .top, spacing: 8) {
                        Text(audit.status.uppercased())
                            .font(Extreme.font(9, weight: .bold)).kerning(0.6)
                            .foregroundColor(Self.color(audit.status))
                            .frame(width: 40, alignment: .leading)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(audit.provider + (audit.risk.map { " · \($0.lowercased()) risk" } ?? ""))
                                .font(Extreme.font(11.5, weight: .semibold)).foregroundColor(Extreme.text)
                            if !audit.summary.isEmpty {
                                Text(audit.summary).font(Extreme.font(11)).foregroundColor(Extreme.muted)
                                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) { PixelSpinner(pixel: 3); Text("Loading…") }
                    .font(Extreme.font(11)).foregroundColor(Extreme.muted)
            }
        }
    }

    private static func color(_ status: String) -> Color {
        switch status {
        case "pass": return Extreme.live
        case "warn": return Extreme.warn
        default: return Extreme.danger
        }
    }

    private func installBox(_ skill: ListedSkill) -> some View {
        let warned = model.audits?.contains { $0.status != "pass" } == true
        return VStack(alignment: .leading, spacing: 10) {
            ExtremeSectionLabel("Install")
            HStack(spacing: 14) {
                Text("For").font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                ForEach(SkillAgent.allCases) { agent in
                    Toggle(agent.title, isOn: Binding(
                        get: { model.agents.contains(agent) },
                        set: { on in if on { model.agents.insert(agent) } else { model.agents.remove(agent) } }))
                        .toggleStyle(.checkbox)
                        .font(Extreme.font(11.5))
                }
            }
            HStack(spacing: 10) {
                Text("In").font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                Picker("", selection: $model.inProject) {
                    Text("All projects").tag(false)
                    if let project = model.project {
                        Text("This project · \((project as NSString).lastPathComponent)").tag(true)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(model.installCommand(skill))
                .font(Extreme.mono(11))
                .foregroundColor(Extreme.text.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Extreme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
            HStack(spacing: 8) {
                if warned {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(Extreme.warn)
                    Text("A review flagged this skill. Read it before installing.")
                        .font(Extreme.font(11)).foregroundColor(Extreme.warn)
                }
                Spacer()
                Button(model.installedCopy(of: skill) != nil ? "Install Again" : "Install") { model.install(skill) }
                    .buttonStyle(ExtremeButtonStyle(prominent: !warned))
                    .disabled(model.agents.isEmpty)
                    .help("Runs this command in a new tab")
            }
        }
    }
}

/// Eight weeks of installs as a line.
private struct Sparkline: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            let top = max(values.max() ?? 1, 1)
            Path { path in
                for (i, value) in values.enumerated() {
                    let point = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                                        y: geo.size.height * (1 - CGFloat(value) / CGFloat(top)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(Extreme.gold, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
#endif
