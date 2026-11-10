#if os(macOS)
import AppKit
import SwiftUI

/// A budget as it's typed: both caps as text, so a half-typed figure isn't a budget yet.
struct BudgetDraft: Equatable {
    var dollars = ""
    var tokens = ""
    var action = BudgetAction.pause

    init() {}

    init(_ budget: AgentBudget?) {
        guard let budget else { return }
        if let dollars = budget.dollars, dollars > 0 {
            self.dollars = String(format: dollars == dollars.rounded() ? "%.0f" : "%.2f", dollars)
        }
        if let tokens = budget.tokens, tokens > 0 { self.tokens = BudgetFormat.count(tokens) }
        action = budget.action
    }

    /// The budget typed, or nil while there's no cap or one of them can't be read.
    var budget: AgentBudget? {
        let cost = Self.parseDollars(dollars), count = Self.parseTokens(tokens)
        if !Self.isBlank(dollars), cost == nil { return nil }
        if !Self.isBlank(tokens), count == nil { return nil }
        guard cost != nil || count != nil else { return nil }
        return AgentBudget(dollars: cost, tokens: count, action: action)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "5", "$7.50", "1,200" -> dollars. Nil for anything else, and for nothing or less.
    static func parseDollars(_ text: String) -> Double? {
        let plain = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(plain), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static let units: [Character: Double] = ["k": 1e3, "m": 1e6, "b": 1e9]

    /// "2M", "500k", "1.5 M", "1,500,000" -> tokens.
    static func parseTokens(_ text: String) -> Int? {
        var plain = text.lowercased().replacingOccurrences(of: "tokens", with: "")
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        var scale = 1.0
        if let unit = plain.last, let factor = units[unit] {
            scale = factor
            plain.removeLast()
        }
        guard let value = Double(plain), value.isFinite, value > 0, value * scale < 1e15 else { return nil }
        return Int((value * scale).rounded())
    }
}

/// The meter itself: a thin bar that fills toward the cap. It never moves on its own.
struct BudgetMeterBar: View {
    let fraction: Double
    let state: BudgetStatus.State

    static func color(_ state: BudgetStatus.State) -> Color {
        switch state {
        case .ok: return Tellurion.gold
        case .warning: return Tellurion.warn
        case .reached, .paused: return Tellurion.danger
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Tellurion.line.opacity(0.8))
                Capsule().fill(Self.color(state))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// On an agent's sidebar card and Mission Control card when a budget applies: the meter with
/// "$1.20 of $5", a note past 80%, and at the cap what to do about it. Click the meter to
/// change the budget.
struct AgentBudgetLine: View {
    let surface: Ghostty.SurfaceView
    var compact = false
    @ObservedObject private var budgets = AgentBudgets.shared
    @State private var editing = false

    var body: some View {
        if let status = budgets.status(for: surface) {
            VStack(alignment: .leading, spacing: 4) {
                Button { editing = true } label: {
                    HStack(spacing: 6) {
                        BudgetMeterBar(fraction: status.fraction, state: status.state).frame(width: compact ? 42 : 72)
                        Text(BudgetFormat.progress(status))
                            .font(Tellurion.mono(10)).foregroundColor(status.state == .ok ? Tellurion.dim : BudgetMeterBar.color(status.state))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(status))
                .accessibilityLabel("Budget: \(BudgetFormat.progress(status))")
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    AgentBudgetEditor(surface: surface) { editing = false }
                }
                switch status.state {
                case .ok:
                    EmptyView()
                case .warning:
                    if budgets.showsNotice(for: surface) { warning }
                case .reached:
                    atTheCap("Budget reached", symbol: "exclamationmark.circle.fill", lead: "Raise by", status)
                case .paused:
                    atTheCap("Paused at budget", symbol: "pause.circle.fill", lead: "Resume with", status)
                }
            }
            .padding(.top, 2)
        }
    }

    private func help(_ status: BudgetStatus) -> String {
        var lines = ["This session's budget. Dollars are what its usage would cost at API prices."]
        if status.spent == nil, let models = budgets.usage(for: surface)?.unpriced, !models.isEmpty {
            lines.append("The cost is unknown: no price for \(models.sorted().joined(separator: ", ")). Only a token cap counts.")
        }
        lines.append("Click to change it.")
        return lines.joined(separator: "\n")
    }

    /// Shown once past 80%, until it's dismissed.
    private var warning: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
            Text("Close to its budget").lineLimit(1)
            Spacer(minLength: 2)
            Button { budgets.hideNotice(for: surface) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(Tellurion.font(10.5))
        .foregroundColor(Tellurion.warn)
    }

    private func atTheCap(_ title: String, symbol: String, lead: String, _ status: BudgetStatus) -> some View {
        let budget = budgets.budget(for: surface)?.budget ?? AgentBudget()
        let add = Button(BudgetFormat.fixedStep(budget, spent: status.spent, tokens: status.tokens)) {
            budgets.raise(.fixed, for: surface)
        }
        let half = Button("+50%") { budgets.raise(.half, for: surface) }
        let remove = Button("Remove budget") { budgets.removeBudget(for: surface) }
        let leadText = Text(lead).foregroundColor(Tellurion.muted)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).lineLimit(1)
            }
            .foregroundColor(Tellurion.danger)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    leadText
                    add
                    half
                    remove
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        leadText
                        add
                        half
                    }
                    remove
                }
            }
            .buttonStyle(TellurionButtonStyle())
            .controlSize(.small)
            .help(status.state == .paused ? "Raising the budget lets the agent carry on where it stopped"
                                          : "The agent is still running")
        }
        .font(Tellurion.font(10.5, weight: .semibold))
    }
}

