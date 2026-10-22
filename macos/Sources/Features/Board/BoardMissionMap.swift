#if os(macOS)
import AppKit
import SwiftUI

/// The Mission Map: who runs whom on this board. Orchestrators on the left, the groups they
/// (or you) made in the middle, and every agent on the right, wired to its group or straight
/// to its orchestrator; agents on neither hang off "Command bar" (reached by @). Filter by
/// status, search, select anything to see what it's doing and act on it, double-click to go
/// there.
enum MissionNodeKind { case orchestrator, commandBar, group, agent }

enum MissionStatus: CaseIterable {
    case working, needsYou, idle, done

    var title: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .idle: return "Idle"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .working: return AgentStatusPill.color(.working)
        case .needsYou: return .orange
        case .idle: return .secondary
        case .done: return .green
        }
    }

    init(_ activity: VerticalTabAgentActivity?) {
        switch activity {
        case .working: self = .working
        case .needsPermission, .needsInput, .failed: self = .needsYou
        case .done: self = .done
        default: self = .idle
        }
    }
}

struct MissionNode: Identifiable, Equatable {
    let id: String
    let kind: MissionNodeKind
    let title: String
    let detail: String
    let color: Color
    var status: MissionStatus?
    /// The tile, card or group it stands for.
    let target: UUID?
}

struct MissionEdge: Hashable {
    let from: String
    let to: String
    /// Reached only through the command bar.
    let dashed: Bool
}

struct MissionGraph {
    var orchestrators: [MissionNode] = []
    var groups: [MissionNode] = []
    var agents: [MissionNode] = []
    var edges: [MissionEdge] = []
    /// Who each node is wired to, either way (for lighting a hovered node's wires).
    var neighbors: [String: Set<String>] = [:]

    var all: [MissionNode] { orchestrators + groups + agents }

    init() {}

    init(board: BoardController) {
        let model = board.model
        var seen = Set<MissionEdge>()
        var edges: [MissionEdge] = []
        func link(_ edge: MissionEdge) { if seen.insert(edge).inserted { edges.append(edge) } }
        defer {
            self.edges = edges
            for edge in edges {
                neighbors[edge.from, default: []].insert(edge.to)
                neighbors[edge.to, default: []].insert(edge.from)
            }
        }
        var placed = Set<UUID>()
        // Groups: yours, then project groups an orchestrator wired.
        var groupIDs: [String: String] = [:]
        for group in model.groups {
            let id = "g:" + group.id.uuidString
            groupIDs[BoardTeams.groupKey(group.id)] = id
            let surfaces = board.groupSurfaces(group)
            let running = surfaces.filter { VerticalTabsAgents.shared.info(for: $0)?.activity == .working }.count
            groups.append(MissionNode(id: id, kind: .group, title: group.name, detail: "\(surfaces.count) · \(running > 0 ? "\(running) running" : "idle")",
                                      color: Color(nsColor: group.nsColor), target: group.id))
            for surface in surfaces { link(MissionEdge(from: id, to: "a:" + surface.id.uuidString, dashed: false)) }
        }
        for team in model.teams {
            for key in team.groups where groupIDs[key] == nil {
                let id = "p:" + key
                groupIDs[key] = id
                let surfaces = board.groupTiles(key)
                groups.append(MissionNode(id: id, kind: .group, title: board.groupTitle(key), detail: "\(surfaces.count) · project",
                                          color: Color(nsColor: BoardProjects.nsColor(model.colors[key] ?? 0)), target: nil))
                for surface in surfaces { link(MissionEdge(from: id, to: "a:" + surface.id.uuidString, dashed: false)) }
            }
        }
        // Orchestrators, wired to their groups and to agents wired one by one.
        for team in model.teams {
            let id = "o:" + team.id.uuidString
            let agents = board.wiredAgents(team)
            orchestrators.append(MissionNode(id: id, kind: .orchestrator, title: board.orchestratorName(team.id),
                                             detail: "\(agents.count) agent\(agents.count == 1 ? "" : "s")",
                                             color: Color(nsColor: BoardProjects.nsColor(team.color)), target: team.id))
            for key in team.groups { if let group = groupIDs[key] { link(MissionEdge(from: id, to: group, dashed: false)) } }
            for member in team.members { link(MissionEdge(from: id, to: "a:" + member.tile.uuidString, dashed: false)) }
            placed.formUnion(agents.map(\.surface.id))
        }
        placed.formUnion(model.groups.flatMap(\.tiles))
        for team in model.teams { for key in team.groups { placed.formUnion(board.groupTiles(key).map(\.id)) } }
        // Every agent; the loose ones from the command bar.
        let loose = model.surfaces.filter { !placed.contains($0.id) }
        if !loose.isEmpty {
            orchestrators.append(MissionNode(id: "command", kind: .commandBar, title: "Command bar",
                                             detail: "\(loose.count) reached only by @", color: Extreme.muted, target: nil))
        }
        for surface in model.surfaces {
            let info = VerticalTabsAgents.shared.info(for: surface)
            let id = "a:" + surface.id.uuidString
            agents.append(MissionNode(id: id, kind: .agent, title: board.tileLabel(surface),
                                      detail: info.map { $0.kind.displayName + " · " + (model.paused.contains(surface.id) ? "Paused" : $0.activity.label) } ?? "Terminal",
                                      color: info.map { $0.kind.brandColor } ?? Extreme.muted, status: MissionStatus(info?.activity), target: surface.id))
            if !placed.contains(surface.id) { link(MissionEdge(from: "command", to: id, dashed: true)) }
        }
    }
}

