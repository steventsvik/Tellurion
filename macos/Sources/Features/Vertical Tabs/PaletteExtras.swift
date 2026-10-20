#if os(macOS)
import AppKit
import SwiftUI

/// Tellurion's additions to the command palette (⌘P / ⌘⇧P): agents waiting on the
/// user, new sessions, and the sidebar, editor and usage toggles. Tabs already appear as
/// Ghostty's own "Focus:" entries; `agentBadge` adds each one's agent status.
enum PaletteExtras {
    /// Agents waiting for permission or an answer, shown first so they're one Enter away.
    static func waitingOptions() -> [CommandOption] {
        TerminalWindows.all.flatMap { controller in
            controller.surfaceTree.compactMap { surface -> CommandOption? in
                guard let info = VerticalTabsAgents.shared.info(for: surface),
                      AgentAlerts.isWaiting(info.activity) else { return nil }
                let tab = TerminalWindows.title(of: surface, in: controller) ?? surface.pwd?.abbreviatedPath
                return CommandOption(
                    title: "Answer \(info.name): \(info.detail ?? info.activity.label)",
                    subtitle: [tab, info.task].compactMap { $0 }.joined(separator: " · "),
                    leadingIcon: info.activity == .needsPermission ? "hand.raised.fill" : "questionmark.bubble.fill",
                    leadingColor: info.kind.brandColor,
                    badge: info.activity.label,
                    emphasis: true
                ) {
                    NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
                }
            }
        }
    }

