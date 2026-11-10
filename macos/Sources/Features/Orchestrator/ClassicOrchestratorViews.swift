#if os(macOS)
import AppKit
import Combine
import SwiftUI

extension OrchestratorStatus.Tone {
    var color: Color {
        switch self {
        case .idle: return Tellurion.dim
        case .working: return Tellurion.core
        case .needsYou: return Tellurion.warn
        case .stopped: return Tellurion.muted
        case .done: return Tellurion.live
        }
    }
}

// MARK: - The sidebar section

/// The sidebar's Orchestrator section, for the project of the tab it's in: the goal, where
/// it's at, and a field to command it. The window button opens the whole thing.
///
/// It's in every window, so it's still (a dot, no motion) and reads its state on the
/// sidebar's tick, only while it's open and its window is on screen.
struct OrchestratorSidebarSection: View {
    let owner: TerminalController
    @AppStorage("OrchestratorSectionCollapsed") private var collapsed = false
    @State private var glance = OrchestratorGlance()
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Tellurion.line).frame(height: 1).padding(.bottom, 4)
            header
            if !collapsed {
                goalLine
                statusLine
                commandRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .leading)
        // Keeps its height in a short window; the tab list above scrolls instead.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: update)
        .onChange(of: collapsed) { if !$0 { update() } }
        .onReceive(VerticalTabsTicker.shared.publisher) {
            guard !collapsed, owner.window?.occlusionState.contains(.visible) == true else { return }
            update()
        }
        // What an orchestrator does shows at once, not on the next tick.
        .onReceive(ClassicOrchestrators.shared.pulses) {
            if !collapsed { update() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(Tellurion.dim).frame(width: 8)
                    Text("ORCHESTRATOR").font(Tellurion.font(10.5, weight: .semibold)).kerning(1.1).foregroundColor(Tellurion.muted)
                        .fixedSize()
                    // Which project this tab's commands go to.
                    Text(verbatim: glance.project).font(Tellurion.font(10)).foregroundColor(Tellurion.dim).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Show the orchestrator" : "Hide the orchestrator")
            Rectangle().fill(Tellurion.line.opacity(0.7)).frame(height: 1)
            Button(action: openWindow) {
                Image(systemName: "arrow.up.right.square").font(.system(size: 10)).foregroundColor(Tellurion.dim)
            }
            .buttonStyle(.plain)
            .disabled(glance.root == nil)
            .help("Orchestrator: wired agents, the whole conversation and its settings (⌃⌘O)")
            .accessibilityLabel("Open the orchestrator")
        }
        .padding(.horizontal, 4)
    }

    /// The goal on one line; an error takes its place while it's the latest thing.
    private var goalLine: some View {
        Text(verbatim: glance.problem ?? glance.goal ?? "No goal yet")
            .font(Tellurion.font(11.5, weight: glance.goal == nil || glance.problem != nil ? .regular : .medium))
            .foregroundColor(glance.problem != nil ? Tellurion.warn : glance.goal == nil ? Tellurion.dim : Tellurion.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .help(glance.problem ?? glance.goal ?? "Give this project's agents one command")
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            PixelDot(color: glance.status.tone.color, size: 6)
            Text(glance.status.line)
                .font(Tellurion.font(10.5))
                .foregroundColor(glance.status.tone == .needsYou ? Tellurion.warn : Tellurion.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if glance.status.running {
                Button("Stop", action: stop)
                    .buttonStyle(.plain)
                    .font(Tellurion.font(10.5, weight: .semibold)).foregroundColor(Tellurion.muted)
                    .help("Stop handing out work; the agents finish what they have")
            }
        }
        .padding(.horizontal, 4)
    }

    private var commandRow: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Tellurion.font(11.5))
                .foregroundColor(Tellurion.text)
                .disabled(glance.root == nil)
                .onSubmit(send)
                .accessibilityLabel("Command the orchestrator")
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                    .foregroundColor(canSend ? Tellurion.ink : Tellurion.muted)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(canSend ? Tellurion.gold : Tellurion.panel))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
        .padding(.leading, 9).padding(.trailing, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tellurion.raised))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tellurion.line, lineWidth: 1))
        .padding(.top, 2)
    }

    private var canSend: Bool { glance.root != nil && !text.trimmingCharacters(in: .whitespaces).isEmpty }

    private var placeholder: String {
        let wired = glance.status.wired
        if wired == 0 { return "Try “start two reviewers”" }
        return "Command \(wired) agent\(wired == 1 ? "" : "s")…"
    }

    private func update() {
        // A pane that closed since the last look comes unwired.
        ClassicOrchestrators.shared.prune()
        let next = ClassicOrchestrators.shared.glance(for: owner)
        if next != glance { glance = next }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let root = glance.root else { return }
        text = ""
        ClassicOrchestrators.shared.open(root: root, from: owner).command(message)
        update()
    }

    private func stop() {
        guard let root = glance.root else { return }
        ClassicOrchestrators.shared.orchestrator(root: root)?.brain.stop()
        update()
    }

    private func openWindow() {
        ClassicOrchestrators.show(from: owner)
    }
}

