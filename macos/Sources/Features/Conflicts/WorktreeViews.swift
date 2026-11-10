#if os(macOS)
import AppKit
import SwiftUI

/// The composers' "Give each agent its own worktree" switch: whether it can be on for the
/// chosen folder, making the worktrees when a group starts, and what went wrong if it did.
final class WorktreeChoice: ObservableObject {
    enum State: Equatable {
        case checking
        case ready
        case unavailable(String)
    }

    /// What's starting: the group's name, each slot's agent ("claude", "codex", … or
    /// "shell"), and the folder they'd all have shared.
    struct Request {
        let group: String
        let kinds: [String]
        /// A name per slot (an orchestrator's roles). Without them, agents get the names
        /// their tiles will have.
        var names: [String]?
        let folder: String?
    }

    /// The switch as the user left it. On until they turn it off.
    @Published var wanted = true
    @Published private(set) var state: State = .checking
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private var checks = 0
    private static let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.worktrees", qos: .userInitiated)

    /// Looks at `folder` (off the main thread): a git repository with a commit, or why not.
    func check(_ folder: String?) {
        guard TellurionSettings.isOn(.conflicts) else { return }
        error = nil
        state = .checking
        checks += 1
        let check = checks
        Self.queue.async {
            let result = AgentWorktrees.repository(of: folder)
            DispatchQueue.main.async {
                guard check == self.checks else { return }
                switch result {
                case .success: self.state = .ready
                case .failure(let failure): self.state = .unavailable(failure.message)
                }
            }
        }
    }

    /// Why the switch can't be on, if it can't: one line.
    func reason(agents: Int) -> String? {
        if agents < 2 { return "For groups of two or more agents." }
        switch state {
        case .checking: return "Checking the folder…"
        case .unavailable(let why): return why
        case .ready: return nil
        }
    }

    func isOn(agents: Int) -> Bool {
        TellurionSettings.isOn(.conflicts) && wanted && reason(agents: agents) == nil
    }

    /// Starts a group. With the switch on, the worktrees are made first and `launch` gets a
    /// folder per slot; if making any fails, nothing is launched and `error` says why. With
    /// it off, `launch` gets nil and starts everyone in the one folder, as before. `launch`
    /// returns the new group's id when it makes one; `done` closes the composer.
    func start(_ request: Request, on board: BoardController, launch: @escaping ([String]?) -> UUID?, done: @escaping () -> Void) {
        guard !busy else { return }
        error = nil
        let agents = request.kinds.filter { $0 != "shell" }.count
        // Still checking counts as on: making the worktrees checks the folder again.
        var unavailable = false
        if case .unavailable = state { unavailable = true }
        let on = TellurionSettings.isOn(.conflicts) && wanted && agents >= 2 && !unavailable
        guard on, let folder = request.folder, !folder.isEmpty else {
            _ = launch(nil)
            done()
            return
        }
        // Agent tiles are named as they'd be named anyway, so a branch says whose it is.
        let named = request.names == nil && BoardAgentNames.enabled
        var taken = Set(board.model.titles.values)
        var counts: [String: Int] = [:]
        let labels: [String] = request.names ?? request.kinds.map { kind in
            if named, kind != "shell" {
                let name = BoardAgentNames.next(taken: taken)
                taken.insert(name)
                return name
            }
            counts[kind, default: 0] += 1
            return "\(kind)-\(counts[kind] ?? 1)"
        }
        busy = true
        Self.queue.async { [weak board] in
            let result = AgentWorktrees.create(group: request.group, agents: labels, folder: folder)
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .failure(let failure):
                    self.error = failure.message
                case .success(let records):
                    guard let board else {
                        // The board closed meanwhile: nothing will run in them.
                        Self.queue.async { for record in records { _ = AgentWorktrees.remove(record, how: .ifNothingIsLost) } }
                        return
                    }
                    AgentWorktreeList.shared.add(records)
                    let group = launch(records.map(\.startFolder))
                    let tiles = group.flatMap { board.namedGroup($0)?.tiles } ?? []
                    AgentWorktreeList.shared.attach(records.map(\.id), board: board.workspace.id, group: group, tiles: tiles)
                    if named, tiles.count == records.count {
                        for (index, tile) in tiles.enumerated() where request.kinds[index] != "shell" && board.model.titles[tile] == nil {
                            guard let view = board.model.surfaces.first(where: { $0.id == tile }) else { continue }
                            board.setTitle(records[index].agent, for: view)
                        }
                    }
                    done()
                }
            }
        }
    }
}

