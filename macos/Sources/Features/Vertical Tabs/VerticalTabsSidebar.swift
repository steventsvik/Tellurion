#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Places the vertical tabs sidebar, the terminal content and the side panels in the
/// order the Layout window sets (by default the sidebar on the left).
struct VerticalTabsLayout<Content: View>: View {
    let controller: TerminalController
    @ObservedObject var ghostty: Ghostty.App
    @StateObject private var model: VerticalTabsModel
    @StateObject private var overlay = VerticalTabsOverlayState()
    @ObservedObject private var editorPanel = EditorPanel.shared
    @ObservedObject private var hermes = HermesSessions.shared
    @ObservedObject private var commandBlocks = CommandBlocksPanel.shared
    @ObservedObject private var visualFix = VisualFixPanel.shared
    /// Pauses the chrome's animations while this window (tab) isn't on screen.
    @StateObject private var motion = WindowMotion()
    @ObservedObject private var settings = ExtremeSettings.shared
    @ObservedObject private var design = DesignStore.shared
    @AppStorage(EditorPanel.widthKey) private var editorWidth: Double = EditorPanel.defaultWidth
    @AppStorage(VisualFixPanel.widthKey) private var visualFixWidth: Double = VisualFixPanel.defaultWidth
    @AppStorage(AgentAurora.enabledKey) private var aurora = false
    @AppStorage(VerticalTabs.visibleKey) private var visible: Bool = true
    @AppStorage(VerticalTabs.widthKey) private var width: Double = VerticalTabs.defaultWidth
    @ObservedObject private var layout = WindowLayout.shared
    /// Where the sidebar is, so the hover card opens beside it on the terminal's side.
    @State private var sidebarFrame: CGRect = .zero
    private let content: Content

    init(controller: TerminalController, ghostty: Ghostty.App, @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.ghostty = ghostty
        self._model = StateObject(wrappedValue: VerticalTabsModel(owner: controller))
        self.content = content()
    }

    /// The terminal never gets narrower than this to make room for side panels.
    private var minTerminalWidth: CGFloat { 320 }

    var body: some View {
        // Side panels have set widths; when the window is narrower than they need (macOS can
        // hand a window back smaller, e.g. from Stage Manager), the editor gives way so
        // nothing is pushed past the window's edge.
        GeometryReader { geometry in
            let limits = panelLimits(in: geometry.size.width)
            layout(maxEditorWidth: limits.editor, maxVisualFixWidth: limits.visualFix)
        }
        // "Status only" in Settings stops the decorative motion everywhere.
        .environment(\.extremeMotion, motion.active && settings.motion == .full)
        .onAppear { motion.attach(controller.window) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in motion.attach(controller.window) }
    }

    /// The most room the editor and Visual Fix can each have. When both want more than the
    /// window has, they share it in proportion.
    private func panelLimits(in total: CGFloat) -> (editor: CGFloat, visualFix: CGFloat) {
        let sidebar = visible && ghostty.readiness == .ready ? CGFloat(width) + 1 : 0
        let history: CGFloat = commandBlocks.isVisible(controller) ? 400 : 0
        let available = max(0, total - sidebar - history - minTerminalWidth - 2)
        let editor = editorPanel.isVisible(controller) ? CGFloat(editorWidth) : 0
        let fix = visualFix.isVisible(controller) ? CGFloat(visualFixWidth) : 0
        guard editor + fix > available, editor + fix > 0 else { return (max(240, available), max(360, available)) }
        let scale = available / (editor + fix)
        return (max(240, editor * scale), max(300, fix * scale))
    }

