#if os(macOS)
import AppKit
import SwiftUI

/// The first-run window: what's installed, setting up agent status in one click, choosing
/// features, and a live test. Shown on first launch only when something needs setting up,
/// and any time from the Tellurion menu.
enum WelcomeWindow {
    static let windowID = "welcome"
    static let doneKey = "ExtremeWelcomeDone"

    static func show() {
        AgentToolWindows.show(id: windowID, title: "Welcome to Tellurion", size: NSSize(width: 640, height: 600)) {
            WelcomeView()
        }
    }

    /// At launch: checks the setup, then shows the welcome window if agent status isn't set
    /// up (and it hasn't been finished or skipped before). Already set up: never shown.
    static func showIfNeeded() {
        let forced = TestHooks.welcome
        let store = SetupChecks.shared
        // Test launches stay quiet unless they ask for it.
        let testing = TestHooks.isTestLaunch
        guard forced || (!UserDefaults.standard.bool(forKey: doneKey) && !testing) else {
            store.refresh()
            return
        }
        store.refresh {
            let needsSetup = store.checks.contains { $0.section == .agentStatus && $0.status == .problem }
            // A fresh install also picks between classic windows and boards.
            if needsSetup || forced || !ExtremeEdition.chosen {
                show()
            } else {
                UserDefaults.standard.set(true, forKey: doneKey)
            }
        }
    }

    static func finish() {
        if !ExtremeEdition.chosen { ExtremeEdition.set(ExtremeEdition.current) }
        UserDefaults.standard.set(true, forKey: doneKey)
        AgentToolWindows.close(id: windowID)
    }
}

private struct WelcomeView: View {
    @ObservedObject private var store = SetupChecks.shared
    @State private var page = 0
    @State private var setUpResult: [String]?
    @State private var connectClaude = !SetupChecks.skipped.contains(.claude)
    @State private var connectCodex = !SetupChecks.skipped.contains(.codex)
    @State private var addShell = true

    private let pages = ["Welcome", "Agent status", "Features", "Try it"]

