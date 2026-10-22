#if os(macOS)
import AppKit
import SwiftUI

/// Boards grouped by project: a board's project is its folder's (the top of its git checkout).
/// The top bar of a board shows Home, its project, the project's other boards as tabs, how
/// many agents are live and when your usage resets; Home lists every project and its boards.
final class BoardProjectsIndex: ObservableObject {
    static let shared = BoardProjectsIndex()

    struct Project: Identifiable {
        let id: String
        let name: String
        let folder: String?
        var boards: [BoardWorkspace]
    }

    @Published private(set) var projects: [Project] = []
    private var observer: NSObjectProtocol?

    private init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: BoardController.boardsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    static func key(of workspace: BoardWorkspace) -> String {
        workspace.folder.flatMap(BoardProjects.project(of:)) ?? workspace.folder ?? ""
    }

    func reload() {
        var byKey: [String: Project] = [:]
        for workspace in BoardStore.all() {
            let key = Self.key(of: workspace)
            let name = key.isEmpty ? "No project" : BoardProjects.name(key)
            byKey[key, default: Project(id: key, name: name, folder: key.isEmpty ? nil : key, boards: [])].boards.append(workspace)
        }
        projects = byKey.values.sorted { ($0.boards.first?.updated ?? .distantPast) > ($1.boards.first?.updated ?? .distantPast) }
    }

    func project(_ key: String) -> Project? { projects.first { $0.id == key } }
}

enum BoardHome {
    static func show() {
        AgentToolWindows.show(id: "board-home", title: "Tellurion", size: NSSize(width: 1000, height: 660)) {
            BoardHomeView()
        }
    }

    static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// Agents on an open board that need you.
    static func waiting(_ id: UUID) -> Int {
        guard let board = BoardController.all.first(where: { $0.workspace.id == id }) else { return 0 }
        return board.model.surfaces.filter { surface in
            VerticalTabsAgents.shared.info(for: surface).map { AgentAlerts.isWaiting($0.activity) } ?? false
        }.count
    }

    /// A new board in a project's folder.
    static func newBoard(in folder: String?) {
        guard let ghostty else { return }
        Board.newBoard(ghostty, folder: folder)
    }

    /// Asks for a project folder, then opens a board there.
    static func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.begin { response in
            if response == .OK, let url = panel.url { newBoard(in: url.path) }
        }
    }
}

// MARK: - Top bar

/// ← Home · project ⌄ · its boards as tabs · + · Close, then live agents and usage.
struct BoardTopBar: View {
    let controller: BoardController
    /// Not observed: the bar would redraw on every pan and zoom. It follows agents and tiles.
    let model: BoardModel
    @State private var liveCount = 0
    @State private var waiting: [UUID: Int] = [:]
    @ObservedObject private var index = BoardProjectsIndex.shared
    @ObservedObject private var usage = UsageMonitor.shared
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        let key = BoardProjectsIndex.key(of: controller.workspace)
        let project = index.project(key)
        HStack(spacing: 6) {
            pill { BoardHome.show() } label: { Label("Home", systemImage: "chevron.left") }
            Menu {
                ForEach(index.projects) { other in
                    Button(other.name) {
                        if let first = other.boards.first, let ghostty = BoardHome.ghostty { Board.reopen(ghostty, first) }
                    }
                }
                Divider()
                Button("New Project…") { BoardHome.chooseProject() }
            } label: {
                Label(project?.name ?? "No project", systemImage: "folder").font(Extreme.font(12, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Extreme.panel.opacity(0.95)))
            .overlay(Capsule().strokeBorder(Extreme.lineStrong))
            ForEach(project?.boards ?? [], id: \.id) { board in tab(board) }
            pill { BoardHome.newBoard(in: project?.folder ?? controller.workspace.folder) } label: { Image(systemName: "plus") }
                .help("New board in this project")
            pill { controller.window?.performClose(nil) } label: { Label("Close", systemImage: "xmark") }
            Rectangle().fill(Extreme.line).frame(width: 1, height: 18).padding(.horizontal, 2)
            live
            if let reset = soonestReset {
                pill { if ExtremeSettings.isOn(.accounts) { model.showAccounts = true } } label: {
                    Label("resets \(Self.time(reset))", systemImage: "clock").font(Extreme.font(11.5))
                }
                .help("When your usage limit resets next. Click for accounts.")
            }
        }
        .fixedSize()
        .onReceive(model.$agentTick) { _ in DispatchQueue.main.async { refreshCounts() } }
        .onReceive(model.$surfaces) { _ in DispatchQueue.main.async { refreshCounts() } }
    }