    private func layout(maxEditorWidth: CGFloat, maxVisualFixWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(layout.order) { box in
                part(box, maxEditorWidth: maxEditorWidth, maxVisualFixWidth: maxVisualFixWidth)
            }
        }
        .coordinateSpace(name: verticalTabsSpace)
        .overlay {
            if visible && ghostty.readiness == .ready {
                VerticalTabsOverlayLayer(
                    state: overlay,
                    palette: VerticalTabsPalette(config: ghostty.config),
                    sidebarFrame: sidebarFrame,
                    sidebarOnLeft: layout.isLeftOfTerminal(.tabs))
                .id(design.revision)
            }
        }
        .onChange(of: visible) { _ in overlay.dismissAll() }
        .onAppear {
            VerticalTabsMenu.shared.installIfNeeded()
            ExtremeLaunch.start()
            ReviewInbox.start()
            TurnCheckpoints.start()
            VerticalTabsTestSupport.openTestTabsIfRequested(from: controller)
        }
    }

    @ViewBuilder
    private func part(_ box: LayoutBox, maxEditorWidth: CGFloat, maxVisualFixWidth: CGFloat) -> some View {
        switch box {
        case .tabs:
            if visible && ghostty.readiness == .ready {
                // The handle is on the side facing the terminal.
                let left = layout.isLeftOfTerminal(.tabs)
                let handle = ColumnResizeHandle(color: Extreme.line, width: $width,
                                                range: VerticalTabs.widthRange, onTrailingEdge: left)
                if !left { handle }
                VerticalTabsSidebar(model: model, owner: controller, config: ghostty.config)
                    .id(design.revision)
                    .frame(width: width)
                    .environmentObject(overlay)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { sidebarFrame = geometry.frame(in: .named(verticalTabsSpace)) }
                                .onChange(of: geometry.frame(in: .named(verticalTabsSpace))) { sidebarFrame = $0 }
                        })
                if left { handle }
            }
        case .terminal:
            // A Hermes tab shows Hermes's own app over its (hidden, idle) terminal.
            ZStack {
                content
                if hermes.isHermes(controller) {
                    HermesSessionView(controller: controller)
                }
                // Light behind the terminal that follows the tab's agents.
                if aurora, !hermes.isHermes(controller) {
                    AgentAurora(controller: controller)
                }
                // "Your app is live" when a localhost session starts listening.
                LocalhostToastLayer(controller: controller)
                // Branding: pixel corner brackets (a traveling light while an agent works)
                // and the sigil assembling when the tab opens.
                Group {
                    TerminalFrameOverlay(controller: controller)
                    NewTabSplash()
                }
                .id(design.revision)
            }
        case .editor:
            // Each tab has its own editor.
            if editorPanel.isVisible(controller) {
                EditorPanelColumn(controller: controller, maxWidth: maxEditorWidth)
            }
        case .visualFix:
            // Point at the running app and have the agent change it.
            if visualFix.isVisible(controller) {
                VisualFixColumn(controller: controller, maxWidth: maxVisualFixWidth)
            }
        case .history:
            if commandBlocks.isVisible(controller) {
                CommandBlocksColumn(controller: controller)
            }
        }
    }
}

/// Which tab groups are collapsed. Shared so every window's sidebar agrees.
final class VerticalTabsCollapse: ObservableObject {
    static let shared = VerticalTabsCollapse()
    @Published var collapsed: Set<ObjectIdentifier> = []

    func toggle(_ id: ObjectIdentifier) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

struct VerticalTabsSidebar: View {
    @ObservedObject var model: VerticalTabsModel
    let owner: TerminalController
    let config: Ghostty.Config

    @AppStorage(VerticalTabs.condensedKey) private var condensed = false
    @ObservedObject private var collapse = VerticalTabsCollapse.shared
    @ObservedObject private var localhost = LocalhostSessions.shared
    @ObservedObject private var projects = VerticalTabsProjects.shared
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        let palette = VerticalTabsPalette(config: config)
        // Localhost sessions get their own cards at the end, whatever their tab order
        // (unless the feature is off; then they're ordinary tabs).
        let localhostOn = settings.isOn(.localhost)
        let isLocalhost: (VerticalTabEntry) -> Bool = { entry in
            localhostOn && (entry.controller.map { localhost.session(for: $0) != nil } ?? false)
        }
        let localhostTabs = model.tabs.filter(isLocalhost)