    var body: some View {
        VStack(spacing: 0) {
            steps
                .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 14)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollView {
                Group {
                    switch page {
                    case 0: welcome
                    case 1: agentStatus
                    case 2: features
                    default: tryIt
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Rectangle().fill(Extreme.line).frame(height: 1)
            navigation.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .extremeWindow()
        .onAppear { store.refreshIfStale(30) }
    }

    // MARK: Chrome

    private var steps: some View {
        HStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(Extreme.font(10, weight: .bold))
                        .foregroundColor(index <= page ? Extreme.ink : Extreme.muted)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(index <= page ? Extreme.gold : Extreme.raised))
                    Text(title).font(Extreme.font(11.5, weight: index == page ? .semibold : .regular))
                        .foregroundColor(index == page ? Extreme.text : Extreme.muted)
                }
                if index < pages.count - 1 { Rectangle().fill(Extreme.line).frame(height: 1).frame(maxWidth: 30) }
            }
            Spacer(minLength: 0)
        }
    }

    private var navigation: some View {
        HStack {
            if page > 0 {
                Button("Back") { page -= 1 }
            }
            Spacer()
            if page < pages.count - 1 {
                Button("Skip setup") { WelcomeWindow.finish() }
                    .help("You can come back from Tellurion > Welcome… or Check Setup…")
                Button(page == 1 && setUpResult == nil && needsSetUp ? "Next without setting up" : "Next") { page += 1 }
                    .buttonStyle(ExtremeButtonStyle(prominent: !(page == 1 && needsSetUp && setUpResult == nil)))
            } else {
                Button("Done") { WelcomeWindow.finish() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 1. Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ExtremeSigil(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TELLURION").font(Extreme.font(18, weight: .semibold)).kerning(4.2).foregroundColor(Extreme.gold)
                    Text("A terminal built for watching coding agents work")
                        .font(Extreme.font(12.5, weight: .regular)).foregroundColor(Extreme.muted)
                }
            }
            Text("""
            Everything Ghostty does, plus a sidebar that shows what each agent is doing, an editor that \
            follows them, review and undo for their changes, and more. A minute of setup connects your agents.
            """)
            .font(Extreme.font(12.5, weight: .regular)).foregroundColor(Extreme.text)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ExtremeSectionLabel("How you see your terminals")
                EditionPicker()
                Text("You can switch any time in Settings.").font(Extreme.font(11)).foregroundColor(Extreme.dim)
            }
            VStack(alignment: .leading, spacing: 8) {
                ExtremeSectionLabel("Found on this Mac")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    tool("claude", "Claude Code")
                    tool("codex", "Codex")
                    tool("jq", "jq (needed by the hooks)")
                    tool("git", "git")
                    tool("gh", "GitHub CLI")
                    tool("docker", "Docker or Colima")
                }
                if store.checks.isEmpty { Text("Looking…").font(Extreme.font(11)).foregroundColor(Extreme.dim) }
            }
        }
    }

    private func tool(_ name: String, _ title: String) -> some View {
        let found = store.tools[name] != nil
        return HStack(spacing: 8) {
            Image(systemName: found ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(found ? Extreme.live : Extreme.dim)
            Text(title).font(Extreme.font(12)).foregroundColor(found ? Extreme.text : Extreme.muted)
        }
    }

    // MARK: 2. Agent status

    private var usesClaude: Bool { store.checks.contains { $0.id == "claude" } }
    private var usesCodex: Bool { store.checks.contains { $0.id == "codex" } }
    private var needsSetUp: Bool { store.checks.contains { $0.section == .agentStatus && $0.status >= .warning && $0.id != "events" } }

    private var agentStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agents tell Tellurion what they're doing through small hook scripts. Setting up:")
                .font(Extreme.font(12.5, weight: .regular)).foregroundColor(Extreme.text)
            VStack(alignment: .leading, spacing: 8) {
                plan(true, "Install the hooks", "Into ~/.ghostty-extreme, outside folders macOS protects", locked: true)
                if usesClaude {
                    plan($connectClaude, "Connect Claude Code", "Adds 9 hook entries to ~/.claude/settings.json. Your other hooks and settings stay"
                         + (store.tools["claude"] == nil ? ". Leave it off if you don't use Claude Code" : ""))
                }
                if usesCodex {
                    plan($connectCodex, "Connect Codex", "Adds 10 entries to ~/.codex/hooks.json. Codex asks you to approve them once"
                         + (store.tools["codex"] == nil ? ". Leave it off if you don't use Codex" : ""))
                }
                if HookInstaller.zshIsLoginShell {
                    plan($addShell, "Add to ~/.zshrc", "One line, so an agent's logo shows the moment it starts. Does nothing in other terminals")
                }
            }
            Text("Each file is backed up beside itself first. Settings > Remove… takes everything back out.")
                .font(Extreme.font(11, weight: .regular)).foregroundColor(Extreme.muted)
            if store.tools["jq"] == nil && !store.checks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Extreme.warn)
                    Text("The hooks need jq, which isn't installed.").font(Extreme.font(12)).foregroundColor(Extreme.text)
                    Spacer()
                    Button(store.tools["brew"] != nil ? "Install with Homebrew" : "Get jq") { store.apply(.installJq) }
                }
                .padding(10).extremePanel(fill: Extreme.raised)
            }
            HStack {
                Button(setUpResult == nil ? "Set up" : "Set up again") { setUp() }
                    .buttonStyle(ExtremeButtonStyle(prominent: setUpResult == nil))
                if let setUpResult {
                    Label(setUpResult.isEmpty ? "Already set up" : "Done: \(setUpResult.joined(separator: ", "))",
                          systemImage: "checkmark.circle.fill")
                        .font(Extreme.font(11.5)).foregroundColor(Extreme.live)
                        .lineLimit(2)
                }
            }
            if let error = store.fixError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(Extreme.font(11.5)).foregroundColor(Extreme.danger)
            }
            let remaining = store.checks.filter { $0.section == .agentStatus && $0.status >= .warning && $0.id != "events" }
            if setUpResult != nil && !remaining.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ExtremeSectionLabel("Still to do")
                    ForEach(remaining) { SetupCheckRow(check: $0, compact: true) }
                }
            }
        }
    }

    private func plan(_ on: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(title)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.text)
                Text(detail).font(Extreme.font(11, weight: .regular)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10).extremePanel()
    }

    private func plan(_ on: Bool, _ title: String, _ detail: String, locked: Bool) -> some View {
        plan(.constant(on), title, detail).disabled(locked)
    }

    private func setUp() {
        store.fixError = nil
        // An agent left unchecked isn't used here: stop asking about it (until it's checked again).
        for (agent, found, connect) in [(HookConfig.Agent.claude, usesClaude, connectClaude), (.codex, usesCodex, connectCodex)]
        where found && SetupChecks.skipped.contains(agent) == connect {
            store.setSkipped(agent, !connect)
        }
        do {
            setUpResult = try HookInstaller.setUp(claude: usesClaude && connectClaude, codex: usesCodex && connectCodex,
                                                  shell: addShell)
        } catch {
            store.fixError = error.localizedDescription
            setUpResult = []
        }
        store.refresh()
    }

    // MARK: 3. Features

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything is on. Turn off what you don't want; a feature that's off has no shortcut, button or background work. You can change this any time in Settings.")
                .font(Extreme.font(12.5, weight: .regular)).foregroundColor(Extreme.text)
                .fixedSize(horizontal: false, vertical: true)
            FeaturePresetPicker()
            FeatureToggleList()
        }
    }

    // MARK: 4. Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send a test event through the real hooks. A new tab runs tellurion doctor, which checks everything and reports to the sidebar.")
                .font(Extreme.font(12.5, weight: .regular)).foregroundColor(Extreme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Run live test") { store.apply(.liveTest) }
                    .buttonStyle(ExtremeButtonStyle(prominent: store.liveCheckAt == nil))
                if store.liveCheckAt != nil {
                    Label("It works: the test event arrived", systemImage: "checkmark.circle.fill")
                        .font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.live)
                }
            }
            if let notifications = store.checks.first(where: { $0.id == "notifications" }), notifications.status != .ok {
                SetupCheckRow(check: notifications, compact: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("Good to know")
                hint("⌃⌘ held for a moment", "shows every shortcut")
                hint("⌘P", "jumps to any tab, agent or command")
                hint("+ New in the sidebar", "starts Claude Code, Codex and other sessions")
                hint("Tellurion menu", "Settings, Check Setup and this window")
                hint("New tabs", "pick up the ~/.zshrc change; tabs that were already open don't")
            }
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(Extreme.font(11.5, weight: .semibold)).foregroundColor(Extreme.gold)
            Text(text).font(Extreme.font(11.5, weight: .regular)).foregroundColor(Extreme.muted)
        }
    }
}
#endif
