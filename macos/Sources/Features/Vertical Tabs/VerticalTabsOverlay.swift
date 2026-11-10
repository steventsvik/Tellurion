#if os(macOS)
import AppKit
import SwiftUI

/// Named coordinate space of `VerticalTabsLayout`; rows report their frames in it so
/// the hover card and menu can be placed beside them, over the terminal.
let verticalTabsSpace = "VerticalTabsLayout"

/// Floating UI anchored to sidebar rows: the hover card and the ⋮ menu.
final class VerticalTabsOverlayState: ObservableObject {
    struct Hover: Equatable {
        let pane: VerticalTabPaneSnapshot
        let tabTitle: String
        let frame: CGRect
    }

    struct Menu {
        weak var controller: TerminalController?
        let pane: VerticalTabPaneSnapshot
        let tabColor: TerminalTabColor
        let anchor: CGRect
    }

    /// The Git panel, opened from a row's branch.
    struct GitPanel {
        weak var controller: TerminalController?
        let pwd: String
        let root: String
        let anchor: CGRect
    }

    @Published private(set) var hover: Hover?
    @Published var menu: Menu?
    @Published var git: GitPanel?

    private var pendingHover: DispatchWorkItem?

    /// Shows the card after a short dwell, like Warp, so passing over rows doesn't flash it.
    func hoverBegan(_ hover: Hover) {
        pendingHover?.cancel()
        if self.hover != nil {
            // Already showing a card: follow the pointer immediately.
            self.hover = hover
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.hover = hover }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func hoverEnded(_ paneID: ObjectIdentifier) {
        pendingHover?.cancel()
        // Grace period so moving between rows doesn't close and reopen the card.
        let work = DispatchWorkItem { [weak self] in
            if self?.hover?.pane.id == paneID { self?.hover = nil }
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func dismissAll() {
        pendingHover?.cancel()
        hover = nil
        menu = nil
        git = nil
    }
}

/// Draws the overlays in the layout's coordinate space.
struct VerticalTabsOverlayLayer: View {
    @ObservedObject var state: VerticalTabsOverlayState
    let palette: VerticalTabsPalette
    let sidebarFrame: CGRect
    /// The hover card opens on the terminal's side of the sidebar.
    let sidebarOnLeft: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let panel = state.git, let controller = panel.controller {
                    Color.black.opacity(0.001)
                        .onTapGesture { state.git = nil }
                    GitPanelView(controller: controller, pwd: panel.pwd, root: panel.root) { state.git = nil }
                        .id(panel.root + panel.pwd)
                        .fixedSize()
                        .offset(
                            x: max(8, min(panel.anchor.minX, geometry.size.width - 370)),
                            y: max(8, min(panel.anchor.maxY + 4, geometry.size.height - 540)))
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                } else if let menu = state.menu, let controller = menu.controller {
                    // Clicking anywhere else closes the menu.
                    Color.black.opacity(0.001)
                        .onTapGesture { state.menu = nil }

                    VerticalTabsMenuPanel(
                        controller: controller,
                        pane: menu.pane,
                        tabColor: menu.tabColor,
                        palette: palette,
                        dismiss: { state.menu = nil })
                        .fixedSize()
                        .offset(
                            x: max(8, min(menu.anchor.minX, geometry.size.width - 300)),
                            y: max(8, min(menu.anchor.maxY + 4, geometry.size.height - 430)))
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
                } else if let hover = state.hover {
                    VerticalTabsHoverCard(hover: hover, palette: palette)
                        .frame(width: 320)
                        .offset(
                            x: sidebarOnLeft ? sidebarFrame.maxX + 10 : max(8, sidebarFrame.minX - 330),
                            y: max(8, min(hover.frame.minY, geometry.size.height - 220)))
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .move(edge: sidebarOnLeft ? .leading : .trailing)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.14), value: state.hover)
            .animation(.easeOut(duration: 0.12), value: state.menu != nil)
            .animation(.easeOut(duration: 0.12), value: state.git != nil)
        }
    }
}

// MARK: - Shared styling

private struct VerticalTabsPanelStyle: ViewModifier {
    let palette: VerticalTabsPalette

    func body(content: Content) -> some View {
        content
            .tellurionPanel(active: true, fill: Tellurion.ink)
            .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
    }
}