        VStack(spacing: 0) {
            header
            Rectangle().fill(Extreme.line).frame(height: 1)
            if let updates = (NSApp.delegate as? AppDelegate)?.updateViewModel {
                UpdateCard(model: updates)
            }

            ScrollView {
                // Not lazy: a lazy stack estimates the height of rows scrolled out of view, so
                // when agent rows change height it loses the scroll position and jumps.
                VStack(alignment: .leading, spacing: 6) {
                    ExtremeSectionLabel("Sessions") {
                        Text("\(model.tabs.count - localhostTabs.count)")
                            .font(Extreme.font(10)).foregroundColor(Extreme.dim)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    ForEach(items(excluding: isLocalhost)) { item in
                        switch item {
                        case .tab(let index, let entry):
                            if let controller = entry.controller {
                                tabGroup(controller, entry: entry, index: index, palette: palette)
                                    .transition(.opacity)
                            }
                        case .project(let group, let members):
                            VerticalTabsProjectGroupView(
                                group: group,
                                controllers: members.compactMap(\.1.controller),
                                owner: owner
                            ) {
                                VStack(spacing: 6) {
                                    ForEach(members, id: \.1.id) { index, entry in
                                        if let controller = entry.controller {
                                            tabGroup(controller, entry: entry, index: index, palette: palette, inProject: true)
                                        }
                                    }
                                }
                            }
                            .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                                    removal: .opacity))
                        }
                    }
                }
                .padding(.bottom, 10)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: groupLayout)
            }

            // What's listening on which port (only when something is).
            if settings.isOn(.ports) {
                PortsSidebarSection(owner: owner)
            }

            // Models on this Mac, to open or drag under a chat (only when Ollama has some).
            if settings.isOn(.localModels) {
                LocalModelsSidebarSection(owner: owner)
            }

            // Localhost sessions stay in view, whatever else is open.
            if !localhostTabs.isEmpty {
                Rectangle().fill(Extreme.line).frame(height: 1)
                LocalhostSidebarSection(entries: localhostTabs, owner: owner)
            }

            // Agent status needs setting up, or a live test just passed (only then).
            SetupSidebarChip().padding(.horizontal, 8).padding(.bottom, 6)

            // Things left running in the background that look finished (only when there are some).
            if settings.isOn(.background) {
                HousekeepingChip().padding(.horizontal, 8).padding(.bottom, 6)
            }