/// The meter alone, for a board tile's title bar.
struct AgentBudgetMeter: View {
    let surface: Ghostty.SurfaceView
    @ObservedObject private var budgets = AgentBudgets.shared

    var body: some View {
        if let status = budgets.status(for: surface) {
            BudgetMeterBar(fraction: status.fraction, state: status.state)
                .frame(width: 34)
                .help("Budget: \(BudgetFormat.progress(status))")
        }
    }
}

/// The two caps and what happens at the limit.
struct BudgetFields: View {
    @Binding var draft: BudgetDraft

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                label("Cost")
                field("$5", $draft.dollars, valid: draft.dollars.isEmpty || BudgetDraft.parseDollars(draft.dollars) != nil)
                    .accessibilityLabel("Cost in dollars")
                hint("dollars, at API prices")
            }
            GridRow {
                label("Tokens")
                field("2M", $draft.tokens, valid: draft.tokens.isEmpty || BudgetDraft.parseTokens(draft.tokens) != nil)
                    .accessibilityLabel("Tokens")
                hint("in and out, cached context included")
            }
            GridRow {
                label("At the limit")
                Picker("", selection: $draft.action) {
                    ForEach(BudgetAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .gridCellColumns(2)
                .accessibilityLabel("At the limit")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Tellurion.font(11.5, weight: .semibold)).foregroundColor(Tellurion.text)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Tellurion.font(10.5, weight: .regular)).foregroundColor(Tellurion.muted)
    }

    private func field(_ placeholder: String, _ text: Binding<String>, valid: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Tellurion.mono(11.5))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .frame(width: 92)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Tellurion.ink))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(valid ? Tellurion.line : Tellurion.danger, lineWidth: 1))
    }
}

/// "Budget…" for one agent: its own cap, which wins over the defaults.
struct AgentBudgetEditor: View {
    let surface: Ghostty.SurfaceView
    var close: () -> Void = {}
    @ObservedObject private var budgets = AgentBudgets.shared
    @State private var draft = BudgetDraft()
    @State private var project: String?