// MARK: - The mark on a wired pane

/// A small link on the card of a pane that's wired to an orchestrator. It doesn't move: it's
/// on every such card in every window.
struct OrchestratorWireMark: View {
    let surface: Ghostty.SurfaceView?
    @ObservedObject private var settings = TellurionSettings.shared

    var body: some View {
        if let surface, settings.isOn(.orchestrator) { Mark(pane: surface.id) }
    }

    private struct Mark: View {
        let pane: UUID
        @ObservedObject private var orchestrators = ClassicOrchestrators.shared

        var body: some View {
            if orchestrators.wired.contains(pane) {
                Image(systemName: "link").font(.system(size: 8.5, weight: .bold)).foregroundColor(Tellurion.gold)
                    .help("Wired to the orchestrator")
                    .accessibilityLabel("Wired to the orchestrator")
            }
        }
    }
}

// MARK: - The window

/// A project's orchestrator in full: the wired agents on the left, what its brain says and
/// does in the middle, and the command field at the bottom.
struct ClassicOrchestratorView: View {
    @ObservedObject var orchestrator: ClassicOrchestrator
    @ObservedObject var brain: OrchestratorBrain
    @StateObject private var dictation = BoardDictation()
    @State private var text = ""
    @State private var spokenAfter: String?
    @State private var rows: [OrchestratorRow] = []
    @State private var choices: [OrchestratorWireGroup] = []
    @State private var status = OrchestratorStatus()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var accent: Color { Tellurion.gold }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tellurion.line).frame(height: 1)
            HStack(spacing: 0) {
                wiredColumn.frame(width: 290)
                Rectangle().fill(Tellurion.line).frame(width: 1)
                VStack(spacing: 0) {
                    conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                    commandArea.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)) { _ in refresh() }
        .onChange(of: orchestrator.team) { _ in refresh() }
        .onChange(of: brain.running) { _ in refresh() }
        .onChange(of: brain.busy) { _ in refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            BoardAssistantOrb(busy: brain.busy, listening: dictation.listening).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Orchestrator").font(Tellurion.font(16, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(verbatim: orchestrator.projectName).font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted)
                    .lineLimit(1).help((orchestrator.root as NSString).abbreviatingWithTildeInPath)
            }
            HStack(spacing: 6) {
                PixelDot(color: status.tone.color, size: 6)
                Text(status.line).font(Tellurion.font(12))
                    .foregroundColor(status.tone == .needsYou ? Tellurion.warn : Tellurion.muted).lineLimit(1)
            }
            .padding(.leading, 6)
            Spacer(minLength: 8)
            enginePicker
            Menu("Up to \(brain.limit) turns") {
                ForEach(ClassicOrchestratorRecord.turnChoices, id: \.self) { count in
                    Button {
                        orchestrator.setTurns(count)
                    } label: {
                        if brain.limit == count { Label("Up to \(count)", systemImage: "checkmark") } else { Text("Up to \(count)") }
                    }
                }
            }
            .fixedSize()
            .help("How many turns it takes on its own per command")
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    /// Which of your CLIs it thinks with, when there's more than one.
    @ViewBuilder
    private var enginePicker: some View {
        if let engines = brain.engines {
            if engines.isEmpty {
                Text("Install Claude Code or Codex").font(Tellurion.font(11.5)).foregroundColor(Tellurion.warn)
            } else if engines.count > 1 {
                Picker("Thinks with", selection: Binding(get: { brain.engine ?? engines[0] }, set: { orchestrator.setEngine($0) })) {
                    ForEach(engines) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Which of your CLIs it thinks with")
            } else {
                Text(engines[0].title).font(Tellurion.font(11.5)).foregroundColor(Tellurion.dim)
                    .help("It thinks with your \(engines[0].title)")
            }
        }
    }

    // MARK: Wired agents

    private var wiredColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(summary).font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text).lineLimit(1)
                Spacer(minLength: 4)
                startMenu(label: Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundColor(Tellurion.muted)
                    .frame(width: 24, height: 24).background(Circle().fill(Tellurion.raised)))
                    .help("Start an agent wired to this orchestrator, in a new tab")
                wireMenu
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            if rows.isEmpty {
                emptyWired
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            OrchestratorWiredRow(row: row, actions: [
                                .init(symbol: "scope", help: "Go to it") { focus(row.id) },
                                .init(symbol: "person.text.rectangle", help: "Role…") { editRole(row.id) },
                                .init(symbol: "xmark", help: "Unwire") { orchestrator.unwire(row.id) },
                            ], focus: { focus(row.id) }, editRole: { editRole(row.id) }, unwire: { orchestrator.unwire(row.id) })
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tellurion.panel.opacity(0.5))
    }

    private var summary: String {
        rows.isEmpty ? "No agents wired" : "\(rows.count) wired"
    }

    private var emptyWired: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No agents wired").font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.text)
            Text("Start a fresh agent in a new tab, or wire the tabs you already have.")
                .font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            startMenu(label: Label("Start agent", systemImage: "plus").font(Tellurion.font(11.5, weight: .semibold)).foregroundColor(accent))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func startMenu<Content: View>(label: Content) -> some View {
        Menu {
            ForEach(brain.installed) { agent in
                Button(agent.kind.displayName) { start(agent) }
            }
            Divider()
            Button("Terminal") { start(nil) }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Every pane that isn't wired yet, by project, agents first.
    private var wireMenu: some View {
        Menu {
            if choices.isEmpty { Text("Nothing left to wire") }
            ForEach(choices) { group in
                Section(group.name) {
                    if group.agents.count > 1 {
                        Button {
                            orchestrator.wire(group.agents)
                        } label: {
                            Text(verbatim: "All agents in \(group.name)")
                        }
                    }
                    ForEach(group.choices) { choice in
                        Button {
                            orchestrator.wire([choice.id])
                        } label: {
                            Label(choice.detail.map { "\(choice.label) · \($0)" } ?? choice.label,
                                  systemImage: choice.isAgent ? "sparkle" : "terminal")
                        }
                    }
                }
            }
        } label: {
            Label("Wire…", systemImage: "cable.connector")
                .font(Tellurion.font(11.5, weight: .semibold))
                .foregroundColor(accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Wire tabs and panes that are already open")
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        if brain.log.isEmpty {
            VStack(spacing: 10) {
                BoardAssistantOrb(busy: false, listening: false).frame(width: 34, height: 34)
                Text(orchestrator.team.goal == nil ? "Give it a command" : "Ready to carry on")
                    .font(Tellurion.font(14, weight: .semibold)).foregroundColor(Tellurion.text)
                Text("Your own Claude Code (or Codex) splits the work, sends each wired agent its part, reads what they "
                     + "answer when they finish, and hands out the next steps. Permission prompts still come to you.")
                    .font(Tellurion.font(12)).foregroundColor(Tellurion.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                if let goal = orchestrator.team.goal {
                    Text(verbatim: "Last goal: " + goal).font(Tellurion.font(11.5)).foregroundColor(Tellurion.dim)
                        .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
            }
            .padding(24)
        } else {
            OrchestratorLogView(log: brain.log, accent: accent)
        }
    }

    // MARK: Command

    private var commandArea: some View {
        HStack(spacing: 6) {
            BoardAssistantField(text: $text, placeholder: placeholder, controller: nil, mentions: [], names: mentionNames,
                                onSubmit: submit, onRecall: recall, onHold: { $0 ? startDictation() : dictation.stop() })
                .frame(height: 20)
            if brain.running || brain.busy {
                OrchestratorRoundButton(symbol: "stop.fill", help: "Stop", filled: true, accent: accent) { brain.stop() }
            }
            OrchestratorRoundButton(symbol: "arrow.up", help: "Send (Return)", filled: canSend, accent: accent, action: submit)
                .disabled(!canSend)
            OrchestratorRoundButton(symbol: dictation.listening ? "mic.fill" : "mic",
                                    help: dictation.listening ? "Stop listening" : "Speak (or hold Space)", accent: accent) {
                if dictation.listening { dictation.stop() } else { startDictation() }
            }
            OrchestratorRoundButton(symbol: "trash", help: "Clear the conversation and start over", accent: accent) { brain.clear() }
                .disabled(brain.log.isEmpty)
        }
        .padding(.leading, 12).padding(.trailing, 5)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tellurion.raised))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(dictation.listening ? accent.opacity(0.7) : Tellurion.line, lineWidth: 1))
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && !brain.busy }

    private var placeholder: String {
        if dictation.listening { return "Listening…" }
        if brain.engines?.isEmpty == true { return "Install Claude Code or Codex to command agents" }
        if rows.isEmpty { return "Try “start two reviewers”" }
        return "Command \(rows.count) agent\(rows.count == 1 ? "" : "s") · @ to direct…"
    }

    /// What @ lists: the wired agents, each with what it's doing.
    private func mentionNames() -> [(label: String, tip: String?)] {
        orchestrator.mentionable().map { entry in
            (label: entry.label, tip: orchestrator.agentInfo(entry.pane)?.activity.label)
        }
    }

    // MARK: Actions

    private func refresh() {
        ClassicOrchestrators.shared.prune()
        let next = orchestrator.labels().map { entry -> OrchestratorRow in
            let info = orchestrator.agentInfo(entry.pane)
            let detail = [info?.kind.displayName ?? "Terminal", orchestrator.role(of: entry.pane)].compactMap { $0 }.joined(separator: " · ")
            return OrchestratorRow(id: entry.pane, name: entry.label, detail: detail, kind: info?.kind, activity: info?.activity, paused: false)
        }
        if next != rows { rows = next }
        let wirable = ClassicOrchestrators.shared.wireChoices(for: orchestrator)
        if wirable != choices { choices = wirable }
        let now = orchestrator.status
        if now != status { status = now }
    }

    private func start(_ agent: BoardAgent?) {
        _ = orchestrator.spawnWired(agent, role: nil, task: nil, folder: nil, for: orchestrator.id)
    }

    private func focus(_ pane: UUID) {
        guard let surface = orchestrator.surface(of: pane) else { return }
        TerminalWindows.show(surface)
    }

    private func editRole(_ pane: UUID) {
        OrchestratorRoleMenu.popUp(current: orchestrator.role(of: pane)) { orchestrator.setRole($0, for: pane) }
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !brain.busy else { return }
        dictation.cancel()
        text = ""
        orchestrator.command(message)
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
        }, failed: { reason in brain.add(.error, reason) })
    }
}

/// The roles on offer for a wired agent, as a menu at the pointer; "Other…" asks for one.
enum OrchestratorRoleMenu {
    static func popUp(current: String?, choose: @escaping (String?) -> Void) {
        let menu = NSMenu()
        for role in BoardTeams.roles {
            let item = ClosureMenuItem(role, image: nil) { choose(role) }
            item.state = current == role ? .on : .off
            menu.addItem(item)
        }
        let other = ClosureMenuItem("Other…", image: nil) { ask(current: current, done: choose) }
        if let current, !BoardTeams.roles.contains(current) { other.state = .on }
        menu.addItem(other)
        menu.addItem(.separator())
        let none = ClosureMenuItem("No Role", image: nil) { choose(nil) }
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func ask(current: String?, done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Role"
        alert.informativeText = "What this agent does for the orchestrator, in a word or two."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.stringValue = current ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Set Role")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            done(field.stringValue)
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
#endif