extension VerticalTabBadge {
    /// Label for the hover card's status pill.
    var pillLabel: String? {
        switch self {
        case .none: return nil
        case .working: return "In progress"
        case .done: return "Done"
        case .bell: return "Bell"
        case .input: return "Needs input"
        case .permission: return "Needs permission"
        case .error: return "Error"
        }
    }
}

// MARK: - Hover card

private struct VerticalTabsHoverCard: View {
    let hover: VerticalTabsOverlayState.Hover
    let palette: VerticalTabsPalette
    @ObservedObject private var git = VerticalTabsGit.shared

    private var pane: VerticalTabPaneSnapshot { hover.pane }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let label = pane.badge.pillLabel, let symbol = pane.badge.symbol {
                let color = pane.badge.color(palette)
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(Tellurion.font(11))
                    Text(label).font(Tellurion.font(12))
                }
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Rectangle().fill(color.opacity(0.16)))
            }

            if let pwd = pane.pwd {
                HStack(spacing: 6) {
                    Text(VerticalTabsHoverCard.abbreviate(pwd))
                        .foregroundColor(Tellurion.text)
                    if let info = git.info(for: pwd) {
                        Text("•").foregroundColor(Tellurion.muted)
                        Image(systemName: "arrow.triangle.branch").font(Tellurion.font(11))
                            .foregroundColor(Tellurion.muted)
                        Text(info.branch).foregroundColor(Tellurion.text)
                        if info.added > 0 { Text("+\(info.added)").foregroundColor(palette.green) }
                        if info.removed > 0 { Text("-\(info.removed)").foregroundColor(palette.red) }
                    }
                }
                .font(Tellurion.font(12.5))
                .lineLimit(1)
                .truncationMode(.head)
            }

            Text(pane.title.isEmpty ? hover.tabTitle : pane.title)
                .font(Tellurion.font(15))
                .foregroundColor(Tellurion.text.opacity(0.85))
                .lineLimit(2)

            if let agent = pane.agent {
                if let task = agent.task {
                    Text(task)
                        .font(Tellurion.font(12.5))
                        .foregroundColor(Tellurion.muted)
                        .lineLimit(3)
                }
                if let detail = agent.detail {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(Tellurion.font(10))
                        Text(detail).lineLimit(2)
                    }
                    .font(Tellurion.font(12))
                    .foregroundColor(agent.activity.badge.color(palette))
                }
                HStack(spacing: 6) {
                    VerticalTabAgentLogo(kind: agent.kind, tint: agent.kind.standaloneLogoColor)
                        .frame(width: 14, height: 14)
                    Text(agent.name)
                }
                .font(Tellurion.font(12))
                .foregroundColor(Tellurion.muted)
            } else {
                HStack(spacing: 6) {
                    Text(">_").font(Tellurion.font(11))
                    Text("Terminal")
                }
                .font(Tellurion.font(12))
                .foregroundColor(Tellurion.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(VerticalTabsPanelStyle(palette: palette))
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - ⋮ menu

private struct VerticalTabsMenuPanel: View {
    let controller: TerminalController
    let pane: VerticalTabPaneSnapshot
    let tabColor: TerminalTabColor
    let palette: VerticalTabsPalette
    let dismiss: () -> Void

    @ObservedObject private var pins = VerticalTabsPins.shared
    @ObservedObject private var editorPanel = EditorPanel.shared
    @ObservedObject private var checkpoints = TurnCheckpoints.shared

    var body: some View {
        let position = VerticalTabsActions.index(of: controller)
        let count = position?.count ?? 1
        let index = position?.index ?? 0

        VStack(alignment: .leading, spacing: 0) {
            item(pins.isPinned(controller) ? "Unpin tab" : "Pin tab") {
                pins.togglePin(controller)
            }
            separator
            item("Move tab to new window", enabled: count > 1) {
                VerticalTabsActions.moveToNewWindow(controller)
            }
            separator
            item("Copy pane title") {
                VerticalTabsActions.copy(pane.title)
            }
            item("Copy working directory", enabled: pane.pwd != nil) {
                VerticalTabsActions.copy(pane.pwd ?? "")
            }
            if editorPanel.isVisible(controller) {
                item("Close code editor") {
                    editorPanel.hide(returningFocusTo: controller)
                }
            } else if TellurionSettings.isOn(.editor) {
                item("Open folder in code editor", enabled: pane.pwd != nil) {
                    editorPanel.show(from: controller, folder: pane.pwd)
                }
            }
            if TellurionSettings.isOn(.memory) {
                item("Project memory…", enabled: pane.pwd != nil) {
                    MemoryWindow.show(folder: pane.pwd)
                }
            }
            if TellurionSettings.isOn(.checks) {
                item("Project check…", enabled: pane.pwd != nil) {
                    ProjectChecksWindow.show(folder: pane.pwd)
                }
            }
            separator
            ForEach(AgentHandoff.Mode.quick, id: \.self) { mode in
                ForEach(AgentHandoff.targets, id: \.self) { target in
                    item(AgentHandoff.title(mode, target), enabled: pane.pwd != nil && pane.surface != nil) {
                        guard let surface = pane.surface else { return }
                        AgentHandoff.handOff(from: surface, in: controller, to: target, mode: mode)
                    }
                }
            }
            item("Hand off…", enabled: pane.surface != nil) {
                guard let surface = pane.surface else { return }
                AgentHandoff.showWindow(from: surface, in: controller)
            }
            item("Start a review loop…", enabled: pane.surface != nil && pane.agent != nil) {
                guard let surface = pane.surface else { return }
                PipelineSetup.show(writer: surface, in: controller)
            }
            if TellurionSettings.isOn(.budgets), let surface = pane.surface, AgentBudgets.canMeasure(pane.agent) {
                item("Budget…") { AgentBudgetPopover.show(for: surface) }
            }
            if TellurionSettings.isOn(.races) {
                item("Race agents on this project…", enabled: pane.pwd != nil) {
                    VerticalTabsActions.select(controller)
                    AgentRaces.showSetup(from: controller)
                }
            }
            undoItems
            separator
            item("Rename tab") {
                VerticalTabsActions.select(controller)
                controller.promptTabTitle()
            }
            item("Move tab up", enabled: index > 0) {
                VerticalTabsActions.moveBy(controller, -1)
            }
            item("Move tab down", enabled: index < count - 1) {
                VerticalTabsActions.moveBy(controller, 1)
            }
            separator
            item("Close tab") {
                controller.closeTab(nil)
            }
            item("Close other tabs", enabled: count > 1) {
                VerticalTabsActions.closeOtherTabs(controller)
            }
            separator
            colorRow
        }
        .padding(.vertical, 6)
        .frame(width: 290)
        .modifier(VerticalTabsPanelStyle(palette: palette))
    }

    /// Undo the agent's last turn, an earlier one, or a restore (see TurnCheckpoints).
    @ViewBuilder
    private var undoItems: some View {
        if let surface = pane.surface, TellurionSettings.isOn(.undo) {
            let list = checkpoints.list(for: surface)
            if !list.isEmpty {
                separator
                let lastTurn = list.last { !$0.isRestorePoint }?.id
                ForEach(Array(list.suffix(4).reversed())) { checkpoint in
                    let prompt = TurnCheckpoints.short(checkpoint.title, 34)
                    let title = checkpoint.isRestorePoint ? "Undo restore"
                        : checkpoint.id == lastTurn ? "Undo last turn: “\(prompt)”"
                        : "Restore to before “\(prompt)”"
                    item(title) { TurnCheckpoints.shared.confirmAndRestore(checkpoint, on: surface) }
                }
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 12)
    }

    private func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        VerticalTabsMenuItem(title: title, enabled: enabled) {
            dismiss()
            // Run after the menu closes so prompts and window moves aren't under it.
            DispatchQueue.main.async(execute: action)
        }
    }

    private var colorRow: some View {
        HStack(spacing: 6) {
            ForEach(TerminalTabColor.allCases, id: \.self) { color in
                Button {
                    (controller.window as? TerminalWindow)?.tabColor = color
                    dismiss()
                } label: {
                    ZStack {
                        if let ns = color.displayColor {
                            Circle().fill(Color(nsColor: ns))
                        } else {
                            Circle().stroke(Tellurion.text.opacity(0.6), lineWidth: 1.5)
                            Rectangle().fill(Tellurion.text.opacity(0.6)).frame(width: 1.5).rotationEffect(.degrees(45))
                        }
                    }
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: tabColor == color ? 2 : 0))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.localizedName)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct VerticalTabsMenuItem: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tellurion.font(13))
                .foregroundColor(enabled ? .primary : Tellurion.muted.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Rectangle()
                        .fill(Color.white.opacity(hovering && enabled ? 0.1 : 0))
                        .padding(.horizontal, 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
#endif