    private func refreshCounts() {
        let count = model.surfaces.filter { VerticalTabsAgents.shared.info(for: $0) != nil }.count
        if count != liveCount { liveCount = count }
        let boards = index.project(BoardProjectsIndex.key(of: controller.workspace))?.boards ?? []
        let counts = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, BoardHome.waiting($0.id)) })
        if counts != waiting { waiting = counts }
    }

    private func tab(_ board: BoardWorkspace) -> some View {
        let current = board.id == controller.workspace.id
        let waiting = self.waiting[board.id] ?? 0
        return Button {
            if !current, let ghostty = BoardHome.ghostty { Board.reopen(ghostty, board) }
        } label: {
            HStack(spacing: 5) {
                Text(board.name).font(Extreme.font(12, weight: current ? .semibold : .regular)).lineLimit(1)
                if waiting > 0 {
                    Text("\(waiting)").font(Extreme.font(10, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 5).frame(height: 15).background(Capsule().fill(Color.red))
                }
            }
            .foregroundColor(current ? Extreme.text : Extreme.muted)
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(current ? Extreme.raised : Extreme.panel.opacity(0.95)))
            .overlay(Capsule().strokeBorder(current ? Extreme.core.opacity(0.7) : Extreme.lineStrong))
        }
        .buttonStyle(.plain)
    }

    private var live: some View {
        let count = liveCount
        return HStack(spacing: 5) {
            Circle().fill(count > 0 ? Color.green : Extreme.dim).frame(width: 6, height: 6)
            Text("\(count) live").font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(Extreme.panel.opacity(0.95)))
        .overlay(Capsule().strokeBorder(Extreme.lineStrong))
        .help("Agents running on this board")
    }

    /// The next time any usage window resets.
    private var soonestReset: Date? {
        usage.entries.flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > Date() }.min()
    }

    static func time(_ date: Date) -> String {
        let formatter = Calendar.current.isDateInToday(date) ? today : later
        return formatter.string(from: date)
    }

    private static let today = formatter("h:mma")
    private static let later = formatter("EEE h:mma")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }

    private func pill<Content: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> Content) -> some View {
        Button(action: action) {
            label().font(Extreme.font(12, weight: .medium)).foregroundColor(Extreme.text)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(Extreme.panel.opacity(0.95)))
                .overlay(Capsule().strokeBorder(Extreme.lineStrong))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Git chip

/// The board folder's branch and how much it has changed; click for the Git panel.
struct BoardGitChip: View {
    let controller: BoardController
    @ObservedObject private var git = VerticalTabsGit.shared
    @State private var showPanel = false

    var body: some View {
        let folder = controller.documentsProject
        if let folder, let info = git.info(for: folder) {
            Button { showPanel.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5, weight: .semibold))
                    Text(info.branch).font(Extreme.mono(11.5)).lineLimit(1)
                    if info.added + info.removed > 0 {
                        Text("+\(info.added) −\(info.removed)").font(Extreme.mono(10.5)).foregroundColor(Extreme.core)
                    }
                }
                .foregroundColor(Extreme.text)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(Extreme.panel.opacity(0.95)))
                .overlay(Capsule().strokeBorder(Extreme.lineStrong))
            }
            .buttonStyle(.plain)
            .help("Changes in \((folder as NSString).abbreviatingWithTildeInPath)")
            .popover(isPresented: $showPanel) {
                GitPanelView(controller: controller, pwd: folder, root: git.root(for: folder) ?? folder) { showPanel = false }
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
                .onAppear { if let folder { git.track(folder) } }
        }
    }
}

// MARK: - Home

/// Every project and its boards.
struct BoardHomeView: View {
    @ObservedObject private var index = BoardProjectsIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Projects").font(Extreme.font(22, weight: .bold)).foregroundColor(Extreme.text)
                    Text("Each project's boards. Open one to carry on where you left off.").font(Extreme.font(12)).foregroundColor(Extreme.muted)
                }
                Spacer()
                Button("New Project…") { BoardHome.chooseProject() }
                .buttonStyle(ExtremeButtonStyle(prominent: true))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(index.projects) { project in card(project) }
                }
            }
        }
        .padding(26)
        .frame(minWidth: 640, minHeight: 420)
        .background(Extreme.ink)
        .onAppear { index.reload() }
    }

    private func card(_ project: BoardProjectsIndex.Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundColor(Extreme.core)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(Extreme.font(14, weight: .semibold)).foregroundColor(Extreme.text)
                    if let folder = project.folder {
                        Text((folder as NSString).abbreviatingWithTildeInPath).font(Extreme.mono(10.5)).foregroundColor(Extreme.dim)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button { BoardHome.newBoard(in: project.folder) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundColor(Extreme.muted).help("New board in this project")
            }
            ForEach(project.boards, id: \.id) { board in
                Button {
                    if let ghostty = BoardHome.ghostty { Board.reopen(ghostty, board) }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(BoardController.all.contains { $0.workspace.id == board.id } ? Color.green : Extreme.dim)
                            .frame(width: 6, height: 6)
                        Text(board.name).font(Extreme.font(12.5)).foregroundColor(Extreme.text).lineLimit(1)
                        Spacer()
                        Text("\(board.tiles.count) tile\(board.tiles.count == 1 ? "" : "s")").font(Extreme.font(11)).foregroundColor(Extreme.dim)
                        Text(board.updated, style: .relative).font(Extreme.font(11)).foregroundColor(Extreme.dim)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Extreme.raised))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Extreme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Extreme.line))
    }
}
#endif