    /// New sessions and Tellurion's own view toggles. Sorted in with Ghostty's commands.
    static func commandOptions(for surfaceView: Ghostty.SurfaceView) -> [CommandOption] {
        var options: [CommandOption] = []
        if let owner = TerminalWindows.controller(of: surfaceView.window) {
            for kind in NewSessionKind.allCases {
                options.append(CommandOption(
                    title: "New Session: \(kind.title)",
                    description: owner is BoardController ? "Open a new tile running \(kind.title)" : "Open a new tab running \(kind.title)",
                    leadingIcon: kind == .terminal ? "terminal" : "plus.bubble",
                    leadingColor: kind.agent?.brandColor
                ) {
                    kind.open(from: owner)
                })
            }
            for kind in DockerSessionKind.allCases {
                options.append(CommandOption(
                    title: "New Isolated Session: \(kind.title)",
                    subtitle: "Docker · \(kind.detail)",
                    description: owner is BoardController ? "Open a new tile in a throwaway Docker container" : "Open a new tab in a throwaway Docker container",
                    leadingIcon: "shippingbox",
                    leadingColor: kind.agent?.brandColor
                ) {
                    DockerSessions.open(kind, from: owner)
                })
            }
            if surfaceView.pwd != nil && !HermesSessions.shared.isHermes(owner) {
                options.append(CommandOption(
                    title: "Hand Off…",
                    description: "Pass this pane's work to another agent, new or running, with its context",
                    leadingIcon: "arrow.triangle.branch"
                ) {
                    AgentHandoff.showWindow(from: surfaceView, in: owner)
                })
                if VerticalTabsAgents.shared.info(for: surfaceView) != nil {
                    options.append(CommandOption(
                        title: "Start a Review Loop…",
                        description: "Another agent reviews this one's work in rounds until it approves",
                        leadingIcon: "arrow.triangle.2.circlepath"
                    ) {
                        PipelineSetup.show(writer: surfaceView, in: owner)
                    })
                }
                for mode in AgentHandoff.Mode.allCases {
                    for target in AgentHandoff.targets {
                        options.append(CommandOption(
                            title: "Hand Off: \(AgentHandoff.title(mode, target))",
                            description: "Open \(target.displayName) beside this pane: \(mode.detail.lowercased())",
                            leadingIcon: "arrow.triangle.branch",
                            leadingColor: target.brandColor
                        ) {
                            AgentHandoff.handOff(from: surfaceView, in: owner, to: target, mode: mode)
                        })
                    }
                }
                if ExtremeSettings.isOn(.races) { options.append(CommandOption(
                    title: "Race Agents…",
                    description: "Give the same task to several agents in separate copies and keep the best",
                    symbols: ["⌃", "⌘", "R"],
                    leadingIcon: "flag.checkered.2.crossed"
                ) {
                    AgentRaces.showSetup(from: owner)
                }) }
            }
            if ExtremeSettings.isOn(.memory), let pwd = surfaceView.pwd {
                options.append(CommandOption(
                    title: "Project Memory",
                    description: "What Claude Code and Codex remember about this project, to read, edit or delete",
                    symbols: ["⌃", "⌘", "Y"],
                    leadingIcon: "brain"
                ) {
                    MemoryWindow.show(folder: pwd)
                })
            }
            if ExtremeSettings.isOn(.skills) {
                options.append(CommandOption(
                    title: "Skills",
                    description: "Every skill your agents have installed, updates, and what's trending on skills.sh",
                    symbols: ["⌃", "⌘", "U"],
                    leadingIcon: "puzzlepiece.extension"
                ) {
                    SkillsWindow.show(folder: surfaceView.pwd)
                })
            }
            if ExtremeSettings.isOn(.environment) {
                options.append(CommandOption(
                    title: "Environment",
                    description: "This folder's tool versions and variables, your containers, and local models",
                    symbols: ["⌃", "⌘", "N"],
                    leadingIcon: "shippingbox"
                ) {
                    EnvironmentWindow.show(folder: surfaceView.pwd)
                })
            }
            if !HermesSessions.shared.isHermes(owner), ExtremeSettings.isOn(.editor) {
                options.append(CommandOption(
                    title: "Toggle Code Editor",
                    description: "Show or hide this tab's code editor",
                    symbols: ["⌃", "⌘", "E"],
                    leadingIcon: "chevron.left.forwardslash.chevron.right"
                ) {
                    EditorPanel.shared.toggle(from: owner)
                })
            }
            if !HermesSessions.shared.isHermes(owner), ExtremeSettings.isOn(.visualFix) {
                options.append(CommandOption(
                    title: "Visual Fix",
                    description: "Point at anything in your running app and have the agent change it",
                    symbols: ["⌃", "⌘", "V"],
                    leadingIcon: "scope"
                ) {
                    VisualFixPanel.shared.toggle(owner)
                })
            }
        }
        options.append(CommandOption(
            title: "Toggle Aurora",
            description: "The light behind the terminal that follows your agents",
            leadingIcon: "sparkles"
        ) {
            let defaults = UserDefaults.standard
            defaults.set(!(defaults.object(forKey: AgentAurora.enabledKey) as? Bool ?? false), forKey: AgentAurora.enabledKey)
        })
        if ExtremeSettings.isOn(.background) { options.append(CommandOption(
            title: "Background Processes",
            description: "Dev servers, VMs, agents and more left running; close what's stale",
            symbols: ["⌃", "⌘", "K"],
            leadingIcon: "gauge.with.dots.needle.67percent"
        ) {
            HousekeepingWindow.show()
        }) }
        if ExtremeSettings.isOn(.missionControl) { options.append(CommandOption(
            title: "Mission Control",
            description: "Every agent at a glance",
            symbols: ["⌃", "⌘", "M"],
            leadingIcon: "square.grid.2x2"
        ) {
            MissionControl.show()
        }) }
        options.append(CommandOption(
            title: "Toggle Vertical Tabs",
            description: "Show or hide the sidebar",
            symbols: ["⌃", "⌘", "S"],
            leadingIcon: "sidebar.left"
        ) {
            VerticalTabsMenu.shared.toggle(nil)
        })
        options.append(CommandOption(
            title: "Layout…",
            description: "Arrange the window: drag the tabs, terminal, editor and panels into place",
            leadingIcon: PixelIcon.layout.symbol
        ) {
            LayoutWindow.show()
        })
        options.append(CommandOption(
            title: "Design…",
            description: "Terminal colors, chrome, font, window and logo: twenty templates or your own",
            leadingIcon: PixelIcon.design.symbol
        ) {
            DesignWindow.show()
        })
        options.append(CommandOption(
            title: "Tellurion Settings",
            description: "Features, animation and the sidebar",
            symbols: ["⌃", "⌘", ","],
            leadingIcon: "gearshape"
        ) {
            ExtremeSettingsWindow.show()
        })
        options.append(CommandOption(
            title: "Check Setup",
            description: "Whether agent status is set up and working, with fixes",
            leadingIcon: "stethoscope"
        ) {
            SetupCheckWindow.show()
        })
        options.append(CommandOption(
            title: "Keyboard Shortcuts",
            description: "Every ⌃⌘ shortcut (or hold ⌃⌘ for a moment)",
            symbols: ["⌃", "⌘", "/"],
            leadingIcon: "keyboard"
        ) {
            ShortcutSheet.shared.show(sticky: true)
        })
        let showsPercent = UserDefaults.standard.bool(forKey: UsagePanel.showsPercentKey)
        if ExtremeSettings.isOn(.usage) { options.append(CommandOption(
            title: showsPercent ? "Usage: Hide Percentages" : "Usage: Show Percentages",
            description: "Switch the sidebar's usage rings between graph and numbers",
            leadingIcon: "chart.pie"
        ) {
            UserDefaults.standard.set(!showsPercent, forKey: UsagePanel.showsPercentKey)
        }) }
        return options
    }

    /// The pane's agent and what it's doing, for its "Focus:" entry.
    static func agentBadge(for surface: Ghostty.SurfaceView) -> String? {
        guard let info = VerticalTabsAgents.shared.info(for: surface), info.kind != .hermes else { return nil }
        return info.activity == .ready ? info.name : "\(info.name) · \(info.activity.label)"
    }
}
#endif