/// The switch itself, for a composer: off and disabled with the reason when the group has
/// fewer than two agents or the folder isn't a git repository with a commit.
struct WorktreeOptionRow: View {
    @ObservedObject var choice: WorktreeChoice
    /// The folder the group starts in.
    let folder: String?
    /// How many of its slots are agents.
    let agents: Int
    @ObservedObject private var settings = TellurionSettings.shared

    static let help = """
    Each agent starts in its own copy of the repository (a git worktree) on its own new branch, \
    made from the current commit, so agents can't overwrite each other's files. Uncommitted changes \
    aren't copied. The copies are kept in Tellurion's folder, not in your project; see Worktrees \
    in a group's menu to compare or remove them.
    """

    var body: some View {
        if settings.isOn(.conflicts) {
            let reason = choice.reason(agents: agents)
            Toggle(isOn: Binding(get: { choice.isOn(agents: agents) }, set: { choice.wanted = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Give each agent its own worktree").font(Tellurion.font(11.5, weight: .medium))
                        .foregroundColor(reason == nil ? Tellurion.text : Tellurion.muted)
                    Text(detail(reason))
                        .font(Tellurion.font(10.5)).foregroundColor(choice.error == nil ? Tellurion.dim : Tellurion.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(reason != nil || choice.busy)
            .help(Self.help)
            .onAppear { choice.check(folder) }
            .onChange(of: folder) { choice.check($0) }
        }
    }

    private func detail(_ reason: String?) -> String {
        if let error = choice.error { return "Nothing was started. \(error)" }
        if choice.busy { return "Making worktrees…" }
        if let reason { return reason }
        return choice.wanted
            ? "Each on its own new branch from the current commit. Uncommitted changes aren't copied."
            : "Everyone works in the same folder."
    }
}

/// The Worktrees list: every worktree made for a group's agents, with its folder, what its
/// agent changed, and removing it.
enum AgentWorktreesWindow {
    static let windowID = "agent-worktrees"

    static func show() {
        AgentToolWindows.show(id: windowID, title: "Worktrees", size: NSSize(width: 680, height: 520)) {
            AgentWorktreesView()
        }
    }

    /// Whether there's anything to show it for: the feature is on, or worktrees it made are
    /// still around to clean up.
    static var isOffered: Bool {
        TellurionSettings.isOn(.conflicts) || !AgentWorktreeList.shared.records.isEmpty
    }

    /// The command palette's entry.
    static func paletteOption() -> CommandOption? {
        guard isOffered else { return nil }
        return CommandOption(
            title: "Worktrees",
            description: "The copies of a repository made for a group's agents: open, compare or remove them",
            leadingIcon: "arrow.triangle.branch"
        ) {
            show()
        }
    }

    /// A group's menu gets "Worktrees…".
    static func addMenuItem(to menu: NSMenu) {
        guard isOffered else { return }
        menu.addItem(ClosureMenuItem("Worktrees…", image: nil) { show() })
    }

    /// Everything a worktree's agent changed since it started, in a window of its own.
    static func showDiff(_ record: AgentWorktrees.Record) {
        AgentToolWindows.show(id: "worktree-diff-\(record.id.uuidString)", title: "\(record.agent) · \(record.branch)",
                              size: NSSize(width: 760, height: 560)) {
            WorktreeDiffView(record: record)
        }
    }
}

private let worktreeQueue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.worktree-list", qos: .userInitiated)

private struct AgentWorktreesView: View {
    @ObservedObject private var list = AgentWorktreeList.shared
    @State private var standings: [UUID: AgentWorktrees.Standing] = [:]
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TellurionWindowTitle(icon: nil, title: "Worktrees", subtitle: "A copy of the repository for each agent of a group, on its own branch")
                Spacer()
                Button("Refresh", action: reload).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            if list.records.isEmpty {
                VStack(spacing: 6) {
                    Text("No worktrees yet").font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text("Start a group on a board with “Give each agent its own worktree” on, and its agents' copies appear here.")
                        .font(Tellurion.font(11.5, weight: .regular)).foregroundColor(Tellurion.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let failure {
                            Text(failure).font(Tellurion.font(11.5)).foregroundColor(Tellurion.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(list.records.reversed()) { record in row(record) }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func row(_ record: AgentWorktrees.Record) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.agent).font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text("\(record.group) · \(record.repoName)").font(Tellurion.font(11.5, weight: .regular)).foregroundColor(Tellurion.muted)
                        .lineLimit(1)
                }
                Text(record.branch).font(Tellurion.mono(11)).foregroundColor(Tellurion.bronze).lineLimit(1).truncationMode(.middle)
                Text(standings[record.id]?.summary ?? "Checking…")
                    .font(Tellurion.font(11, weight: .regular))
                    .foregroundColor(standings[record.id]?.hasWork == true ? Tellurion.warn : Tellurion.dim)
            }
            Spacer(minLength: 12)
            Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: record.path, isDirectory: true)) }
                .disabled(standings[record.id]?.missing == true)
            Button("Diff") { AgentWorktreesWindow.showDiff(record) }
                .disabled(standings[record.id]?.missing == true)
                .help("What its agent changed since it started")
            Button("Remove…") {
                failure = nil
                AgentWorktreeRemoval.confirm(record) { problem in
                    failure = problem
                    reload()
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .tellurionPanel()
    }

    private func reload() {
        let records = list.records
        worktreeQueue.async {
            var found: [UUID: AgentWorktrees.Standing] = [:]
            for record in records { found[record.id] = AgentWorktrees.standing(of: record) }
            DispatchQueue.main.async { standings = found }
        }
    }
}

private struct WorktreeDiffView: View {
    let record: AgentWorktrees.Record
    @State private var text = ""
    @State private var error: String? = "Comparing…"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TellurionWindowTitle(icon: nil, title: record.agent,
                                     subtitle: "\(record.branch), since it started from \(record.baseBranch ?? String(record.base.prefix(8)))")
                Spacer()
                Button("Refresh", action: load).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            AgentDiffView(text: text, error: error)
        }
        .onAppear(perform: load)
    }

    private func load() {
        worktreeQueue.async {
            let diff = AgentWorktrees.diff(of: record)
            DispatchQueue.main.async {
                text = diff.text
                error = diff.error
            }
        }
    }
}

/// Removing a worktree always asks first, and never discards work that isn't merged unless
/// that's the button the user pressed.
enum AgentWorktreeRemoval {
    /// Asks, removes, and takes the worktree off the list. `completion` gets what went
    /// wrong, or nil (also when the user cancelled).
    static func confirm(_ record: AgentWorktrees.Record, completion: @escaping (String?) -> Void) {
        worktreeQueue.async {
            let standing = AgentWorktrees.standing(of: record)
            DispatchQueue.main.async {
                guard let how = ask(record, standing) else {
                    completion(nil)
                    return
                }
                worktreeQueue.async {
                    let result = AgentWorktrees.remove(record, how: how)
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            AgentWorktreeList.shared.forget(record.id)
                            completion(nil)
                        case .failure(let failure):
                            completion("\(record.agent): \(failure.message)")
                        }
                    }
                }
            }
        }
    }