            // Bottom left: live usage of the user's AI subscriptions.
            if settings.isOn(.usage) {
                Rectangle().fill(Extreme.line).frame(height: 1)
                UsagePanel(palette: palette)
            }
        }
        .background(sidebarBackground)
        .onAppear { Extreme.registerFonts() }
    }

    /// What the list's layout depends on: which groups exist and how many tabs each holds.
    private var groupLayout: [String] {
        projects.groups.values.map { "\($0.id):\($0.members.count)" }.sorted()
    }

    /// One sidebar entry: a tab on its own, or a project's tabs bracketed together.
    private enum Item: Identifiable {
        case tab(Int, VerticalTabEntry)
        case project(VerticalTabsProjects.Group, [(Int, VerticalTabEntry)])

        var id: String {
            switch self {
            case .tab(_, let entry): return "tab-\(entry.id.hashValue)"
            case .project(let group, _): return "project-" + group.id
            }
        }
    }

    /// Tabs in order, with each project's tabs gathered where its first tab is.
    private func items(excluding isLocalhost: (VerticalTabEntry) -> Bool) -> [Item] {
        var result: [Item] = []
        var placed: Set<String> = []
        let tabs = Array(model.tabs.enumerated()).filter { !isLocalhost($0.element) }
        for (offset, entry) in tabs {
            guard let controller = entry.controller else { continue }
            if let group = projects.group(for: controller) {
                guard placed.insert(group.id).inserted else { continue }
                let members = tabs.filter { $0.element.controller.map { group.members.contains(ObjectIdentifier($0)) } ?? false }
                result.append(.project(group, members.map { ($0.offset + 1, $0.element) }))
            } else {
                result.append(.tab(offset + 1, entry))
            }
        }
        return result
    }

    private func tabGroup(_ controller: TerminalController, entry: VerticalTabEntry, index: Int,
                          palette: VerticalTabsPalette, inProject: Bool = false) -> some View {
        VerticalTabGroup(
            controller: controller,
            owner: owner,
            index: index,
            tabColor: entry.tabColor,
            condensed: condensed,
            collapsed: collapse.collapsed.contains(entry.id),
            palette: palette,
            inProject: inProject,
            onToggleCollapse: { collapse.toggle(entry.id) })
    }

    /// The terminal's own background, a shade deeper (just a touch on a light design,
    /// where a dark wash would gray it out).
    private var sidebarBackground: some View {
        ZStack {
            config.backgroundColor.opacity(config.backgroundOpacity)
            Color.black.opacity(Extreme.chrome.isLight ? 0.05 : 0.28)
        }
    }

    /// The sigil and wordmark, then the tools.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                LivingSigil(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TELLURION")
                        .font(Extreme.font(11.5))
                        .kerning(3.6)
                        .foregroundColor(Extreme.gold)
                        .extremeGlint()
                    Text("Α Ι · ΣΥΣΤΗΜΑ")
                        .font(Extreme.font(9))
                        .kerning(2.4)
                        .foregroundColor(Extreme.dim)
                }
                Spacer(minLength: 0)
            }
            // As many tool icons as fit; the Tools button lists all of them.
            ViewThatFits(in: .horizontal) {
                toolRow(.none)
                toolRow(.some)
                toolRow(.most)
                toolRow(.least)
                toolRow(.all)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// How many tool icons a narrow sidebar leaves out (they're still under Tools).
    private enum Overflow: Int { case none, some, most, least, all }

    private func toolRow(_ overflow: Overflow) -> some View {
        HStack(spacing: overflow == .none ? 6 : 4) {
            NewSessionMenu(owner: owner, compact: true)
            Spacer(minLength: 0)
            if overflow != .all, settings.isOn(.editor) { EditorHeaderButton(owner: owner) }
            if overflow.rawValue < Overflow.least.rawValue, settings.isOn(.localhost) { LocalhostHeaderButton() }
            if overflow.rawValue < Overflow.least.rawValue, settings.isOn(.review) { ReviewHeaderButton() }
            if overflow == .none, settings.isOn(.activity) {
                ExtremeIconButton(icon: .chart, help: "Agent activity and usage graphs (⌃⌘A)", action: ActivityDashboard.toggle)
            }
            if overflow.rawValue < Overflow.most.rawValue, settings.isOn(.skills) {
                ExtremeIconButton(icon: .skills, help: "Skills: what your agents have installed, updates, and what's trending (⌃⌘U)") {
                    SkillsWindow.show(folder: owner.focusedSurface?.pwd)
                }
            }
            if overflow != .all, settings.isOn(.missionControl) { MissionControlButton() }
            ToolsButton(owner: owner, condensed: $condensed)
        }
    }
}

/// A small action icon in the row's hover chip, lit on hover.
private struct ChipIcon: View {
    let icon: PixelIcon
    @State private var hovering = false

