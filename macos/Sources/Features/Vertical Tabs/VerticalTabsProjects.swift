#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Groups tabs whose agents work in the same project, so the sidebar can bracket them.
///
/// A tab belongs to the project of its agent's folder (the repository root, or the folder
/// itself outside git). When two or more tabs have agents in one project, every tab in that
/// project, agent or not, is grouped.
final class VerticalTabsProjects: ObservableObject {
    static let shared = VerticalTabsProjects()
    static let ungroupedKey = "VerticalTabsUngroupedProjects"

    struct Group: Equatable, Identifiable {
        /// The project's folder, compared ignoring case and symlinks.
        let id: String
        /// The project's folder as it is on disk.
        let root: String
        let name: String
        /// Its tabs, in no particular order (the sidebar orders them).
        let members: Set<ObjectIdentifier>
        /// Agent sessions working in the project (a tab can hold several, in splits).
        let agents: Int
    }

    @Published private(set) var groups: [String: Group] = [:]
    private var tabGroup: [ObjectIdentifier: String] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let center = NotificationCenter.default
        Publishers.Merge4(
            center.publisher(for: VerticalTabsAgents.didChange).map { _ in () },
            center.publisher(for: .verticalTabsNeedRefresh).map { _ in () },
            // A closed tab should leave its group right away, not on the next tick.
            center.publisher(for: NSWindow.willCloseNotification).map { _ in () },
            VerticalTabsTicker.shared.publisher)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &cancellables)
        UserDefaults.standard.publisher(for: \.verticalTabsUngroupedProjects)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        DispatchQueue.main.async { [weak self] in self?.recompute() }
    }

    func group(for controller: TerminalController) -> Group? {
        tabGroup[ObjectIdentifier(controller)].flatMap { groups[$0] }
    }

    /// Stop grouping this project (it can be grouped again from the tab's menu).
    func ungroup(_ group: Group) {
        var list = UserDefaults.standard.verticalTabsUngroupedProjects
        list.append(group.id)
        UserDefaults.standard.verticalTabsUngroupedProjects = list
    }

    func regroup(_ id: String) {
        UserDefaults.standard.verticalTabsUngroupedProjects.removeAll { $0 == id }
    }

    /// The project a tab works in, if any: where its agent is, or else its focused pane.
    /// `agents` counts its agent sessions in that project.
    static func project(of controller: TerminalController) -> (id: String, root: String, agents: Int)? {
        guard !HermesSessions.shared.isHermes(controller),
              LocalhostSessions.shared.session(for: controller) == nil else { return nil }
        let surfaces = Array(controller.surfaceTree)
        let agentSurfaces = surfaces.filter { surface in
            guard let kind = VerticalTabsAgents.shared.info(for: surface)?.kind else { return false }
            return kind != .hermes
        }
        guard let pwd = (agentSurfaces.first ?? controller.focusedSurface ?? surfaces.first)?.pwd,
              let id = projectID(of: pwd) else { return nil }
        let agents = agentSurfaces.filter { $0.pwd.flatMap(projectID(of:)) == id }.count
        return (id, LocalhostProject(folder: pwd).root, agents)
    }

    /// The project a folder belongs to, compared ignoring case; nil for a home folder or
    /// the disk, which aren't projects.
    private static func projectID(of folder: String) -> String? {
        let id = ProjectPath.canonical(LocalhostProject(folder: folder).root)
        let home = ProjectPath.canonical(NSHomeDirectory())
        guard id != home, id != "/", !home.hasPrefix(id + "/") else { return nil }
        return id
    }

    /// Tabs that are open. A closed tab's window can linger in the app's window list for a
    /// while after it closes.
    static var openControllers: [TerminalController] {
        TerminalController.all.filter { controller in
            guard let window = controller.window else { return false }
            if window.isVisible || window.isMiniaturized { return true }
            // A background tab isn't "visible", but it's still in its tab group.
            return window.tabGroup?.windows.contains(window) == true
                && window.tabGroup?.windows.contains { $0.isVisible || $0.isMiniaturized } == true
        }
    }

    private func recompute() {
        var members: [String: Set<ObjectIdentifier>] = [:]
        var agentTabs: [String: Int] = [:]
        var agents: [String: Int] = [:]
        var roots: [String: String] = [:]
        for controller in Self.openControllers {
            guard let project = Self.project(of: controller) else { continue }
            members[project.id, default: []].insert(ObjectIdentifier(controller))
            if project.agents > 0 { agentTabs[project.id, default: 0] += 1 }
            agents[project.id, default: 0] += project.agents
            if roots[project.id] == nil || project.agents > 0 { roots[project.id] = project.root }
        }
        let ungrouped = Set(UserDefaults.standard.verticalTabsUngroupedProjects)
        var next: [String: Group] = [:]
        // Grouping is across tabs (a tab's splits are already together).
        // A group forms with two agent tabs, and stays while it still has two tabs and an
        // agent, so one session finishing doesn't pull the sidebar apart.
        for (id, tabs) in members where !ungrouped.contains(id)
            && ((agentTabs[id] ?? 0) >= 2 || groups[id] != nil && tabs.count >= 2 && (agentTabs[id] ?? 0) >= 1) {
            let root = roots[id] ?? id
            next[id] = Group(id: id, root: root, name: ProjectPath.displayName(root), members: tabs, agents: agents[id] ?? 0)
        }
        guard next != groups else { return }
        tabGroup = [:]
        for group in next.values { for tab in group.members { tabGroup[tab] = group.id } }
        groups = next
    }
}