    /// The question, by what removing would lose. Nil: cancelled.
    private static func ask(_ record: AgentWorktrees.Record, _ standing: AgentWorktrees.Standing) -> AgentWorktrees.Removal? {
        let inUse = TerminalWindows.surfaces.contains { entry in
            entry.surface.pwd.map { $0 == record.path || $0.hasPrefix(record.path + "/") } ?? false
        }
        let open = inUse ? "\n\nA terminal is still open in it. Close it first, or its folder disappears under it." : ""
        let alert = NSAlert()
        if standing.hasWork {
            alert.alertStyle = .warning
            alert.messageText = "\(record.agent)'s worktree has work that isn't merged"
            alert.informativeText = """
            \(standing.summary.prefix(1).uppercased() + standing.summary.dropFirst()) on \(record.branch). Merge or commit it first, \
            or choose what to do with it.\(open)
            """
            alert.addButton(withTitle: "Cancel")
            var choices: [AgentWorktrees.Removal] = []
            if !standing.uncommitted {
                alert.addButton(withTitle: "Remove Folder, Keep Branch")
                choices.append(.keepingBranch)
            }
            alert.addButton(withTitle: "Discard Work and Remove")
            alert.buttons.last?.hasDestructiveAction = true
            choices.append(.discardingWork)
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue - 1
            return choices.indices.contains(index) ? choices[index] : nil
        }
        alert.messageText = "Remove \(record.agent)'s worktree?"
        alert.informativeText = standing.missing
            ? "Its folder is already gone. Its branch \(record.branch) is removed too; everything on it is merged.\(open)"
            : "Its folder and its branch \(record.branch) are removed. Everything on the branch is already merged, and nothing in the folder is uncommitted.\(open)"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // Return cancels: removing isn't something to do by accident.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn ? .ifNothingIsLost : nil
    }
}
#endif
