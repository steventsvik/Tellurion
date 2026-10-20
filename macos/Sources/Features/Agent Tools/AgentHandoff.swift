#if os(macOS)
import AppKit
import SwiftUI

/// Passes a pane's work to another agent with the context written into its first message:
/// the task, the recent conversation, exactly what the first agent changed (since its first
/// turn here, from the undo snapshots) and commands that failed. The other agent can be a
/// new one in a split beside the original, or one that's already running (the message waits
/// until it's between turns; see `AgentInbox`).
enum AgentHandoff {
    enum Mode: CaseIterable, Identifiable {
        /// Read the changes and report problems without editing anything.
        case review
        /// Pick up the task where the previous agent stopped.
        case `continue`
        /// Look at the task and the approach, suggest a plan; no edits.
        case secondOpinion

        var id: Self { self }

        /// The ones in the ⋮ and Mission Control menus; the rest are in the Hand Off window.
        static let quick: [Mode] = [.review, .continue]

        var verb: String {
            switch self {
            case .review: return "Review with"
            case .continue: return "Continue with"
            case .secondOpinion: return "Second opinion from"
            }
        }

        var title: String {
            switch self {
            case .review: return "Review"
            case .continue: return "Continue"
            case .secondOpinion: return "Second opinion"
            }
        }

        var detail: String {
            switch self {
            case .review: return "Check the changes for bugs and gaps; no edits"
            case .continue: return "Finish the task from where it stopped"
            case .secondOpinion: return "Weigh in on the approach and suggest a plan; no edits"
            }
        }
    }

    static let targets: [VerticalTabAgentKind] = [.claude, .codex]

    static func title(_ mode: Mode, _ target: VerticalTabAgentKind) -> String {
        "\(mode.verb) \(target.displayName)"
    }

    /// Where the work goes.
    enum Destination: Equatable {
        /// A new agent in a split beside the pane.
        case newSplit(VerticalTabAgentKind)
        /// An agent that's already running in another pane.
        case existing(Ghostty.SurfaceView)
    }

    /// One-click handoff from a menu: the conversation and the changes, to a new agent beside it.
    static func handOff(from surface: Ghostty.SurfaceView, in controller: BaseTerminalController,
                        to target: VerticalTabAgentKind, mode: Mode) {
        AgentContext.gather(from: surface, parts: [.conversation, .changes]) { context in
            send(prompt(mode: mode, context: context), from: surface, in: controller, to: .newSplit(target), mode: mode)
        }
    }

    /// Starts the new agent with the message, or queues it for a running one.
    static func send(_ prompt: String, from surface: Ghostty.SurfaceView, in controller: BaseTerminalController,
                     to destination: Destination, mode: Mode) {
        switch destination {
        case .newSplit(let target):
            guard let file = AgentTools.writePrompt(
                prompt, folder: "handoffs", name: "\(AgentTools.timestamp())-\(target.rawValue).md") else { return }
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = surface.pwd
            config.initialInput = AgentTools.agentCommand(target, promptFile: file)
            controller.newSplit(at: surface, direction: .right, baseConfig: config)
        case .existing(let target):
            let from = VerticalTabsAgents.shared.info(for: surface)?.kind.displayName ?? "another pane"
            AgentInbox.shared.deliver(prompt, to: target, label: "\(mode.title) from \(from)")
        }
    }

    /// Whether a handoff to `destination` should carry the source's project notes: only a
    /// running agent of the other kind needs them. A new one gets them when its session
    /// starts (shared memory, through the hooks) and one of the same kind has its own.
    static func needsMemory(from surface: Ghostty.SurfaceView, to destination: Destination) -> Bool {
        guard ExtremeSettings.isOn(.sharedMemory), case .existing(let target) = destination,
              let source = VerticalTabsAgents.shared.info(for: surface)?.kind,
              let receiver = VerticalTabsAgents.shared.info(for: target)?.kind else { return false }
        return source != receiver
    }

