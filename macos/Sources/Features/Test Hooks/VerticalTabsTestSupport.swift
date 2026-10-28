#if os(macOS)
import AppKit
import SwiftUI

#if TELLURION_TEST_HOOKS
/// Test-only: `GHOSTTY_EXTREME_TEST_TABS=N` (set by a test launch, never in normal use)
/// opens N tabs at startup so the sidebar can be exercised without UI scripting.
enum VerticalTabsTestSupport {
    private static var didOpen = false

    /// `GHOSTTY_EXTREME_TEST_OVERLAY=hover|menu|git|tools`: the selected row opens its hover
    /// card, ⋮ menu or Git panel, or the header opens Tools, shortly after launch.
    static let overlayMode = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_OVERLAY"]
    static let showOverlay = Notification.Name("com.steventsvik.ghostty-extreme.testShowOverlay")

    static func openTestTabsIfRequested(from controller: TerminalController) {
        guard !didOpen else { return }
        didOpen = true
        MainActor.assumeIsolated { DemoDirector.startIfRequested(from: controller) }
        if overlayMode != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                NotificationCenter.default.post(name: showOverlay, object: nil)
            }
        }
        if let name = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_COLOR"],
           let color = TerminalTabColor.allCases.first(where: { $0.localizedName.lowercased() == name }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { (controller.window as? TerminalWindow)?.tabColor = color }
        }
        if ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_SESSION"] == "hermes" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NewSessionKind.hermes.open(from: controller) }
        }
        // `GHOSTTY_EXTREME_TEST_SESSION=docker:<kind>`: open an isolated Docker session.
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_SESSION"], value.hasPrefix("docker:"),
           let kind = DockerSessionKind(rawValue: String(value.dropFirst("docker:".count))) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { DockerSessions.open(kind, from: controller) }
        }
        // `GHOSTTY_EXTREME_TEST_EDITOR_DELAY`: seconds before opening it (default 1.5).
        if let file = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_EDITOR"] {
            let delay = Double(ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_EDITOR_DELAY"] ?? "") ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // A folder (trailing slash) opens the editor the way a user does, with no file.
                if file.hasSuffix("/") {
                    EditorPanel.shared.show(from: controller)
                } else {
                    EditorPanel.shared.show(from: controller, folder: (file as NSString).deletingLastPathComponent)
                    EditorPanel.shared.session(for: controller).webView.openFile(file, line: 20)
                }
                // `GHOSTTY_EXTREME_TEST_EDITOR_JS`: script run in the editor once it's loaded.
                if let script = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_EDITOR_JS"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        EditorPanel.shared.session(for: controller).webView.evaluateJavaScript(script)
                    }
                }
            }
        }
        // `GHOSTTY_EXTREME_TEST_BACKGROUND=<seconds>`: open the Background window then.
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_BACKGROUND"], let delay = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { HousekeepingWindow.show() }
        }
        // `GHOSTTY_EXTREME_TEST_VISUAL=<seconds>`: open Visual Fix on the best running app then.
        if let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_VISUAL"], let delay = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { VisualFixPanel.shared.show(from: controller) }
        }
        // `GHOSTTY_EXTREME_TEST_PALETTE=1`: open the command palette in the visible tab after 11s.
        if ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_PALETTE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
                let window = controller.window?.tabGroup?.selectedWindow ?? controller.window
                (window?.windowController as? BaseTerminalController)?.toggleCommandPalette(nil)
            }
        }
        let env = ProcessInfo.processInfo.environment
        // `GHOSTTY_EXTREME_TEST_TYPE=<command>`: types it (plus Enter) into the first tab after 3s.
        if let command = env["GHOSTTY_EXTREME_TEST_TYPE"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let model = controller.focusedSurface?.surfaceModel else { return }
                model.sendText(command)
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
        }
        // `GHOSTTY_EXTREME_TEST_REVIEW=comment,send,undo,commit`: acts on the first review item,
        // one step every 3s starting at 24s, logging to `GHOSTTY_EXTREME_TEST_LOG`.
        if let steps = env["GHOSTTY_EXTREME_TEST_REVIEW"] {
            let log: (String) -> Void = { TestHooks.note($0) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 24_000_000_000)
                let inbox = ReviewInbox.shared
                for step in steps.split(separator: ",") {
                    guard let item = inbox.items.first else { log("\(step): no review item"); break }
                    switch step {
                    case "comment":
                        if let file = item.files.first, let line = file.hunks.first?.lines.first(where: { $0.kind == .added }) {
                            inbox.addComment("Use Decimal for money; floats round badly.", on: line, file: file, in: item)
                        }
                        log("comment: \(inbox.items.first?.comments.count ?? 0) comments")
                    case "send":
                        log("send: \(inbox.sendFeedback(item))")
                    case "undo":
                        if let file = item.files.first(where: { $0.status == .added }) { inbox.undo(file, in: item) }
                        log("undo: requested")
                    case "commit":
                        inbox.commit(item, message: "Add discount codes") { error in log("commit: \(error ?? "ok")") }
                    default:
                        break
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                log("files now: \(inbox.items.first?.files.map(\.path) ?? [])")
            }
        }
        // `GHOSTTY_EXTREME_TEST_OPEN=localhost,review,activity,blocks,setup,welcome,settings,shortcuts,update,localhost-session,skills`: open those after
        // `GHOSTTY_EXTREME_TEST_OPEN_DELAY` seconds (default 10).
        if let windows = env["GHOSTTY_EXTREME_TEST_OPEN"] {
            let delay = Double(env["GHOSTTY_EXTREME_TEST_OPEN_DELAY"] ?? "") ?? 10
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for name in windows.split(separator: ",") {
                    switch name {
                    case "localhost": LocalhostManager.show()
                    case "review": ReviewInbox.show()
                    case "activity": ActivityDashboard.toggle()
                    case "blocks": CommandBlocksPanel.shared.show(controller)
                    case "setup": SetupCheckWindow.show()
                    case "welcome": WelcomeWindow.show()
                    case "settings": ExtremeSettingsWindow.show()
                    case "update": UpdateWindow.show()
                    case "skills": SkillsWindow.show(folder: env["GHOSTTY_EXTREME_TEST_SKILLS_PROJECT"])
                    case "environment": EnvironmentWindow.show(folder: env["GHOSTTY_EXTREME_TEST_SKILLS_PROJECT"])
                    case "localhost-session":
                        // A throwaway server in a temporary folder, for the sidebar's localhost cards.
                        _ = LocalhostSessions.shared.start(command: "python3 -m http.server 8791 --bind 127.0.0.1",
                                                           in: NSTemporaryDirectory(), from: controller, focus: false)
                    case "shortcuts":
                        ShortcutSheet.shared.show(sticky: true)
                        for entry in ShortcutSheet.collect() {
                            TestHooks.note("\(entry.id): " + entry.shortcuts.map { "\($0.keys) \($0.title)" }.joined(separator: ", "))
                        }
                    default: break
                    }
                }
            }
        }
        // `GHOSTTY_EXTREME_TEST_SETUP=1` (with `GHOSTTY_EXTREME_TEST_HOME=<scratch folder>`): after 4s,
        // do what the welcome window's "Set up" does, logging the result.
        if env["GHOSTTY_EXTREME_TEST_SETUP"] == "1", env["GHOSTTY_EXTREME_TEST_HOME"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let result: String
                do { result = try HookInstaller.setUp(claude: true, codex: true, shell: true).joined(separator: ", ") } catch { result = "error: \(error)" }
                TestHooks.note("setup: " + result)
                SetupChecks.shared.refresh()
            }
        }
        // `GHOSTTY_EXTREME_TEST_STOP_PORT=<port>`: after 12s, Stop whatever listens there (as the
        // Ports section's Stop does), logging what was listening before and after.
        if let value = env["GHOSTTY_EXTREME_TEST_STOP_PORT"], let port = Int(value) {
            let log: (String) -> Void = { TestHooks.note($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                let monitor = PortsMonitor.shared
                log("ports: " + monitor.entries.map { ":\($0.port) \($0.kind) \($0.title) [\($0.command)]" }.joined(separator: ", "))
                log("conflict: \(monitor.conflict.map { String($0.port) } ?? "none")")
                guard let entry = monitor.entries.first(where: { $0.port == port }) else { log("stop: nothing on \(port)"); return }
                monitor.stop(entry)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    log("after stop: \(port) " + (monitor.entries.contains { $0.port == port } ? "still listening" : "free")
                        + ", pid \(entry.pid) " + (ProcessProbe.isAlive(entry.pid) ? "alive" : "gone"))
                }
            }
        }
        // `GHOSTTY_EXTREME_TEST_DUMP_SCREEN=<seconds>`: write the focused pane's screen to
        // `<GHOSTTY_EXTREME_TEST_LOG>.screen` then (to see exactly what an agent's idle screen looks like).
        if let value = env["GHOSTTY_EXTREME_TEST_DUMP_SCREEN"], let delay = Double(value),
           let path = env["GHOSTTY_EXTREME_TEST_LOG"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let surface = controller.focusedSurface else { return }
                let info = VerticalTabsAgents.shared.info(for: surface)
                let screen = surface.cachedVisibleContents.get()
                // Its own file: other test logging rewrites the log as it goes.
                try? ("agent: \(info.map { "\($0.kind) \($0.activity)" } ?? "none")\n----\n\(screen)\n----\n")
                    .write(toFile: path + ".screen", atomically: true, encoding: .utf8)
            }
        }
        // `GHOSTTY_EXTREME_TEST_PRESENT=1`: after 8s, present the first tab's pane the way
        // Mission Control's Open does (while a later tab is selected).
        if env["GHOSTTY_EXTREME_TEST_PRESENT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard let surface = controller.surfaceTree.first else { return }
                NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
            }
        }
        // `GHOSTTY_EXTREME_TEST_MISSION=1`: open Mission Control after 12s.
        if env["GHOSTTY_EXTREME_TEST_MISSION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { MissionControl.show() }
        }
        // `GHOSTTY_EXTREME_TEST_HANDOFF=review|continue`: hand the first pane off to Claude Code after 6s.
        if let mode = env["GHOSTTY_EXTREME_TEST_HANDOFF"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard let surface = controller.focusedSurface else { return }
                AgentHandoff.handOff(from: surface, in: controller, to: .claude, mode: mode == "continue" ? .continue : .review)
            }
        }
        // `GHOSTTY_EXTREME_TEST_RACE=<task>`: race one Claude and one Codex after 4s; with
        // `GHOSTTY_EXTREME_TEST_RACE_KEEP=1`, keep claude-1's changes at 30s and clean up at 36s,
        // logging to `GHOSTTY_EXTREME_TEST_LOG`.
        if let task = env["GHOSTTY_EXTREME_TEST_RACE"], let folder = env["GHOSTTY_EXTREME_TEST_RACE_FOLDER"] {
            let log: (String) -> Void = { TestHooks.note($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                AgentRaces.shared.start(task: task, folder: folder, counts: [.claude: 1, .codex: 1],
                                        includeChanges: true, from: controller) { result in
                    switch result {
                    case .failure(let error): log("race failed: \(error.message)")
                    case .success(let race):
                        log("race \(race.id) " + race.contestants.map { "\($0.id)=\($0.worktree)" }.joined(separator: " "))
                        AgentRaces.show(race, from: controller)
                        guard env["GHOSTTY_EXTREME_TEST_RACE_KEEP"] == "1" else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 26) {
                            AgentRaces.shared.keep(race.contestants[0], of: race) { error in
                                log("keep: \(error ?? "ok")")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                    AgentRaces.shared.cleanUp(race)
                                    log("cleaned up")
                                }
                            }
                        }
                    }
                }
            }
        }
        // Report which window is the visible tab so a test can capture that one.
        if let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_WINDOW_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let window = controller.window?.tabGroup?.selectedWindow ?? controller.window
                try? String(window?.windowNumber ?? 0).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // `GHOSTTY_EXTREME_TEST_RESELECT=1`: switch back to the first tab after 9s and
        // report its window in <window file>.2.
        if ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_RESELECT"] == "1",
           let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_WINDOW_FILE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                VerticalTabsActions.select(controller)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    try? String(controller.window?.windowNumber ?? 0).write(toFile: path + ".2", atomically: true, encoding: .utf8)
                }
            }
        }
        guard let value = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_TABS"],
              let count = Int(value), count > 1 else { return }
        for i in 1..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(i)) {
                controller.newTab(nil)
            }
        }
    }
}
#else
/// Release builds have no test launches; see `TestHooks`.
enum VerticalTabsTestSupport {
    static func openTestTabsIfRequested(from controller: TerminalController) {}
}
#endif
#endif
