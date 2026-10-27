#if os(macOS)
import SwiftUI

/// The sidebar's "Tools" button: every tool by name, with what it's for and its shortcut,
/// including the ones that don't fit as icons in the header.
struct ToolsButton: View {
    let owner: BaseTerminalController
    @Binding var condensed: Bool
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let lit = open || hovering
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Text("Tools").font(Extreme.font(11.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .fixedSize()
            .foregroundColor(lit ? Extreme.gold : Extreme.text.opacity(0.85))
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .background(shape.fill(lit ? Extreme.raised : Extreme.panel))
            .overlay(shape.strokeBorder(lit ? Extreme.gold.opacity(0.55) : Extreme.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: lit)
        .help("Every tool, with its shortcut")
#if TELLURION_TEST_HOOKS
        .onReceive(NotificationCenter.default.publisher(for: VerticalTabsTestSupport.showOverlay)) { _ in
            if VerticalTabsTestSupport.overlayMode == "tools", owner.window?.isKeyWindow ?? false { open = true }
        }
#endif
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ToolsPanel(owner: owner, condensed: $condensed) { action in
                open = false
                // After the popover closes, so a window it opens comes to the front.
                DispatchQueue.main.async(execute: action)
            }
        }
    }
}

private struct ToolsPanel: View {
    let owner: BaseTerminalController
    @Binding var condensed: Bool
    let run: (@escaping () -> Void) -> Void
    @ObservedObject private var settings = ExtremeSettings.shared

    private struct Tool: Identifiable {
        let feature: ExtremeFeature?
        let symbol: String
        let title: String
        let detail: String
        var shortcut: String?
        let action: () -> Void
        var id: String { title }
    }

    private struct Section: Identifiable {
        let title: String
        let tools: [Tool]
        var id: String { title }
    }

    /// The tools in groups; a group whose tools are all off isn't shown.
    private var sections: [Section] {
        let pwd = owner.focusedSurface?.pwd
        let hermes = HermesSessions.shared.isHermes(owner)
        let board = owner as? BoardController
        var group: [Tool] = []
        var all: [Section] = []
        func add(_ feature: ExtremeFeature, _ symbol: String, _ title: String, _ detail: String,
                 _ action: @escaping () -> Void) {
            guard settings.isOn(feature) else { return }
            group.append(Tool(feature: feature, symbol: symbol, title: title, detail: detail,
                              shortcut: feature.shortcut.map { "⌃⌘" + $0 }, action: action))
        }
        func section(_ title: String) {
            if !group.isEmpty { all.append(Section(title: title, tools: group)) }
            group = []
        }

        if !hermes {
            if board == nil {
                add(.editor, PixelIcon.code.symbol, "Code editor", "Watch the agent edit, live") { EditorPanel.shared.toggle(from: owner) }
            }
            add(.visualFix, PixelIcon.target.symbol, "Visual Fix", "Point at your app, have it changed") { VisualFixPanel.shared.toggle(owner) }
            add(.commandHistory, "list.bullet.rectangle", "Command history", "Every command with its output") { CommandBlocksPanel.shared.toggle(owner) }
        }
        section(board == nil ? "This tab" : "This tile")

        if let board {
            group.append(Tool(feature: nil, symbol: "map", title: "Agent map", detail: "Where agents are working, file by file",
                              shortcut: "⌃⌘M") { [weak board] in board?.showAgentMap() })
        } else {
            add(.missionControl, PixelIcon.grid.symbol, "Mission Control", "Every agent as a live card", MissionControl.toggle)
        }
        if !hermes {
            add(.races, "flag.checkered.2.crossed", "Agent races", "One task, several agents, keep the best") { AgentRaces.showSetup(from: owner) }
        }
        add(.review, PixelIcon.inbox.symbol, "Review changes", "Each agent's finished work", ReviewInbox.toggle)
        add(.activity, PixelIcon.chart.symbol, "Agent activity", "Time, prompts, files and tokens", ActivityDashboard.toggle)
        section("Agents")

        add(.localhost, PixelIcon.globe.symbol, "Localhost", "Dev servers your agents started", LocalhostManager.toggle)
        add(.skills, PixelIcon.skills.symbol, "Skills", "Installed skills, updates, trending") { SkillsWindow.show(folder: pwd) }
        if pwd != nil {
            add(.memory, PixelIcon.memory.symbol, "Project memory", "What your agents remember here") { MemoryWindow.show(folder: pwd) }
        }
        add(.environment, PixelIcon.environment.symbol, "Environment", "Tool versions, containers, models") { EnvironmentWindow.show(folder: pwd) }
        section("Project")

        add(.background, "gauge.with.dots.needle.67percent", "Background processes", "Servers and agents left running", HousekeepingWindow.show)
        add(.phone, PixelIcon.phone.symbol, "Phone", "Your terminal on your phone, paired devices", PhoneSetup.show)
        add(.localModels, "cpu", "Local models", "Chat with a model on this Mac", LocalModelsWindow.show)
        section("This Mac")

        let condense = condensed
        group = [
            Tool(feature: nil, symbol: PixelIcon.layout.symbol, title: "Layout",
                 detail: "Move the tabs, terminal and panels around", action: LayoutWindow.show),
            Tool(feature: nil, symbol: PixelIcon.design.symbol, title: "Design",
                 detail: "Templates, your own colors and logo", action: DesignWindow.show),
        ]
        // Boards list their tiles their own way.
        if !(owner is BoardController) {
            group.append(Tool(feature: nil, symbol: (condense ? PixelIcon.expand : .condense).symbol,
                              title: condense ? "Expand view" : "Condense view",
                              detail: condense ? "Show agent details on each tab" : "One line per tab") { condensed.toggle() })
        }
        group.append(Tool(feature: nil, symbol: "gearshape", title: "Settings", detail: "Turn tools on or off",
                          shortcut: "⌃⌘,", action: ExtremeSettingsWindow.show))
        section("View")
        return all
    }

    var body: some View {
        let sections = sections
        VStack(alignment: .leading, spacing: 1) {
            ForEach(sections) { section in
                Text(section.title.uppercased())
                    .font(Extreme.font(9.5, weight: .semibold))
                    .kerning(1.1)
                    .foregroundColor(Extreme.muted)
                    .padding(.horizontal, 8)
                    .padding(.top, section.id == sections.first?.id ? 4 : 10)
                    .padding(.bottom, 3)
                ForEach(section.tools) { tool in
                    ToolsPanelRow(symbol: tool.symbol, title: tool.title, detail: tool.detail,
                                  shortcut: tool.shortcut) { run(tool.action) }
                }
            }
        }
        .padding(6)
        .frame(width: 300)
        .onAppear {
            // `GHOSTTY_EXTREME_TEST_TOOL=<title>`: choose that tool once the panel is open.
            guard let title = TestHooks.tool,
                  let tool = sections.flatMap(\.tools).first(where: { $0.title == title }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run(tool.action) }
        }
        .background(Extreme.panel)
        .environment(\.colorScheme, .dark)
    }
}

private struct ToolsPanelRow: View {
    let symbol: String
    let title: String
    let detail: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(hovering ? Extreme.gold : Extreme.text.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Extreme.ink))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(hovering ? Extreme.gold.opacity(0.5) : Extreme.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Extreme.font(11.5, weight: .semibold))
                        .foregroundColor(hovering ? Extreme.gold : Extreme.text)
                    Text(detail).font(Extreme.font(10)).foregroundColor(Extreme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut).font(Extreme.mono(10)).foregroundColor(Extreme.dim)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Extreme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