    var body: some View {
        PixelIconView(icon: icon, color: hovering ? Extreme.gold : Extreme.muted, pixel: 1.1)
            .frame(width: 24, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Extreme.raised : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The pane's "Review N" chip when its agent's work is waiting, otherwise `diff`. Watches the
/// inbox itself, so the chip appears the moment a review is ready.
private struct ReviewOrDiffChip<Diff: View>: View {
    let surface: Ghostty.SurfaceView?
    @ViewBuilder let diff: () -> Diff
    @ObservedObject private var inbox = ReviewInbox.shared

    var body: some View {
        if let surface, inbox.item(for: surface)?.stage == .ready {
            ReviewPaneChip(surface: surface)
        } else {
            diff()
        }
    }
}

/// Opens this tab's code editor; while it's open, the same button closes it.
struct EditorHeaderButton: View {
    let owner: BaseTerminalController
    @ObservedObject private var panel = EditorPanel.shared

    var body: some View {
        let open = panel.isVisible(owner)
        ExtremeIconButton(icon: open ? .close : .code,
                          help: open ? "Close the code editor (⌃⌘E)" : "Open the code editor: watch the agent live (⌃⌘E)",
                          active: open) {
            panel.toggle(from: owner)
        }
        .disabled(HermesSessions.shared.isHermes(owner))
    }
}

/// Opens Mission Control (⌃⌘M); a dot shows when an agent is waiting.
struct MissionControlButton: View {
    var body: some View {
        ExtremeIconButton(icon: .grid, help: "Mission Control (⌃⌘M)", action: MissionControl.toggle)
    }
}

// MARK: - Icon with status

/// A pane's icon: the agent's logo on its brand-colored circle (or a neutral terminal
/// circle), with a status badge cut into the bottom-right corner. Proportions follow
/// Warp's `render_icon_with_status` (circle 76%, glyph 43%, badge 57% of the box).
struct VerticalTabAvatar: View {
    let agent: VerticalTabAgentKind?
    var mood: AgentMood = .idle
    let badge: VerticalTabBadge
    let palette: VerticalTabsPalette
    /// Extra highlight on the row behind the avatar, so the badge ring matches it.
    var rowHighlight: Double = 0
    var size: CGFloat = 22
    /// Running on a model on this Mac: a chip instead of the agent's critter.
    var local = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if local {
                    LocalModelSprite(pixel: size >= 22 ? 2 : 1.5)
                } else {
                    MoodSprite(kind: agent, mood: mood, pixel: size >= 22 ? 2 : 1.5)
                }
            }
                .frame(width: size, height: size)
                .background(Extreme.ink.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
            switch badge {
            case .none:
                EmptyView()
            case .working:
                PixelSpinner(color: Extreme.core, pixel: size >= 22 ? 3 : 2.5)
                    .padding(2)
                    .background(Extreme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Extreme.core.opacity(0.4), lineWidth: 1))
                    .offset(x: 6, y: 6)
            default:
                // Waiting on you blinks fast; finished or failed stays lit.
                let urgent = badge == .permission || badge == .input || badge == .bell
                PixelDot(color: badge.color(palette), blinking: urgent, size: size >= 22 ? 7 : 5,
                         interval: urgent ? 0.3 : 0.5)
                    .padding(2)
                    .background(Extreme.ink)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: size, height: size)
        .help(badge.helpText)
    }
}

/// An agent's logo in its brand color, or the terminal glyph, for the label line.
private struct VerticalTabKindLabel: View {
    let agent: VerticalTabAgentInfo?
    let palette: VerticalTabsPalette

