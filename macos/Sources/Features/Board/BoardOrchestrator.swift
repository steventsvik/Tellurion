#if os(macOS)
import AppKit
import SwiftUI

/// An orchestrator card's content: what's wired to it (terminals, then groups with their
/// agents and how many are done), Connect mode for wiring more, what its brain is doing, and
/// the command field. The list is a snapshot taken when the board syncs (agents changing,
/// wiring, pauses), so drags and zooms don't redraw it.
final class OrchestratorContent: CardContent {
    private let state = OrchestratorState()
    private var host: NSView?
    private var brain: OrchestratorBrain?

    override func apply(_ card: BoardCard) {
        attach()
        refreshAgents()
    }

    override func refreshAgents() {
        guard let board else { return }
        state.update(OrchestratorSnapshot(board: board, id: cardID))
    }

    override func beginTyping() {
        guard let field = descendants.compactMap({ $0 as? NSTextField }).first(where: \.isEditable) else { return }
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
    }

    private func attach() {
        guard host == nil, let board else { return }
        let brain = board.orchestratorBrain(cardID)
        brain.lookUp()
        self.brain = brain
        let host = NSHostingView(rootView: OrchestratorPanel(controller: board, id: cardID, brain: brain, state: state))
        host.sizingOptions = []
        addSubview(host)
        self.host = host
        needsLayout = true
    }
}

// MARK: - The snapshot

struct OrchestratorRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// "Codex · Reviewer".
    let detail: String
    let kind: VerticalTabAgentKind?
    let activity: VerticalTabAgentActivity?
    let paused: Bool
}

struct OrchestratorSection: Identifiable, Equatable {
    /// The group's project, or "" for terminals wired by themselves.
    let id: String
    let title: String?
    let color: Int?
    let rows: [OrchestratorRow]
    var done: Int { rows.filter { $0.activity == .done }.count }
}

/// Something Connect mode can wire: a group or a terminal.
struct OrchestratorChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let wired: Bool
    let group: String?
    let tile: UUID?
}

struct OrchestratorSnapshot: Equatable {
    var sections: [OrchestratorSection] = []
    var agents = 0
    var groups = 0
    var done = 0
    var working = 0
    /// Agents with a message waiting to go in.
    var queued = 0
    var wiring = false
    var color = BoardTeams.color
    var groupChoices: [OrchestratorChoice] = []
    var tileChoices: [OrchestratorChoice] = []
    var wired: Set<UUID> = []

    init() {}

    init(board: BoardController, id: UUID) {
        guard let team = board.orchestrator(id) else { return }
        color = team.color
        wiring = board.model.wiring == id
        let agents = board.wiredAgents(team)
        wired = Set(agents.map(\.surface.id))
        func row(_ agent: BoardTeamAgent) -> OrchestratorRow {
            let info = VerticalTabsAgents.shared.info(for: agent.surface)
            let detail = [info?.kind.displayName ?? "Terminal", agent.role].compactMap { $0 }.joined(separator: " · ")
            return OrchestratorRow(id: agent.surface.id, name: board.tileLabel(agent.surface), detail: detail, kind: info?.kind,
                                   activity: info?.activity, paused: board.model.paused.contains(agent.surface.id))
        }
        let single = agents.filter { $0.group == nil }.map(row)
        if !single.isEmpty { sections.append(OrchestratorSection(id: "", title: nil, color: nil, rows: single)) }
        for project in team.groups {
            sections.append(OrchestratorSection(id: project, title: BoardProjects.name(project).uppercased(),
                                                color: board.model.colors[project],
                                                rows: agents.filter { $0.group == project }.map(row)))
        }
        self.agents = agents.count
        groups = team.groups.count
        done = sections.reduce(0) { $0 + $1.done }
        working = sections.reduce(0) { $0 + $1.rows.filter { $0.activity == .working }.count }
        queued = agents.filter { agent in
            VerticalTabsAgents.shared.info(for: agent.surface)?.activity != .working && !AgentInbox.shared.waiting(for: agent.surface).isEmpty
        }.count
        guard wiring else { return }
        let projects = Set(board.model.surfaces.compactMap { board.model.projects[$0.id] }).union(team.groups).sorted()
        groupChoices = projects.map { project in
            let count = board.groupTiles(project).count
            return OrchestratorChoice(id: project, title: BoardProjects.name(project), detail: "\(count)",
                                      wired: team.groups.contains(project), group: project, tile: nil)
        }
        tileChoices = board.tileLabels().map { entry in
            OrchestratorChoice(id: entry.id.uuidString, title: entry.label,
                               detail: VerticalTabsAgents.shared.info(for: entry.surface)?.kind.displayName,
                               wired: team.members.contains { $0.tile == entry.id }, group: nil, tile: entry.id)
        }
    }
}