extension UserDefaults {
    @objc dynamic var verticalTabsUngroupedProjects: [String] {
        get { stringArray(forKey: VerticalTabsProjects.ungroupedKey) ?? [] }
        set { set(newValue, forKey: VerticalTabsProjects.ungroupedKey) }
    }
}

/// Comparing and naming project folders.
enum ProjectPath {
    /// A folder's path as the file system knows it, for comparing: symlinks resolved
    /// (/tmp is /private/tmp) and case ignored (macOS folders are case-insensitive, and a
    /// shell remembers the path the way it was typed).
    static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(path, &buffer) != nil ? String(cString: buffer) : (path as NSString).standardizingPath
        return resolved.lowercased()
    }

    /// The folder's name as it's spelled on disk.
    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.nameKey]).name) ?? url.lastPathComponent
    }
}

// MARK: - Sidebar

/// A bracket around the tabs that work in one project, with the project's state at the top.
struct VerticalTabsProjectGroupView<Content: View>: View {
    let group: VerticalTabsProjects.Group
    let controllers: [TerminalController]
    let owner: TerminalController
    @ViewBuilder let content: () -> Content

    @AppStorage("VerticalTabsCollapsedProjects") private var collapsedList = ""
    @State private var summary = ProjectGroupSummary()
    @State private var hovering = false
    @ObservedObject private var localhost = LocalhostSessions.shared