    private var info: VerticalTabAgentInfo? { VerticalTabsAgents.shared.info(for: surface) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Budget for \(info?.name ?? "this pane")").font(Tellurion.font(14, weight: .semibold)).foregroundColor(Tellurion.gold)
                Text(current).font(Tellurion.font(10.5)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BudgetFields(draft: $draft)
            Text(note).font(Tellurion.font(10.5, weight: .regular)).foregroundColor(Tellurion.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if budgets.budget(for: surface) != nil {
                    Button("Remove budget") {
                        budgets.removeBudget(for: surface)
                        close()
                    }
                } else if budgets.ownBudget(for: surface) != nil {
                    Button("Use the defaults") {
                        budgets.useDefaults(for: surface)
                        close()
                    }
                }
                Spacer(minLength: 8)
                if let project {
                    Button("Set for \((project as NSString).lastPathComponent)") {
                        budgets.setProject(draft.budget, root: project)
                        close()
                    }
                    .disabled(draft.budget == nil)
                    .help("The default for new agent sessions in \(project)")
                }
                Button("Set") {
                    if let budget = draft.budget { budgets.setBudget(budget, for: surface) }
                    close()
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .disabled(draft.budget == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Tellurion.panel)
        .buttonStyle(TellurionButtonStyle())
        .onAppear {
            draft = BudgetDraft(budgets.ownBudget(for: surface).flatMap { $0.isSet ? $0 : nil } ?? budgets.budget(for: surface)?.budget)
            guard let folder = surface.pwd else { return }
            budgets.project(of: folder) { project = $0 }
        }
    }

    /// What holds this session now.
    private var current: String {
        if let (budget, scope) = budgets.budget(for: surface) {
            let used = budgets.usage(for: surface).map { usage in
                " Used so far: " + [usage.spent.map(BudgetFormat.money), "\(BudgetFormat.count(usage.tokens)) tokens"]
                    .compactMap { $0 }.joined(separator: ", ") + "."
            } ?? ""
            return "\(scope.label): \(BudgetFormat.caps(budget)).\(used)"
        }
        if budgets.ownBudget(for: surface) != nil { return "No budget for this agent, whatever the defaults say." }
        if !AgentBudgets.canMeasure(info) { return "Budgets measure Claude Code and Codex sessions." }
        return "No budget. Setting one measures this session from its start."
    }

    private var note: String {
        if info?.localCodex != nil {
            return "A model on this Mac costs nothing, so only a token cap counts."
        }
        if info?.veniceModel != nil {
            return "Dollars use Venice's prices for the model, once the Local Models window has loaded them. Until then only a token cap counts."
        }
        return "Dollars are what the usage would cost at API prices. On a subscription plan you aren't billed this; it's the API value the Activity window shows."
    }
}

/// "Budget…" on a Mission Control card.
struct AgentBudgetButton: View {
    let surface: Ghostty.SurfaceView
    @ObservedObject private var settings = TellurionSettings.shared
    @State private var editing = false

    var body: some View {
        if settings.isOn(.budgets), AgentBudgets.canMeasure(VerticalTabsAgents.shared.info(for: surface)) {
            Button("Budget…") { editing = true }
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    AgentBudgetEditor(surface: surface) { editing = false }
                }
        }
    }
}

/// "Budget…" from a menu or the command palette, where there's no button to hang a popover
/// on: it opens where the pointer is, or over the pane itself.
enum AgentBudgetPopover {
    private static var popover: NSPopover?

    static func show(for surface: Ghostty.SurfaceView, atPointer: Bool = true) {
        guard TellurionSettings.isOn(.budgets) else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let editor = AgentBudgetEditor(surface: surface) { [weak popover] in popover?.close() }
        popover.contentViewController = NSHostingController(rootView: DesignSkin { editor })
        if atPointer, let window = NSApp.keyWindow ?? surface.window, let view = window.contentView {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .maxX)
        } else if surface.window != nil {
            let top = NSRect(x: surface.bounds.midX, y: surface.isFlipped ? surface.bounds.minY : surface.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: top, of: surface, preferredEdge: .minY)
        } else {
            return
        }
        self.popover = popover
    }
}

extension AgentBudgets {
    /// The command palette's entries: the Budgets window, and this pane's own budget when
    /// its agent can be measured.
    static func paletteOptions(for surface: Ghostty.SurfaceView) -> [CommandOption] {
        guard TellurionSettings.isOn(.budgets) else { return [] }
        var options = [CommandOption(
            title: "Budgets",
            description: "What an agent session may cost or use before it stops, for every session or per project",
            leadingIcon: "dollarsign.circle"
        ) {
            BudgetsWindow.show()
        }]
        if canMeasure(VerticalTabsAgents.shared.info(for: surface)) {
            options.append(CommandOption(
                title: "Budget for This Agent…",
                description: "Cap what this session may cost at API prices or use in tokens",
                leadingIcon: "dollarsign.circle"
            ) {
                AgentBudgetPopover.show(for: surface, atPointer: false)
            })
        }
        return options
    }
}

/// Where the defaults live: one for every new session, and one per project.
enum BudgetsWindow {
    static let windowID = "budgets"