    /// Other panes running Claude Code or Codex, in any window.
    static func runningAgents(excluding surface: Ghostty.SurfaceView) -> [(surface: Ghostty.SurfaceView, info: VerticalTabAgentInfo, tab: String)] {
        TerminalWindows.all.flatMap { controller in
            controller.surfaceTree.compactMap { other -> (Ghostty.SurfaceView, VerticalTabAgentInfo, String)? in
                guard other !== surface, let info = VerticalTabsAgents.shared.info(for: other),
                      info.kind == .claude || info.kind == .codex else { return nil }
                return (other, info, TerminalWindows.title(of: other, in: controller) ?? other.pwd?.abbreviatedPath ?? "Tab")
            }
        }
    }

    /// The running agent closest to `surface`: another pane in the same tab, else one in the
    /// same project (repository).
    static func nearestAgent(to surface: Ghostty.SurfaceView) -> (surface: Ghostty.SurfaceView, info: VerticalTabAgentInfo, tab: String)? {
        let agents = runningAgents(excluding: surface)
        if let controller = TerminalWindows.controller(of: surface.window),
           let sameTab = agents.first(where: { agent in controller.surfaceTree.contains { $0 === agent.surface } }) {
            return sameTab
        }
        guard let root = VerticalTabsGit.shared.root(for: surface.pwd) else { return nil }
        return agents.first { VerticalTabsGit.shared.root(for: $0.surface.pwd) == root }
    }

    // MARK: The message

    static func prompt(mode: Mode, context: AgentContext) -> String {
        let who = context.agent.map { "another coding agent (\($0.displayName))" } ?? "someone"
        let background = context.isEmpty ? "There's no recorded context; look at the project's current state." : context.render()
        switch mode {
        case .review:
            return """
            You're reviewing work that \(who) just did in \(context.folder).

            \(background)

            Review those changes (run `git diff` and read new files if you need more than what's above). Look for \
            bugs, security problems, missed edge cases, and anything that doesn't match the task. List your findings \
            from most to least important, each with a file:line reference and a suggested fix. If everything looks \
            right, say so. Do not modify any files; this is a review only.
            """
        case .continue:
            return """
            You're taking over a task from \(who), who was working in \(context.folder) and stopped.

            \(background)

            First check the current state (`git diff` and the relevant files), then finish the task. Keep what's \
            already done unless it's wrong. When you're finished, summarize what you changed.
            """
        case .secondOpinion:
            return """
            \(who.prefix(1).uppercased() + who.dropFirst()) is working in \(context.folder) and I'd like a second opinion.

            \(background)

            Look at the task and the approach so far. Is it the right way to solve it? What would you do differently, \
            what risks or simpler options do you see? Answer with a short assessment and a concrete plan. Do not \
            modify any files.
            """
        }
    }
}

// MARK: - Hand Off window

extension AgentHandoff {
    static func showWindow(from surface: Ghostty.SurfaceView, in controller: BaseTerminalController,
                           mode: Mode = .review, target: VerticalTabAgentKind? = nil) {
        // A window still open from another pane would come forward unchanged and hand off
        // that pane's work (#10): start fresh for this one.
        AgentToolWindows.close(id: "handoff")
        AgentToolWindows.show(id: "handoff", title: "Hand Off", size: NSSize(width: 640, height: 720)) {
            HandoffView(surface: surface, controller: controller, mode: mode,
                        target: target ?? (VerticalTabsAgents.shared.info(for: surface)?.kind == .codex ? .claude : .codex))
        }
    }
}

private struct HandoffView: View {
    weak var surface: Ghostty.SurfaceView?
    weak var controller: BaseTerminalController?
    @State private var mode: AgentHandoff.Mode
    @State private var target: VerticalTabAgentKind
    /// Nil: a new agent in a split. Otherwise the running agent's pane.
    @State private var existing: ObjectIdentifier?
    @State private var parts: Set<AgentContext.Part> = [.conversation, .changes]
    /// The user changed "Project notes" themselves; stop choosing it for them.
    @State private var memoryTouched = false
    @State private var context: AgentContext?
    @State private var text = ""
    @State private var edited = false
    @State private var loading = false

    init(surface: Ghostty.SurfaceView, controller: BaseTerminalController, mode: AgentHandoff.Mode, target: VerticalTabAgentKind) {
        self.surface = surface
        self.controller = controller
        _mode = State(initialValue: mode)
        _target = State(initialValue: target)
    }

