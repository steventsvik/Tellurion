#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// One screen with every agent (or every pane) as a live card: status, task, last action, how
/// long it's been in that state and the bottom of its terminal. Click a card to jump to it.
enum MissionControl {
    static let windowID = "mission-control"

    static func toggle() {
        // A board shows its agents on its Agent Map instead.
        if let board = TerminalWindows.controller(of: NSApp.keyWindow ?? NSApp.mainWindow) as? BoardController {
            board.showAgentMap()
            return
        }
        if AgentToolWindows.isOpen(windowID) {
            AgentToolWindows.close(id: windowID)
        } else {
            show()
        }
    }

    static func show() {
        guard ExtremeSettings.isOn(.missionControl) else { return }
        AgentToolWindows.show(id: windowID, title: "Mission Control", size: NSSize(width: 1120, height: 720)) {
            MissionControlView()
        }
    }
}

/// A pane as Mission Control shows it.
private struct MissionCard: Identifiable {
    let id: ObjectIdentifier
    let surface: Weak<Ghostty.SurfaceView>
    weak var controller: BaseTerminalController?
    let tabTitle: String
    let folder: String?
    let tabColor: Color?
    let agent: VerticalTabAgentInfo?
    let preview: String

    /// Waiting agents first, then working, then finished, then everything else.
    var rank: Int {
        switch agent?.activity {
        case .needsPermission, .needsInput: return 0
        case .working: return 1
        case .failed: return 2
        case .done: return 3
        case .ready: return 4
        case .none: return 5
        }
    }
}