    var body: some View {
        HStack(spacing: 5) {
            if let agent {
                // Shortened in the middle when long (a local model's "publisher/model:tag"),
                // so the row never grows wider than the sidebar.
                Text(agent.name)
                    .foregroundColor(agent.kind == .claude && agent.localModel == nil ? Extreme.claude : Extreme.text.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if agent.activity != .ready {
                    Text("·").fixedSize()
                    Text(agent.activity.label)
                        .foregroundColor(agent.activity.badge == .none
                            ? Extreme.muted : agent.activity.badge.color(palette))
                        .fixedSize()
                }
                if let detail = agent.detail {
                    Text("·").fixedSize()
                    Text(detail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            } else {
                Text("Terminal")
            }
        }
        .font(Extreme.font(10.5))
        .foregroundColor(Extreme.muted)
        .lineLimit(1)
    }
}

// MARK: - Tab group

private struct VerticalTabGroup: View {
    let controller: TerminalController
    let owner: TerminalController
    let index: Int
    let tabColor: TerminalTabColor
    let condensed: Bool
    let collapsed: Bool
    let palette: VerticalTabsPalette
    /// Inside a project bracket, which already provides the side margin.
    var inProject = false
    let onToggleCollapse: () -> Void

    @State private var snapshot: VerticalTabSnapshot = .empty
    @ObservedObject private var pins = VerticalTabsPins.shared

    private var isSelected: Bool { controller === owner }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(spacing: condensed ? 2 : 6) {
                    ForEach(snapshot.panes) { pane in
                        VerticalTabPaneRow(
                            pane: pane,
                            controller: controller,
                            tabTitle: snapshot.title,
                            tabColor: tabColor,
                            isSelected: isSelected && pane.isFocused,
                            condensed: condensed,
                            palette: palette)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .extremePanel(active: isSelected, fill: isSelected ? Extreme.panel : Color.clear)
        .overlay(alignment: .leading) { colorCard }
        .padding(.leading, inProject ? 0 : 8)
        .padding(.trailing, 8)
        .onAppear(perform: update)
        .onReceive(VerticalTabsTicker.shared.publisher) {
            // Every tab window carries a sidebar, but only the one on screen needs
            // to stay current; the others refresh when their tab is selected.
            guard owner.window?.occlusionState.contains(.visible) == true else { return }
            update()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if pins.isPinned(controller) {
                PixelIconView(icon: .pin, color: Extreme.bronze, pixel: 1)
            }
            Text(displayTitle)
                .font(Extreme.font(12, weight: .semibold))
                .foregroundColor(isSelected ? Extreme.gold : Extreme.text.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(snapshot.title)
            if snapshot.hasUnseen {
                PixelDot(color: Extreme.live, blinking: true, size: 6)
                    .help("Agent finished while you were away")
            }
            Spacer(minLength: 4)
            if snapshot.panes.count > 1 {
                Text("\(snapshot.panes.count) panes")
                    .font(Extreme.font(10))
                    .foregroundColor(Extreme.dim)
                    .fixedSize()
            }
            if index <= 9 {
                Text("⌘\(index)")
                    .font(Extreme.font(10, weight: .semibold))
                    .foregroundColor(Extreme.dim)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Extreme.raised))
                    .fixedSize()
            }
            Button(action: onToggleCollapse) {
                PixelIconView(icon: collapsed ? .chevronRight : .chevronDown, color: Extreme.muted, pixel: 1.25)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, collapsed ? 8 : 5)
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .contextMenu { contextMenu }
    }

    /// A custom tab title, or else the project folder the tab is in.
    private var displayTitle: String {
        if let override = controller.titleOverride, !override.isEmpty { return override }
        if let pwd = snapshot.representative?.pwd {
            return pwd == NSHomeDirectory() ? "Home" : ProjectPath.displayName(LocalhostProject(folder: pwd).root)
        }
        return Self.cleanTitle(snapshot.title)
    }

    /// A colored tab carries its color as a bar down its left edge.
    @ViewBuilder
    private var colorCard: some View {
        if let ns = tabColor.displayColor {
            Rectangle().fill(Color(nsColor: ns)).frame(width: 2).padding(.vertical, 1)
        }
    }

    /// Samples the tab and redraws only if something visible changed.
    private func update() {
        let next = VerticalTabSnapshot(controller: controller)
        if next != snapshot { snapshot = next }
    }

    private func select() {
        guard let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Agents prefix titles with activity glyphs (e.g. "✳ "); drop them for the header.
    static func cleanTitle(_ title: String) -> String {
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber && $0 != "~" && $0 != "/" }
        let result = String(trimmed).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Terminal" : result
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let project = VerticalTabsProjects.project(of: controller),
           UserDefaults.standard.verticalTabsUngroupedProjects.contains(project.id) {
            Button("Group \(ProjectPath.displayName(project.root)) Tabs Again") {
                VerticalTabsProjects.shared.regroup(project.id)
            }
            Divider()
        }
        Button("Rename Tab…") {
            select()
            controller.promptTabTitle()
        }
        if let window = controller.window as? TerminalWindow {
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.self) { color in
                    Button {
                        window.tabColor = color
                    } label: {
                        if tabColor == color {
                            Label(color.localizedName, systemImage: "checkmark")
                        } else {
                            Text(color.localizedName)
                        }
                    }
                }
            }
        }
        Divider()
        Button("Close Tab") { controller.closeTab(nil) }
    }
}

// MARK: - Pane row

private struct VerticalTabPaneRow: View {
    let pane: VerticalTabPaneSnapshot
    let controller: TerminalController
    let tabTitle: String
    let tabColor: TerminalTabColor
    let isSelected: Bool
    let condensed: Bool
    let palette: VerticalTabsPalette

    @ObservedObject private var git = VerticalTabsGit.shared
    @ObservedObject private var pulls = GitHubPulls.shared
    @ObservedObject private var settings = ExtremeSettings.shared
    @State private var trackedPwd: String?
    @State private var hovering = false
    @State private var frame: CGRect = .zero
    @EnvironmentObject private var overlay: VerticalTabsOverlayState

    private var gitInfo: VerticalTabsGitInfo? { git.info(for: pane.pwd) }

    var body: some View {
        Group {
            if condensed { condensedBody } else { expandedBody }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, condensed ? 5 : 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Extreme.raised : (hovering ? Extreme.raised.opacity(0.6) : Color.clear)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Extreme.gold.opacity(0.35) : Color.clear, lineWidth: 1))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Extreme.gold).frame(width: 3).padding(.vertical, 8).offset(x: -1)
                    .shadow(color: Extreme.gold.opacity(0.6), radius: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if pane.badge == .working {
                PixelActivityBar(color: Extreme.core).padding(.horizontal, 10).padding(.bottom, 2)
            } else if pane.badge == .permission || pane.badge == .input {
                Capsule().fill(Extreme.warn).frame(height: 2).padding(.horizontal, 10).padding(.bottom, 2)
                    .shadow(color: Extreme.warn.opacity(0.6), radius: 3)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .overlay(alignment: .topTrailing) {
            if hovering || overlay.menu?.pane.id == pane.id { hoverChip.padding(.top, 4).padding(.trailing, 4) }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frame = geometry.frame(in: .named(verticalTabsSpace)) }
                    .onChange(of: geometry.frame(in: .named(verticalTabsSpace))) { frame = $0 }
            })
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside {
                overlay.hoverBegan(.init(pane: pane, tabTitle: tabTitle, frame: frame))
            } else {
                overlay.hoverEnded(pane.id)
            }
        }
        .onTapGesture(perform: focus)
#if TELLURION_TEST_HOOKS
        .onReceive(NotificationCenter.default.publisher(for: VerticalTabsTestSupport.showOverlay)) { _ in
            guard isSelected else { return }
            if VerticalTabsTestSupport.overlayMode == "git", let pwd = pane.pwd, let root = git.root(for: pwd) {
                overlay.git = .init(controller: controller, pwd: pwd, root: root,
                                    anchor: CGRect(x: frame.minX + 30, y: frame.minY + 4, width: 0, height: 18))
            } else if VerticalTabsTestSupport.overlayMode == "menu" {
                overlay.menu = .init(
                    controller: controller, pane: pane, tabColor: tabColor,
                    anchor: CGRect(x: frame.maxX - 56, y: frame.minY + 4, width: 26, height: 26))
            } else {
                hovering = true
                overlay.hoverBegan(.init(pane: pane, tabTitle: tabTitle, frame: frame))
            }
        }
#endif
        .onAppear {
            trackedPwd = pane.pwd
            git.track(pane.pwd)
        }
        .onDisappear {
            git.untrack(trackedPwd)
            trackedPwd = nil
        }
        .onChange(of: pane.pwd) { newValue in
            git.untrack(trackedPwd)
            trackedPwd = newValue
            git.track(newValue)
        }
    }