    private var running: [(surface: Ghostty.SurfaceView, info: VerticalTabAgentInfo, tab: String)] {
        surface.map { AgentHandoff.runningAgents(excluding: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ExtremeWindowTitle(icon: .branch, title: "Hand Off",
                                   subtitle: "Pass this pane's work to another agent, with the context it needs")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("What to do") {
                        HStack(spacing: 8) {
                            ForEach(AgentHandoff.Mode.allCases) { option in
                                choice(option.title, option.detail, selected: mode == option) { mode = option; refreshText() }
                            }
                        }
                    }
                    section("Who") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(AgentHandoff.targets, id: \.self) { kind in
                                radio("New \(kind.displayName) beside this pane", selected: existing == nil && target == kind) {
                                    existing = nil
                                    target = kind
                                }
                            }
                            ForEach(running, id: \.surface) { agent in
                                radio("\(agent.info.kind.displayName) in \(agent.tab) · \(agent.info.activity.label)",
                                      selected: existing == ObjectIdentifier(agent.surface)) {
                                    existing = ObjectIdentifier(agent.surface)
                                }
                            }
                            if existing != nil {
                                Text("It's sent when that agent finishes its turn and its input box is empty.")
                                    .font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
                            }
                        }
                    }
                    section("Include") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(AgentContext.Part.allCases) { part in
                                Toggle(isOn: Binding(get: { parts.contains(part) }, set: { on in
                                    if on { parts.insert(part) } else { parts.remove(part) }
                                    if part == .memory { memoryTouched = true }
                                    gather()
                                })) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(part.title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
                                        Text(part.detail).font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    section(edited ? "Message (edited)" : "Message") {
                        TextEditor(text: Binding(get: { text }, set: { text = $0; edited = true }))
                            .font(Extreme.mono(11))
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .extremePanel(fill: Extreme.raised)
                            .overlay { if loading { ProgressView().controlSize(.small) } }
                        Text("\(text.count) characters" + (edited ? " · your edits are kept until you change what's included" : ""))
                            .font(Extreme.font(10)).foregroundColor(Extreme.dim)
                    }
                }
                .padding(16)
            }
            Rectangle().fill(Extreme.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { AgentToolWindows.close(id: "handoff") }
                Button(existing == nil ? "Hand off to \(target.displayName)" : "Send when ready") { handOff() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .disabled(text.isEmpty || surface == nil || loading)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .extremeWindow()
        .onAppear(perform: gather)
        .onChange(of: existing) { _ in chooseMemory() }
    }

    private var destination: AgentHandoff.Destination {
        if let existing, let agent = running.first(where: { ObjectIdentifier($0.surface) == existing }) {
            return .existing(agent.surface)
        }
        return .newSplit(target)
    }

    /// Project notes go to running agents of the other kind (see `AgentHandoff.needsMemory`).
    private func chooseMemory() {
        guard !memoryTouched, let surface else { return }
        let wanted = AgentHandoff.needsMemory(from: surface, to: destination)
        guard wanted != parts.contains(.memory) else { return }
        if wanted { parts.insert(.memory) } else { parts.remove(.memory) }
        gather()
    }

    private func gather() {
        guard let surface else { return }
        // Test-only: which pane the window works from (`GHOSTTY_EXTREME_TEST_LOG`).
        if let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_LOG"] {
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (old + "handoff source: \(surface.pwd ?? "?")\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        loading = true
        AgentContext.gather(from: surface, parts: parts) { gathered in
            context = gathered
            loading = false
            edited = false
            refreshText()
        }
    }

    private func refreshText() {
        guard let context, !edited else { return }
        text = AgentHandoff.prompt(mode: mode, context: context)
    }

    private func handOff() {
        guard let surface, let controller else { return }
        AgentHandoff.send(text, from: surface, in: controller, to: destination, mode: mode)
        AgentToolWindows.close(id: "handoff")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ExtremeSectionLabel(title)
            content()
        }
    }

    private func choice(_ title: String, _ detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Extreme.font(12, weight: .semibold)).foregroundColor(selected ? Extreme.gold : Extreme.text)
                Text(detail).font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            .padding(10)
            .extremePanel(active: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Extreme.gold : Extreme.dim)
                Text(title).font(Extreme.font(12)).foregroundColor(Extreme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