    private var collapsed: Bool { collapsedList.split(separator: "\n").contains { $0 == group.id } }
    private var color: Color { LocalhostProject(folder: group.root).color }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !summary.overlaps.isEmpty { overlapWarning }
            if !collapsed {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 6)
        .background(
            LinearGradient(colors: [color.opacity(0.07), color.opacity(0.02)], startPoint: .leading, endPoint: .trailing)
                .padding(.leading, 10))
        .overlay(alignment: .leading) {
            ProjectBracket(color: color, state: summary.state)
                .frame(width: 10)
                .padding(.leading, 6)
                .allowsHitTesting(false)
        }
        .onAppear(perform: update)
        .onReceive(VerticalTabsTicker.shared.publisher) {
            guard owner.window?.occlusionState.contains(.visible) == true else { return }
            update()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: collapsed)
        .animation(.easeOut(duration: 0.2), value: summary)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            statusLine.padding(.leading, 14)
        }
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .onTapGesture(count: 2, perform: toggleCollapse)
        .contextMenu {
            Button("Open \(group.name) in Code Editor") { EditorPanel.shared.show(from: owner, folder: group.root) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.root)]) }
            Divider()
            Button(collapsed ? "Show Tabs" : "Fold Tabs", action: toggleCollapse)
            Button("Don't Group \(group.name)") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { VerticalTabsProjects.shared.ungroup(group) }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 7) {
            Rectangle().fill(color).frame(width: 7, height: 7).shadow(color: color.opacity(0.8), radius: 3)
            Text(group.name)
                .font(Tellurion.font(12.5, weight: .semibold))
                .foregroundColor(Tellurion.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(group.agents == 1 ? "1 agent" : "\(group.agents) agents")
                .font(Tellurion.font(10, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 1))
                .fixedSize()
            Spacer(minLength: 2)
            if let server = projectServer, let url = server.url {
                Button {
                    VisualFixPanel.shared.show(from: owner, url: url)
                } label: {
                    HStack(spacing: 3) {
                        PixelDot(color: Tellurion.live, size: 4)
                        Text(verbatim: ":\(url.port ?? 80)").font(Tellurion.font(9.5)).foregroundColor(Tellurion.gold)
                        PixelIconView(icon: .target, color: Tellurion.gold, pixel: 0.9)
                    }
                    .padding(.horizontal, 4).frame(height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tellurion.gold.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("\(group.name) is live at \(LocalhostAddress.display(url)). Click to fix it visually")
                .fixedSize()
            }
            if hovering {
                headerButton(.code, help: "Open \(group.name) in the code editor") {
                    EditorPanel.shared.show(from: owner, folder: group.root)
                }
                .transition(.opacity)
            }
            Button(action: toggleCollapse) {
                PixelIconView(icon: collapsed ? .chevronRight : .chevronDown, color: Tellurion.muted, pixel: 1.25)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the project's tabs" : "Fold the project's tabs")
        }
    }

    /// "2 working · 1 waiting", with a live marker for each.
    private var statusLine: some View {
        HStack(spacing: 8) {
            if summary.working > 0 {
                HStack(spacing: 4) {
                    PixelSpinner(color: Tellurion.core, pixel: 1.5)
                    Text("\(summary.working) working").foregroundColor(Tellurion.core)
                }
            }
            if summary.waiting > 0 {
                HStack(spacing: 4) {
                    PixelDot(color: Tellurion.warn, blinking: true, size: 4, interval: 0.3)
                    Text("\(summary.waiting) waiting").foregroundColor(Tellurion.warn)
                }
            }
            if summary.done > 0 {
                HStack(spacing: 4) {
                    PixelDot(color: Tellurion.live, size: 4)
                    Text("\(summary.done) done").foregroundColor(Tellurion.live)
                }
            }
            if summary.working + summary.waiting + summary.done == 0 {
                Text((group.root as NSString).abbreviatingWithTildeInPath).foregroundColor(Tellurion.dim).lineLimit(1)
            }
        }
        .font(Tellurion.font(9.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var overlapWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("!").font(Tellurion.font(10)).foregroundColor(Tellurion.ink)
                .frame(width: 13, height: 13).background(Tellurion.warn)
            Text("Both changed \(summary.overlaps.prefix(3).joined(separator: ", "))"
                 + (summary.overlaps.count > 3 ? " and \(summary.overlaps.count - 3) more" : "")
                 + ". Check they don't conflict.")
                .font(Tellurion.font(9.5))
                .foregroundColor(Tellurion.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 10)
        .help("More than one agent in \(group.name) changed these files. Review before committing.")
        .onTapGesture { ReviewInbox.show() }
    }

    private func headerButton(_ icon: PixelIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PixelIconView(icon: icon, color: Tellurion.text.opacity(0.85), pixel: 1.1)
                .frame(width: 20, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tellurion.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleCollapse() {
        var ids = collapsedList.split(separator: "\n").map(String.init)
        if let index = ids.firstIndex(of: group.id) { ids.remove(at: index) } else { ids.append(group.id) }
        collapsedList = ids.joined(separator: "\n")
    }

    /// The project's running server, if one is live.
    private var projectServer: LocalhostSession? {
        localhost.sessions.last { $0.state == .live && ProjectPath.canonical($0.project.root) == group.id }
    }

    // MARK: State

    private func update() {
        var next = ProjectGroupSummary()
        var changedBy: [String: Set<ObjectIdentifier>] = [:]
        for controller in controllers where VerticalTabsProjects.openControllers.contains(where: { $0 === controller }) {
            for surface in controller.surfaceTree {
                guard let info = VerticalTabsAgents.shared.info(for: surface), info.kind != .hermes else { continue }
                switch info.activity {
                case .working: next.working += 1
                case .needsPermission, .needsInput: next.waiting += 1
                case .done: next.done += 1
                default: break
                }
                for file in ReviewInbox.shared.item(for: surface)?.files ?? [] {
                    changedBy[file.path, default: []].insert(ObjectIdentifier(surface))
                }
            }
        }
        next.overlaps = changedBy.filter { $0.value.count > 1 }.map(\.key).sorted()
        if next != summary { summary = next }
    }
}

/// What a project's agents are up to.
struct ProjectGroupSummary: Equatable {
    enum State: Equatable { case idle, working, waiting }
    var working = 0
    var waiting = 0
    var done = 0
    /// Files more than one of the project's agents changed.
    var overlaps: [String] = []

    var state: State { waiting > 0 ? .waiting : working > 0 ? .working : .idle }
}

/// The group's bracket: a line down its left side with corner ticks. A light runs down it
/// while an agent works; its corners blink when one needs you.
private struct ProjectBracket: View {
    let color: Color
    let state: ProjectGroupSummary.State
    @Environment(\.tellurionMotion) private var motion

    var body: some View {
        // Core Animation layers: the falling light and the blink cost the app nothing per frame.
        BracketLights(color: color, state: motion ? state : (state == .working ? .idle : state))
    }
}
#endif