final class OrchestratorState: ObservableObject {
    @Published private(set) var snapshot = OrchestratorSnapshot()

    func update(_ snapshot: OrchestratorSnapshot) {
        if snapshot != self.snapshot { self.snapshot = snapshot }
    }
}

// MARK: - The panel

private struct OrchestratorPanel: View {
    let controller: BoardController
    let id: UUID
    @ObservedObject var brain: OrchestratorBrain
    @ObservedObject var state: OrchestratorState
    @StateObject private var dictation = BoardDictation()
    @State private var text = ""
    @State private var spokenAfter: String?

    private var snapshot: OrchestratorSnapshot { state.snapshot }
    private var accent: Color { BoardProjects.color(snapshot.color) }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Group {
                if snapshot.wiring {
                    connectList
                } else if snapshot.agents == 0 {
                    emptyState
                } else {
                    wiredList
                }
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Extreme.raised.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
            activity
            inputBar.padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 8)
        }
        .background(Extreme.panel)
    }

    // MARK: Top

    private var topRow: some View {
        HStack(spacing: 8) {
            BoardAssistantOrb(busy: brain.busy, listening: dictation.listening).frame(width: 20, height: 20)
            Text(summary).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
            Spacer(minLength: 4)
            if snapshot.agents > 0 { OrchestratorRing(done: snapshot.done, total: snapshot.agents, color: accent) }
            spawnMenu
            Button {
                if snapshot.wiring { controller.endWiring() } else { controller.startWiring(id) }
            } label: {
                Label(snapshot.wiring ? "Done" : "Connect", systemImage: snapshot.wiring ? "checkmark" : "cable.connector")
                    .font(Extreme.font(11.5, weight: .semibold))
                    .foregroundColor(snapshot.wiring ? Extreme.ink : accent)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(snapshot.wiring ? accent : accent.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(accent.opacity(snapshot.wiring ? 0 : 0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(snapshot.wiring ? "Stop wiring" : "Wire terminals and groups: click them on the board")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var summary: String {
        if snapshot.agents == 0 && snapshot.groups == 0 { return "No agents wired" }
        var parts = ["\(snapshot.agents) agent\(snapshot.agents == 1 ? "" : "s")"]
        if snapshot.groups > 0 { parts.append("\(snapshot.groups) group\(snapshot.groups == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var spawnMenu: some View {
        Menu {
            ForEach(brain.installed) { agent in
                Button(agent.kind.displayName) { spawn(agent) }
            }
            Divider()
            Button("Terminal") { spawn(nil) }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundColor(Extreme.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Extreme.raised))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start an agent wired to this orchestrator")
    }

    private func spawn(_ agent: BoardAgent?) {
        controller.spawnAgent(agent, role: nil, task: nil, folder: nil, for: id)
    }

    // MARK: Lists

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            BoardAssistantOrb(busy: false, listening: false).frame(width: 34, height: 34)
            Text("No agents wired").font(Extreme.font(13, weight: .semibold)).foregroundColor(Extreme.text)
            Text("Start a fresh agent, or tap Connect and pick terminals or groups on the board.")
                .font(Extreme.font(11.5)).foregroundColor(Extreme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
            Menu {
                ForEach(brain.installed) { agent in
                    Button(agent.kind.displayName) { spawn(agent) }
                }
                Divider()
                Button("Terminal") { spawn(nil) }
            } label: {
                Label("Start agent", systemImage: "plus").font(Extreme.font(11.5, weight: .semibold)).foregroundColor(accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var connectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Click terminals or group labels on the board, or wire them here. Tap Done when finished.")
                    .font(Extreme.font(11)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                if !snapshot.groupChoices.isEmpty {
                    ExtremeSectionLabel("Groups")
                    ForEach(snapshot.groupChoices) { choice in choiceRow(choice, symbol: "square.grid.2x2.fill") }
                }
                if !snapshot.tileChoices.isEmpty {
                    ExtremeSectionLabel("Terminals").padding(.top, 6)
                    ForEach(snapshot.tileChoices) { choice in choiceRow(choice, symbol: nil) }
                }
                if snapshot.groupChoices.isEmpty && snapshot.tileChoices.isEmpty {
                    Text("Nothing on the board yet.").font(Extreme.font(11.5)).foregroundColor(Extreme.dim)
                }
            }
            .padding(12)
        }
    }

    private func choiceRow(_ choice: OrchestratorChoice, symbol: String?) -> some View {
        Button {
            if let group = choice.group { controller.toggleGroup(group, in: id) }
            if let tile = choice.tile { controller.toggleWire(tile, in: id) }
        } label: {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(choice.title).font(Extreme.font(12, weight: .semibold)).lineLimit(1)
                if let detail = choice.detail {
                    Text(detail).font(Extreme.font(10.5)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: choice.wired ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 13))
            }
            .foregroundColor(choice.wired ? Extreme.ink : Extreme.text)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(choice.wired ? accent : Extreme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((choice.wired ? "Unwire " : "Wire ") + choice.title)
    }

    private var wiredList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.sections) { section in
                    if let title = section.title {
                        HStack(spacing: 6) {
                            Circle().fill(section.color.map(BoardProjects.color) ?? accent).frame(width: 6, height: 6)
                            Text(title).font(Extreme.font(10.5, weight: .bold)).foregroundColor(Extreme.muted).tracking(0.6)
                            Spacer()
                            Text("\(section.done)/\(section.rows.count)").font(Extreme.mono(10.5)).foregroundColor(Extreme.dim)
                        }
                        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 2)
                    }
                    ForEach(section.rows) { row in OrchestratorAgentRow(controller: controller, row: row, accent: accent) }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
    }

    // MARK: Activity

    @ViewBuilder
    private var activity: some View {
        let recent = Array(brain.log.suffix(brain.running || brain.busy ? 2 : 3))
        if !recent.isEmpty || brain.running {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(recent) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: Self.symbol(entry.kind)).font(.system(size: 9, weight: .semibold))
                            .foregroundColor(entry.kind == .error ? .red : entry.kind == .say ? accent : Extreme.dim)
                            .frame(width: 12).padding(.top, 2)
                        Text(entry.text).font(Extreme.font(11)).foregroundColor(entry.kind == .say ? Extreme.text : Extreme.muted)
                            .lineLimit(entry.kind == .say ? 4 : 2)
                            .textSelection(.enabled)
                    }
                }
                if brain.running {
                    HStack(spacing: 6) {
                        Text(brain.busy ? "Thinking · turn \(brain.turn) of \(brain.limit)"
                             : waitingLine)
                            .font(Extreme.font(10.5, weight: .medium)).foregroundColor(accent)
                        Spacer()
                        Button("Stop") { brain.stop() }
                            .buttonStyle(.plain)
                            .font(Extreme.font(10.5, weight: .semibold)).foregroundColor(Extreme.muted)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Extreme.raised.opacity(0.5)))
            .padding(.horizontal, 10).padding(.top, 8)
        }
    }

    private var waitingLine: String {
        let count = snapshot.working + snapshot.queued
        let who = count == 0 ? "Waiting" : "Waiting for \(count) agent\(count == 1 ? "" : "s")"
        return who + " · turn \(brain.turn) of \(brain.limit)"
    }

    private static func symbol(_ kind: OrchestratorBrain.Entry.Kind) -> String {
        switch kind {
        case .user: return "person.fill"
        case .say: return "sparkle"
        case .action: return "arrow.turn.down.right"
        case .event: return "circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 6) {
            BoardAssistantField(text: $text, placeholder: placeholder, controller: controller, mentions: snapshot.wired,
                                onSubmit: submit, onRecall: recall, onHold: { $0 ? startDictation() : dictation.stop() })
                .frame(height: 20)
            if brain.busy {
                button("stop.fill", "Stop", filled: true) { brain.stop() }
            } else {
                button("arrow.up", "Send (Return)", filled: !text.trimmingCharacters(in: .whitespaces).isEmpty) { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            button(dictation.listening ? "mic.fill" : "mic", dictation.listening ? "Stop listening" : "Speak (or hold Space)") {
                if dictation.listening { dictation.stop() } else { startDictation() }
            }
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Extreme.raised))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(dictation.listening ? accent.opacity(0.7) : Extreme.line, lineWidth: 1))
    }

    private var placeholder: String {
        if dictation.listening { return "Listening…" }
        if brain.engines?.isEmpty == true { return "Install Claude Code or Codex to command agents" }
        if snapshot.agents == 0 { return "Try “start two reviewers”" }
        return "Command \(snapshot.agents) agent\(snapshot.agents == 1 ? "" : "s") · @ to direct…"
    }

    private func button(_ symbol: String, _ help: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                .foregroundColor(filled ? Extreme.ink : Extreme.muted)
                .frame(width: 26, height: 26)
                .background(Circle().fill(filled ? accent : Extreme.panel))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !brain.busy else { return }
        dictation.stop()
        text = ""
        brain.command(message)
    }

    private func recall() {
        guard text.isEmpty, let last = brain.log.last(where: { $0.kind == .user }) else { return }
        text = last.text
    }

    private func startDictation() {
        guard !dictation.listening else { return }
        spokenAfter = text
        dictation.start(update: { words in
            let before = spokenAfter ?? ""
            text = before.isEmpty ? words : before + " " + words
        }, failed: { _ in })
    }
}

/// One wired agent: its logo, name, agent and role, and status; on hover, go to it or pause it.
private struct OrchestratorAgentRow: View {
    let controller: BoardController
    let row: OrchestratorRow
    let accent: Color
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let kind = row.kind {
                    VerticalTabAgentLogo(kind: kind, tint: Extreme.text)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(Extreme.muted)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                Text(row.detail).font(Extreme.font(10.5)).foregroundColor(Extreme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                icon("scope", "Go to it") { focus() }
                icon(row.paused ? "play.fill" : "pause.fill", row.paused ? "Resume" : "Pause") {
                    controller.setPaused(!row.paused, [row.id])
                }
            } else if row.paused {
                BoardPausedPill()
            } else if row.kind != nil {
                AgentStatusPill(activity: row.activity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Extreme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { focus() }
        .contextMenu {
            Button("Go to It") { focus() }
            Button("Role…") {
                guard let team = controller.model.teams.first(where: { team in team.members.contains { $0.tile == row.id } }) else { return }
                controller.promptRename("Role", current: controller.role(of: row.id, in: team.id) ?? "", button: "Set Role") {
                    controller.setRole($0, for: row.id, in: team.id)
                }
            }
            Button("Unwire") { controller.unwire(row.id) }
        }
    }

    private func focus() {
        guard let surface = controller.model.surfaces.first(where: { $0.id == row.id }) else { return }
        controller.focusTile(surface)
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(Extreme.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Over the board while an orchestrator is connecting, at any zoom: what to do, and Done.
struct OrchestratorWiringBanner: View {
    let controller: BoardController
    let id: UUID

    var body: some View {
        let color = BoardProjects.color(controller.orchestrator(id)?.color ?? BoardTeams.color)
        HStack(spacing: 10) {
            Image(systemName: "cable.connector").font(.system(size: 12, weight: .semibold)).foregroundColor(color)
            Text("Wiring \(controller.orchestratorName(id))").font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.text)
            Text("Click terminals or group labels").font(Extreme.font(12)).foregroundColor(Extreme.muted)
            Button { controller.endWiring() } label: {
                Label("Done", systemImage: "checkmark").font(Extreme.font(11.5, weight: .semibold))
                    .foregroundColor(Extreme.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(color))
            }
            .buttonStyle(.plain)
            .help("Done wiring (Escape)")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(Extreme.panel.opacity(0.97)))
        .overlay(Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }
}

/// How many wired agents are done: a thin ring and "3/8".
private struct OrchestratorRing: View {
    let done: Int
    let total: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Extreme.line, lineWidth: 2)
                Circle().trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text("\(done)/\(total)").font(Extreme.mono(10.5)).foregroundColor(Extreme.muted)
        }
        .help("\(done) of \(total) done")
    }
}
#endif