    /// Warp's floating ⋮ / × controls shown on the hovered row.
    private var hoverChip: some View {
        HStack(spacing: 0) {
            chipButton(.code, help: "Open this folder in the code editor") {
                overlay.dismissAll()
                EditorPanel.shared.show(from: controller, folder: pane.pwd)
            }
            chipButton(.more, help: "More") {
                overlay.dismissAll()
                overlay.menu = .init(
                    controller: controller,
                    pane: pane,
                    tabColor: tabColor,
                    anchor: CGRect(x: frame.maxX - 56, y: frame.minY + 4, width: 26, height: 26))
            }
            chipButton(.close, help: controller.surfaceTree.count > 1 ? "Close Pane" : "Close Tab") {
                overlay.dismissAll()
                if controller.surfaceTree.count > 1, let surface = pane.surface {
                    controller.closeSurface(surface)
                } else {
                    controller.closeTab(nil)
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Extreme.ink))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Extreme.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
    }

    private func chipButton(_ icon: PixelIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChipIcon(icon: icon)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var avatar: some View {
        VerticalTabAvatar(
            agent: pane.agent?.kind,
            mood: AgentMood(pane.agent),
            badge: pane.badge,
            palette: palette,
            rowHighlight: isSelected ? 0.09 : (hovering ? 0.05 : 0),
            size: condensed ? 18 : 22,
            local: pane.agent?.localModel != nil)
    }

    private var expandedBody: some View {
        HStack(alignment: .top, spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                locationLine
                primaryLine
                HStack(spacing: 6) {
                    VerticalTabKindLabel(agent: pane.agent, palette: palette)
                    Spacer(minLength: 4)
                    // A pending review already counts the changes.
                    ReviewOrDiffChip(surface: pane.surface) { diffChip }
                }
                // Always there for an agent (dimmed while it's ready), so rows don't change
                // height between turns and push the list around.
                if let agent = pane.agent { detailLine(agent).opacity(agent.activity == .ready ? 0.55 : 1) }
                // Answer a permission prompt without switching to the pane.
                if pane.agent?.activity == .needsPermission, let surface = pane.surface,
                   let prompt = AgentPermissions.prompt(on: surface) {
                    AgentPermissionButtons(surface: surface, prompt: prompt, compact: true).padding(.top, 3)
                }
                // A review loop it's in, and messages waiting to be typed into it.
                if let surface = pane.surface { AgentMessagesLine(surface: surface, compact: true) }
            }
        }
    }

    private var condensedBody: some View {
        HStack(spacing: 8) {
            avatar
            primaryLine
            Spacer(minLength: 4)
            diffChip
        }
    }

    /// How long the agent has been at it, and the last thing it did: "2m · Edit: cart.py".
    private func detailLine(_ agent: VerticalTabAgentInfo) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
            Text(Self.elapsed(since: agent.since))
            if let action = agent.lastAction, !action.isEmpty {
                Text("·")
                Text(action)
                    .font(Extreme.mono(10))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(Extreme.font(10))
        .foregroundColor(Extreme.dim)
        .lineLimit(1)
    }

    static func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(1, seconds))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// "~/project • ⎇ branch"
    private var locationLine: some View {
        HStack(spacing: 5) {
            Text(pane.pwd.map(Self.abbreviate) ?? "~")
                .lineLimit(1)
                .truncationMode(.head)
            if let gitInfo {
                if settings.isOn(.git), let pwd = pane.pwd, let root = git.root(for: pwd) {
                    // Opens the Git panel.
                    Button {
                        overlay.dismissAll()
                        overlay.git = .init(controller: controller, pwd: pwd, root: root,
                                            anchor: CGRect(x: frame.minX + 30, y: frame.minY + 4, width: 0, height: 18))
                    } label: {
                        HStack(spacing: 5) {
                            branchLabel(gitInfo)
                            AheadBehindLabel(info: gitInfo)
                            if let pull = pulls.pull(root: root, branch: gitInfo.branch) {
                                PullRequestBadge(pull: pull)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Branches, stashes, commits and pull request")
                    .onAppear { pulls.fetch(root: root, branch: gitInfo.branch) }
                    .onChange(of: gitInfo.branch) { pulls.fetch(root: root, branch: $0) }
                } else {
                    branchLabel(gitInfo)
                }
            }
        }
        .font(Extreme.font(11.5))
        .foregroundColor(Extreme.text)
    }

    private func branchLabel(_ info: VerticalTabsGitInfo) -> some View {
        HStack(spacing: 5) {
            PixelIconView(icon: .branch, color: Extreme.bronze, pixel: 1)
            Text(info.branch)
                .foregroundColor(Extreme.bronze)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(1)
    }

    /// What the pane is doing: the agent's task, or the terminal's title/command.
    @ViewBuilder
    private var primaryLine: some View {
        if let agent = pane.agent {
            // A local model's pane is titled by Claude Code; say where it runs instead.
            Text(agent.task ?? (agent.localModel != nil ? "Running on this Mac" : VerticalTabGroup.cleanTitle(pane.title)))
                .font(Extreme.font(11))
                .foregroundColor(Extreme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(pane.title.isEmpty ? "Terminal" : pane.title)
                .font(Extreme.font(11))
                .foregroundColor(Extreme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var diffChip: some View {
        if let gitInfo, gitInfo.added > 0 || gitInfo.removed > 0 {
            HStack(spacing: 3) {
                if gitInfo.added > 0 { Text("+\(gitInfo.added)").foregroundColor(Extreme.live) }
                if gitInfo.removed > 0 { Text("-\(gitInfo.removed)").foregroundColor(Extreme.danger) }
            }
            .font(Extreme.mono(10.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Extreme.ink))
            .overlay(Capsule().strokeBorder(Extreme.line, lineWidth: 1))
            .fixedSize()
        }
    }

    private func focus() {
        guard let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = pane.surface { Ghostty.moveFocus(to: surface) }
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
#endif