private struct MissionControlView: View {
    @AppStorage("GhosttyExtremeMissionControlAllPanes") private var showAllPanes = false
    @ObservedObject private var races = AgentRaces.shared
    @State private var cards: [MissionCard] = []
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if cards.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(cards) { card in
                            MissionCardView(card: card, now: now)
                        }
                    }
                    .padding(16)
                }
                if !races.races.isEmpty {
                    racesSection
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: reload)
        .onReceive(timer) { value in
            now = value
            reload()
        }
        .onChange(of: showAllPanes) { _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ExtremeWindowTitle(icon: .grid, title: "Mission Control")
            summary
            Spacer()
            Picker("", selection: $showAllPanes) {
                Text("Agents").tag(false)
                Text("All panes").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            if ExtremeSettings.isOn(.races), let owner = TerminalWindows.front ?? TerminalWindows.all.first(where: { $0.window?.isVisible == true }) {
                Button {
                    AgentRaces.showSetup(from: owner)
                } label: { Label("Race agents…", systemImage: "flag.checkered.2.crossed") }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var summary: some View {
        let agents = cards.compactMap(\.agent)
        let counts: [(String, Int, Color)] = [
            ("waiting", agents.filter { AgentAlerts.isWaiting($0.activity) }.count, .orange),
            ("working", agents.filter { $0.activity == .working }.count, AgentStatusPill.color(.working)),
            ("done", agents.filter { $0.activity == .done }.count, .green),
        ]
        return HStack(spacing: 10) {
            ForEach(counts.filter { $0.1 > 0 }, id: \.0) { label, count, color in
                HStack(spacing: 4) {
                    PixelDot(color: color, size: 6)
                    Text("\(count) \(label)").font(Extreme.font(12)).foregroundColor(Extreme.muted)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ExtremeSigil(size: 56)
            Text(showAllPanes ? "No panes open" : "No agents running")
                .font(Extreme.font(15))
            Text("Start Claude Code or Codex in a tab (or race several at once) and they'll show up here live.")
                .font(Extreme.font(12)).foregroundColor(Extreme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 380)
        .padding(.vertical, 90)
        .frame(maxWidth: .infinity)
    }

    private var racesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RACES").font(Extreme.font(10.5)).kerning(0.4).foregroundColor(Extreme.muted)
            ForEach(races.races) { race in
                Button {
                    AgentRaces.show(race, from: TerminalWindows.front)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "flag.checkered.2.crossed").foregroundColor(.purple)
                        Text(race.task).lineLimit(1)
                        Spacer()
                        Text("\(race.contestants.count) agents · \(race.repoName)").foregroundColor(Extreme.muted)
                    }
                    .font(Extreme.font(12))
                    .padding(10)
                    .background(Rectangle().fill(Extreme.text.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func reload() {
        var result: [MissionCard] = []
        for controller in TerminalWindows.all {
            guard let window = controller.window else { continue }
            let color = (window as? TerminalWindow)?.tabColor
            for surface in controller.surfaceTree {
                let agent = VerticalTabsAgents.shared.info(for: surface)
                guard showAllPanes || agent != nil else { continue }
                // Hermes tabs show a web app, not the terminal underneath.
                let preview = agent?.kind == .hermes ? "" : Self.tail(surface.cachedVisibleContents.get(), lines: 9)
                let own = TerminalWindows.title(of: surface, in: controller) ?? (surface.title.isEmpty ? window.title : surface.title)
                // A tile also says which board it's on.
                let title = (controller as? BoardController).map { "\($0.workspace.name) · \(own)" } ?? own
                result.append(MissionCard(
                    id: ObjectIdentifier(surface),
                    surface: Weak(surface),
                    controller: controller,
                    tabTitle: title,
                    folder: surface.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath },
                    tabColor: color.flatMap { $0.displayColor }.map { Color(nsColor: $0) },
                    agent: agent,
                    preview: preview))
            }
        }
        cards = result.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank : (a.agent?.since ?? .distantPast) > (b.agent?.since ?? .distantPast)
        }
    }

    /// The last non-blank lines of the screen, with trailing spaces trimmed.
    private static func tail(_ text: String, lines count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        var end = lines.count
        while end > 0 && lines[end - 1].isEmpty { end -= 1 }
        return lines[max(0, end - count)..<end].joined(separator: "\n")
    }
}

private struct MissionCardView: View {
    let card: MissionCard
    let now: Date
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.agent?.name ?? "Terminal").font(Extreme.font(13))
                    Text([card.tabTitle, card.folder].compactMap { $0 }.joined(separator: " · "))
                        .font(Extreme.font(11)).foregroundColor(Extreme.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let agent = card.agent, agent.kind != .hermes {
                    AgentStatusPill(activity: agent.activity)
                }
            }
            if let task = card.agent?.task, !task.isEmpty {
                Text(task).font(Extreme.font(12.5)).lineLimit(2)
            }
            if let agent = card.agent, agent.kind != .hermes {
                HStack(spacing: 5) {
                    Image(systemName: AgentAlerts.isWaiting(agent.activity) ? "hand.raised.fill" : "bolt.fill")
                        .font(Extreme.font(9)).foregroundColor(AgentStatusPill.color(agent.activity))
                    Text(actionLine(agent)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(elapsed(since: agent.since)).monospacedDigit()
                }
                .font(Extreme.font(11)).foregroundColor(Extreme.muted)
            }
            if !card.preview.isEmpty {
                Text(card.preview)
                    .font(Extreme.mono(9.5))
                    .foregroundColor(Extreme.text.opacity(0.75))
                    .lineLimit(9)
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .bottomLeading)
                    .padding(8)
                    .background(Rectangle().fill(Color.black.opacity(0.35)))
                    .clipped()
            }
            if card.agent?.activity == .needsPermission, let surface = card.surface.value,
               let prompt = AgentPermissions.prompt(on: surface) {
                AgentPermissionButtons(surface: surface, prompt: prompt)
            }
            if let surface = card.surface.value { AgentMessagesLine(surface: surface) }
            actions
        }
        .padding(12)
        .background(
            Rectangle()
                .fill(Extreme.text.opacity(hovering ? 0.08 : 0.045)))
        .overlay(
            Rectangle()
                .stroke(borderColor, lineWidth: card.rank == 0 ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
        .onHover { hovering = $0 }
    }

    private var borderColor: Color {
        if card.rank == 0 { return AgentStatusPill.color(card.agent?.activity).opacity(0.8) }
        return card.tabColor?.opacity(0.6) ?? Extreme.text.opacity(0.12)
    }

    private var avatar: some View {
        AgentBadge(kind: card.agent?.kind, size: 26)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open", action: focus)
            if let surface = card.surface.value, let controller = card.controller, surface.pwd != nil {
                Menu("Hand off") {
                    ForEach(AgentHandoff.Mode.quick, id: \.self) { mode in
                        ForEach(AgentHandoff.targets, id: \.self) { target in
                            Button(AgentHandoff.title(mode, target)) {
                                AgentHandoff.handOff(from: surface, in: controller, to: target, mode: mode)
                                focus()
                            }
                        }
                        Divider()
                    }
                    Button("Hand Off…") { AgentHandoff.showWindow(from: surface, in: controller) }
                    if card.agent != nil {
                        Button("Start a Review Loop…") { PipelineSetup.show(writer: surface, in: controller) }
                    }
                }
                .fixedSize()
            }
            Spacer()
        }
        .controlSize(.small)
    }

    private func actionLine(_ agent: VerticalTabAgentInfo) -> String {
        if AgentAlerts.isWaiting(agent.activity) { return agent.detail ?? agent.activity.label }
        if let action = agent.lastAction { return action }
        return agent.activity.label
    }

    private func elapsed(since date: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    private func focus() {
        guard let surface = card.surface.value else { return }
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
    }
}
#endif