    static func show() {
        guard TellurionSettings.isOn(.budgets) else { return }
        AgentToolWindows.show(id: windowID, title: "Budgets", size: NSSize(width: 560, height: 640)) {
            BudgetsView()
        }
    }
}

private struct BudgetsView: View {
    @ObservedObject private var budgets = AgentBudgets.shared
    /// The projects of the folders that are open, to offer a default for.
    @State private var open: Set<String> = []

    private var projects: [String] {
        Set(budgets.settings.projects.keys).union(open).sorted()
    }

    private var measured: [Ghostty.SurfaceView] {
        TerminalWindows.surfaces.map { $0.surface }.filter { budgets.status(for: $0) != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TellurionWindowTitle(icon: .chart, title: "Budgets", subtitle: "What an agent session may use before it stops")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        TellurionSectionLabel("Every new session")
                        BudgetDefaultRow(title: "Default budget", detail: "For each Claude Code and Codex session started from now on",
                                         budget: budgets.settings.everywhere, offTitle: "Turn Off") { budgets.setDefault($0) }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TellurionSectionLabel("Projects")
                        if projects.isEmpty {
                            Text("Open a project in a tab to give it its own default.")
                                .font(Tellurion.font(11)).foregroundColor(Tellurion.muted)
                        }
                        ForEach(projects, id: \.self) { root in
                            BudgetDefaultRow(title: (root as NSString).lastPathComponent,
                                             detail: (root as NSString).abbreviatingWithTildeInPath,
                                             budget: budgets.settings.projects[root], offTitle: "Remove") {
                                budgets.setProject($0, root: root)
                            }
                        }
                    }
                    if !measured.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            TellurionSectionLabel("Agents now")
                            ForEach(measured, id: \.id) { surface in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(surface)).font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    AgentBudgetLine(surface: surface)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .tellurionPanel()
                            }
                        }
                    }
                    Text("""
                    A budget caps one session: what its usage would cost at API prices, its tokens, or both. \
                    On a subscription plan the dollars aren't billed; they're the API value the Activity window shows. \
                    A project's default wins over the general one, and a budget set on an agent's own card wins over both. \
                    A paused agent is frozen, not stopped: raise or remove its budget and it carries on.
                    """)
                    .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear(perform: findProjects)
    }

    private func title(_ surface: Ghostty.SurfaceView) -> String {
        let name = VerticalTabsAgents.shared.info(for: surface)?.name ?? "Agent"
        return [name, surface.pwd.map { ($0 as NSString).abbreviatingWithTildeInPath }].compactMap { $0 }.joined(separator: " · ")
    }

    private func findProjects() {
        for folder in Set(TerminalWindows.surfaces.compactMap { $0.surface.pwd }) {
            budgets.project(of: folder) { open.insert($0) }
        }
    }
}

/// One default: its caps, with Save and a way to turn it off.
private struct BudgetDefaultRow: View {
    let title: String
    let detail: String
    let budget: AgentBudget?
    let offTitle: String
    let save: (AgentBudget?) -> Void
    @State private var draft = BudgetDraft()

    /// Whether what's typed differs from what's saved.
    private var changed: Bool {
        guard let typed = draft.budget else { return false }
        return typed.dollars != budget?.dollars || typed.tokens != budget?.tokens || typed.action != budget?.action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Tellurion.font(12.5, weight: .semibold)).foregroundColor(Tellurion.text)
                    Text(detail).font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(budget.map(BudgetFormat.caps) ?? "Off").font(Tellurion.mono(11))
                    .foregroundColor(budget == nil ? Tellurion.dim : Tellurion.gold)
            }
            BudgetFields(draft: $draft)
            HStack(spacing: 8) {
                Spacer()
                if budget != nil {
                    Button(offTitle) {
                        save(nil)
                        draft = BudgetDraft()
                    }
                }
                Button("Save") { save(draft.budget) }
                    .buttonStyle(TellurionButtonStyle(prominent: changed))
                    .disabled(!changed)
            }
        }
        .padding(10)
        .tellurionPanel()
        .onAppear { draft = BudgetDraft(budget) }
        .onChange(of: budget) { draft = BudgetDraft($0) }
    }
}
#endif
