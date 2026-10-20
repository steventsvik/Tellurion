#if os(macOS)
import AppKit
import SwiftUI

/// Tellurion's own settings: which features are on, how much the chrome moves, the
/// sidebar, and agent setup. Ghostty's settings stay in its config file (⌘,).
enum ExtremeSettingsWindow {
    static let windowID = "extreme-settings"

    static func show() {
        AgentToolWindows.show(id: windowID, title: "Tellurion Settings", size: NSSize(width: 620, height: 720)) {
            ExtremeSettingsView()
        }
    }
}

private struct ExtremeSettingsView: View {
    @ObservedObject private var settings = ExtremeSettings.shared
    @ObservedObject private var setup = SetupChecks.shared
    @AppStorage(AgentAurora.enabledKey) private var aurora = false
    @AppStorage(VerticalTabs.widthKey) private var sidebarWidth: Double = VerticalTabs.defaultWidth
    @AppStorage(VerticalTabs.condensedKey) private var condensed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ExtremeWindowTitle(icon: nil, title: "Settings", subtitle: "Tellurion's features and look", sigil: true)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        ExtremeSectionLabel("Edition")
                        EditionPicker()
                        Text("Decides what a new window is. Switching to Board opens a board; your open windows stay.")
                            .font(Extreme.font(11)).foregroundColor(Extreme.muted)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ExtremeSectionLabel("Features")
                        FeaturePresetPicker()
                        FeatureToggleList()
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ExtremeSectionLabel("Look")
                        settingRow("Design", designDetail) {
                            Button("Open Design…") { DesignWindow.show() }
                        }
                        settingRow("Animation", "Status only keeps spinners and status lights, and stops the decoration") {
                            Picker("", selection: Binding(get: { settings.motion }, set: { settings.motion = $0 })) {
                                ForEach(ExtremeMotionLevel.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 200)
                            .accessibilityLabel("Animation")
                        }
                        settingRow("Aurora", "Light behind the terminal that follows the tab's agents") {
                            Toggle("", isOn: $aurora).toggleStyle(.switch).accessibilityLabel("Aurora")
                        }
                        settingRow("Compact rows", "One line per pane in the sidebar") {
                            Toggle("", isOn: $condensed).toggleStyle(.switch).accessibilityLabel("Compact rows")
                        }
                        settingRow("Sidebar width", "\(Int(sidebarWidth)) points; you can also drag its edge") {
                            Slider(value: $sidebarWidth, in: VerticalTabs.widthRange, step: 10).frame(width: 200)
                                .accessibilityLabel("Sidebar width")
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ExtremeSectionLabel("Agents")
                        settingRow(agentTitle, "Hooks that let Claude Code and Codex report their status") {
                            HStack(spacing: 8) {
                                Button("Check Setup…") { SetupCheckWindow.show() }
                                Button("Remove…") { HookRemoval.confirm() }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ExtremeSectionLabel("Shortcuts")
                        settingRow("Every shortcut", "Hold ⌃⌘ for a moment, or press ⌃⌘/") {
                            Button("Show") { ShortcutSheet.shared.show(sticky: true) }
                        }
                    }
                }
                .padding(16)
            }
        }
        .extremeWindow()
        .onAppear { setup.refreshIfStale(60) }
    }

    private var designDetail: String {
        let name = DesignStore.shared.design.name
        return DesignStore.shared.design.isStandardLook ? "Tellurion as shipped; templates, your own colors, font, window and logo"
            : "\(name): terminal colors, chrome, font, window and logo"
    }

    private var agentTitle: String {
        switch setup.worst {
        case .problem: return "Agent status: needs fixing"
        case .warning: return "Agent status: works, with warnings"
        default: return setup.checks.isEmpty ? "Agent status" : "Agent status: set up"
        }
    }

    private func settingRow<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.text)
                Text(detail).font(Extreme.font(11, weight: .regular)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(10)
        .extremePanel()
    }
}

/// Everything / Agent essentials / Just the sidebar.
struct FeaturePresetPicker: View {
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ExtremePreset.allCases) { preset in
                let selected = settings.preset == preset
                Button { settings.apply(preset) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.title).font(Extreme.font(12, weight: .semibold))
                            .foregroundColor(selected ? Extreme.gold : Extreme.text)
                        Text(preset.detail).font(Extreme.font(10.5, weight: .regular)).foregroundColor(Extreme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                    .padding(10)
                    .extremePanel(active: selected)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A switch per feature, with what it does and its shortcut.
struct FeatureToggleList: View {
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ExtremeFeature.allCases.enumerated()), id: \.element) { index, feature in
                if index > 0 { Rectangle().fill(Extreme.line.opacity(0.6)).frame(height: 1) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(feature.title).font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.text)
                            if let key = feature.shortcut {
                                Text("⌃⌘\(key)").font(Extreme.mono(10.5)).foregroundColor(Extreme.dim)
                            }
                        }
                        Text(feature.detail).font(Extreme.font(11, weight: .regular)).foregroundColor(Extreme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(get: { settings.isOn(feature) }, set: { settings.set(feature, on: $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(feature.title)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .extremePanel()
    }
}

/// Takes Tellurion's hooks back out of the agents' configs and ~/.zshrc.
enum HookRemoval {
    static func confirm() {
        let alert = NSAlert()
        alert.messageText = "Remove Tellurion's agent hooks?"
        alert.informativeText = """
        This takes Tellurion's entries out of ~/.claude/settings.json, ~/.codex/hooks.json, the \
        other agents' hook files and ~/.zshrc (each is backed up first). Your other hooks stay. The sidebar will no longer show \
        what agents are doing until you set it up again.
        """
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // Return cancels: removing isn't something to do by accident.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookInstaller.disconnect(.claude)
            try HookInstaller.disconnect(.codex)
            for agent in MoreAgent.allCases where HookInstaller.hasAnyHook(agent) {
                try HookInstaller.disconnect(agent)
            }
            try HookInstaller.removeShellIntegration()
        } catch {
            SetupChecks.shared.fixError = error.localizedDescription
        }
        SetupChecks.shared.refresh()
    }
}
#endif