/// Where each node's card is, for the wires.
private struct MissionAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct MissionMapView: View {
    let controller: BoardController
    @ObservedObject var model: BoardModel
    @State private var filter: MissionStatus?
    @State private var search = ""
    @State private var selected: String?
    @State private var hovered: String?
    /// Built when agents, groups or wiring change, not on every redraw (hovering redraws).
    @State private var graph = MissionGraph()

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { close() }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    header(graph)
                    filters(graph)
                    ScrollView { columns(graph).padding(.vertical, 8) }
                    legend
                }
                .padding(18)
                Rectangle().fill(Extreme.line).frame(width: 1)
                inspector(graph).frame(width: 290)
            }
            .frame(maxWidth: 1180, maxHeight: 760)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Extreme.panel))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Extreme.lineStrong))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(40)
        }
        .onExitCommand { close() }
        .onAppear { graph = MissionGraph(board: controller) }
        .onReceive(model.$agentTick) { _ in rebuild() }
        .onReceive(model.$surfaces) { _ in rebuild() }
        .onReceive(model.$groups) { _ in rebuild() }
        .onReceive(model.$teams) { _ in rebuild() }
        .onReceive(model.$paused) { _ in rebuild() }
    }

    /// After the change lands (the publishers fire just before it).
    private func rebuild() {
        DispatchQueue.main.async { graph = MissionGraph(board: controller) }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { model.showMissionMap = false }
    }

    // MARK: Header

    private func header(_ graph: MissionGraph) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted").font(.system(size: 14, weight: .semibold))
                .foregroundColor(Extreme.ink).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Extreme.core))
            VStack(alignment: .leading, spacing: 1) {
                Text("Mission Map").font(Extreme.font(16, weight: .semibold)).foregroundColor(Extreme.text)
                Text(subtitle(graph)).font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(Extreme.muted)
                    .frame(width: 26, height: 26).background(Circle().fill(Extreme.raised))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func subtitle(_ graph: MissionGraph) -> String {
        let orchestrators = graph.orchestrators.filter { $0.kind == .orchestrator }.count
        let working = graph.agents.filter { $0.status == .working }.count
        var parts: [String] = []
        if orchestrators > 0 { parts.append("\(orchestrators) orchestrator\(orchestrators == 1 ? "" : "s")") }
        parts.append("\(graph.groups.count) group\(graph.groups.count == 1 ? "" : "s")")
        parts.append("\(graph.agents.count) agent\(graph.agents.count == 1 ? "" : "s")")
        parts.append("\(working) working")
        return parts.joined(separator: " · ")
    }

    private func filters(_ graph: MissionGraph) -> some View {
        HStack(spacing: 6) {
            pill("All", count: graph.agents.count, color: nil, on: filter == nil) { filter = nil }
            ForEach(MissionStatus.allCases, id: \.self) { status in
                pill(status.title, count: graph.agents.filter { $0.status == status }.count, color: status.color, on: filter == status) {
                    filter = filter == status ? nil : status
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundColor(Extreme.dim)
                TextField("Find an agent or group", text: $search).textFieldStyle(.plain).font(Extreme.font(12))
            }
            .padding(.horizontal, 10).frame(width: 220, height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Extreme.raised))
        }
    }

    private func pill(_ title: String, count: Int, color: Color?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(title).font(Extreme.font(11.5, weight: .medium))
                Text("\(count)").font(Extreme.mono(11)).opacity(0.7)
            }
            .foregroundColor(on ? Extreme.ink : Extreme.text)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(on ? Extreme.core : Extreme.raised))
        }
        .buttonStyle(.plain)
    }

    // MARK: Graph

    private func visible(_ node: MissionNode) -> Bool {
        if let filter, node.kind == .agent, node.status != filter { return false }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || node.title.lowercased().contains(query) || node.kind != .agent && node.kind != .group
    }

    private func columns(_ graph: MissionGraph) -> some View {
        let agents = graph.agents.filter(visible)
        let groups = graph.groups.filter(visible)
        return HStack(alignment: .top, spacing: 90) {
            column("ORCHESTRATORS", graph.orchestrators)
            column("GROUPS", groups)
            column("AGENTS", agents)
        }
        .padding(.horizontal, 6)
        .backgroundPreferenceValue(MissionAnchors.self) { anchors in
            GeometryReader { proxy in
                wires(graph, anchors: anchors, proxy: proxy, shown: Set((agents + groups + graph.orchestrators).map(\.id)))
            }
        }
    }

    private func column(_ title: String, _ nodes: [MissionNode]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.7)
            if nodes.isEmpty {
                Text("None").font(Extreme.font(11.5)).foregroundColor(Extreme.dim).frame(width: 220, alignment: .leading)
            }
            ForEach(nodes) { node in card(node) }
        }
    }

    private func card(_ node: MissionNode) -> some View {
        let lit = hovered.map { hovered in hovered == node.id || graph.neighbors[hovered]?.contains(node.id) == true } ?? true
        return HStack(spacing: 9) {
            Circle().fill(node.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                Text(node.detail).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let status = node.status { Circle().fill(status.color).frame(width: 7, height: 7) }
        }
        .padding(.horizontal, 10).frame(width: 220, height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Extreme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected == node.id ? Extreme.core : Extreme.line, lineWidth: selected == node.id ? 1.5 : 1))
        .opacity(lit ? 1 : 0.35)
        .anchorPreference(key: MissionAnchors.self, value: .bounds) { [node.id: $0] }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? node.id : (hovered == node.id ? nil : hovered) }
        .onTapGesture(count: 2) { goTo(node) }
        .onTapGesture { selected = node.id }
    }

    private func wires(_ graph: MissionGraph, anchors: [String: Anchor<CGRect>], proxy: GeometryProxy, shown: Set<String>) -> some View {
        Canvas { context, _ in
            for edge in graph.edges where shown.contains(edge.from) && shown.contains(edge.to) {
                guard let from = anchors[edge.from].map({ proxy[$0] }), let to = anchors[edge.to].map({ proxy[$0] }) else { continue }
                let start = CGPoint(x: from.maxX, y: from.midY), end = CGPoint(x: to.minX, y: to.midY)
                var path = Path()
                path.move(to: start)
                let mid = (end.x - start.x) / 2
                path.addCurve(to: end, control1: CGPoint(x: start.x + mid, y: start.y), control2: CGPoint(x: end.x - mid, y: end.y))
                let lit = hovered == nil || edge.from == hovered || edge.to == hovered
                let color = edge.dashed ? Extreme.muted : Color.green
                context.stroke(path, with: .color(color.opacity(lit ? 0.7 : 0.12)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: edge.dashed ? [4, 4] : []))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(MissionStatus.allCases, id: \.self) { status in
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.title).font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                }
            }
            Text("- - - Command bar only").font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
            Spacer()
            Text("Click to inspect · Double-click to go there").font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ graph: MissionGraph) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = graph.all.first(where: { $0.id == selected }) {
                    nodeInspector(node, graph)
                } else {
                    overview(graph)
                }
            }
            .padding(18)
        }
    }

    private func overview(_ graph: MissionGraph) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Fleet") {
                ForEach(MissionStatus.allCases, id: \.self) { status in
                    row(status.title, "\(graph.agents.filter { $0.status == status }.count)", color: status.color)
                }
            }
            section("Structure") {
                row("Orchestrators", "\(graph.orchestrators.filter { $0.kind == .orchestrator }.count)")
                row("Groups", "\(graph.groups.count)")
                row("Agents", "\(graph.agents.count)")
                row("Running orchestrators", "\(model.teams.filter { controller.orchestratorBrains[$0.id]?.running == true }.count)")
            }
            Text("Select an agent, a group or an orchestrator to see what it's doing and act on it.")
                .font(Extreme.font(11.5)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func nodeInspector(_ node: MissionNode, _ graph: MissionGraph) -> some View {
        HStack(spacing: 10) {
            Circle().fill(node.color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(Extreme.font(15, weight: .semibold)).foregroundColor(Extreme.text)
                Text(node.detail).font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
            }
        }
        if node.kind != .commandBar {
            Button { goTo(node) } label: {
                Label(node.kind == .group ? "Frame on the board" : "Go to it", systemImage: "arrow.up.forward")
                    .font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.ink)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Extreme.core))
            }
            .buttonStyle(.plain)
        }
        switch node.kind {
        case .agent:
            if let id = node.target, let surface = model.surfaces.first(where: { $0.id == id }) {
                agentActions(surface)
                section("Now") {
                    let info = VerticalTabsAgents.shared.info(for: surface)
                    row("Status", model.paused.contains(id) ? "Paused" : info?.activity.label ?? "Terminal", color: node.status?.color)
                    if let since = info?.since {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in row("For", Self.elapsed(since)) }
                    }
                    if let task = info?.task { Text(task).font(Extreme.font(11)).foregroundColor(Extreme.muted).lineLimit(4) }
                }
                section("Belongs to") {
                    let parents = graph.edges.filter { $0.to == node.id }.compactMap { edge in graph.all.first { $0.id == edge.from } }
                    if parents.isEmpty { row("Nothing", "") }
                    ForEach(parents) { parent in link(parent) }
                }
            }
        case .group:
            section("Members") {
                ForEach(graph.edges.filter { $0.from == node.id }.compactMap { edge in graph.agents.first { $0.id == edge.to } }) { link($0) }
            }
            section("Commanded by") {
                let parents = graph.edges.filter { $0.to == node.id }.compactMap { edge in graph.orchestrators.first { $0.id == edge.from } }
                if parents.isEmpty { row("You (by @\(node.title))", "") }
                ForEach(parents) { link($0) }
            }
        case .orchestrator, .commandBar:
            section(node.kind == .commandBar ? "Agents" : "Scope") {
                ForEach(graph.edges.filter { $0.from == node.id }.compactMap { edge in graph.all.first { $0.id == edge.to } }) { link($0) }
            }
        }
    }

    private func agentActions(_ surface: Ghostty.SurfaceView) -> some View {
        let paused = model.paused.contains(surface.id)
        return HStack(spacing: 8) {
            Button { controller.setPaused(!paused, [surface.id]) } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                    .font(Extreme.font(11.5, weight: .medium)).foregroundColor(Extreme.text)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Extreme.raised))
            }
            .buttonStyle(.plain)
            Button { controller.close(surface) } label: {
                Label("Kill", systemImage: "xmark.octagon").font(Extreme.font(11.5, weight: .medium)).foregroundColor(.red)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.6)))
            }
            .buttonStyle(.plain)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Extreme.font(9.5, weight: .bold)).foregroundColor(Extreme.dim).tracking(0.6)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Extreme.raised))
        }
    }

    private func row(_ title: String, _ value: String, color: Color? = nil) -> some View {
        HStack {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(title).font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
            Spacer()
            Text(value).font(Extreme.mono(11.5)).foregroundColor(Extreme.text)
        }
    }

    private func link(_ node: MissionNode) -> some View {
        Button { selected = node.id } label: {
            HStack(spacing: 6) {
                Circle().fill(node.color).frame(width: 6, height: 6)
                Text(node.title).font(Extreme.font(11.5, weight: .medium)).foregroundColor(Extreme.text).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(Extreme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func elapsed(_ since: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// Closes the map and takes the camera there.
    private func goTo(_ node: MissionNode) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            switch node.kind {
            case .agent:
                if let id = node.target, let surface = model.surfaces.first(where: { $0.id == id }) { controller.focusTile(surface) }
            case .group:
                if let id = node.target, let group = controller.namedGroup(id), let frame = controller.groupFrame(group) {
                    controller.zoom(toFit: frame.insetBy(dx: -60, dy: -80), animated: true)
                }
            case .orchestrator:
                if let id = node.target { controller.raise(id: id); controller.zoom(toNode: id) }
            case .commandBar:
                controller.assistantField?.window?.makeFirstResponder(controller.assistantField)
            }
        }
    }
}
#endif
