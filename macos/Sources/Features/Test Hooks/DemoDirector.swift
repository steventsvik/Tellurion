#if os(macOS)
import AppKit

#if TELLURION_TEST_HOOKS
/// Test-only: `GHOSTTY_EXTREME_DEMO=<file>` plays a timed script against the first window so
/// a demo can be screen-recorded without UI scripting. Each line is
/// `<seconds since launch> <action> [args]`; `#` starts a comment. Tabs are 1-based.
///
///     frame <x> <y> <w> <h>   main window frame in points, y from the top of the screen
///     frame visible           main window fills the screen above the Dock
///     tab <n>                 select tab n
///     type <n> <text>         type text plus Enter into tab n
///     send <n> <text>         type text into tab n
///     key <n> enter|up|down   press a key in tab n
///     editor <n> / editorhide <n>
///     palette <n>             toggle the command palette in tab n
///     mission | localhost | review | activity
///     close <window id>       close a tool window (mission-control, activity, ...)
///     race <n> <task>         race one Claude and one Codex in tab n's folder
///     mark <label>            append "<label> <unix time>" to GHOSTTY_EXTREME_DEMO_MARKS
///     editorat <n> <folder>   open tab n's code editor on a folder
///     js <n> <script>         run JavaScript in tab n's code editor
///     background              open the Background window
///     visualfix <n> [url]     open Visual Fix from tab n, optionally on a URL
///     answer <n> allow|deny   answer tab n's permission prompt, as its sidebar buttons do
///     restorelast <n>         ask to undo tab n's last agent turn
@MainActor
enum DemoDirector {
    private static var started = false

    static func startIfRequested(from controller: TerminalController) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let path = env["GHOSTTY_EXTREME_DEMO"],
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        started = true
        let marks = env["GHOSTTY_EXTREME_DEMO_MARKS"]
        for raw in script.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let time = Double(parts[0]) else { continue }
            let command = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                MainActor.assumeIsolated { run(command, in: controller, marks: marks) }
            }
        }
    }

    /// Appends a line to the test log (`GHOSTTY_EXTREME_TEST_LOG`), where a test run reads it.
    nonisolated static func note(_ line: @autoclosure () -> String) {
        guard TestHooks.log != nil else { return }
        TestHooks.note("[demo] \(line())")
    }

    private static func tab(_ n: String, of controller: TerminalController) -> TerminalController? {
        guard let window = controller.window, let index = Int(n) else { return nil }
        let windows = window.tabGroup?.windows ?? [window]
        guard index >= 1, index <= windows.count else { return nil }
        return windows[index - 1].windowController as? TerminalController
    }

    private static func run(_ command: String, in controller: TerminalController, marks: String?) {
        let words = command.split(separator: " ", maxSplits: 2).map(String.init)
        let action = words[0]
        let arg = words.count > 1 ? words[1] : ""
        let rest = words.count > 2 ? words[2] : ""
        let target = tab(arg, of: controller)

        // Keep the demo in front even if something else took focus.
        NSApp.activate(ignoringOtherApps: true)

        switch action {
        case "frame" where arg == "visible":
            if let screen = controller.window?.screen ?? NSScreen.main {
                controller.window?.setFrame(screen.visibleFrame, display: true)
            }
        case "frame":
            let n = command.split(separator: " ").dropFirst().compactMap { Double($0) }
            guard n.count == 4, let screen = controller.window?.screen ?? NSScreen.main else { return }
            let top = screen.frame.maxY
            controller.window?.setFrame(NSRect(x: n[0], y: top - n[1] - n[3], width: n[2], height: n[3]), display: true)
        case "tab":
            if let target { VerticalTabsActions.select(target) }
        case "type", "send":
            guard let model = target?.focusedSurface?.surfaceModel else { return }
            model.sendText(rest)
            if action == "type" {
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
        case "key":
            guard let model = target?.focusedSurface?.surfaceModel else { return }
            let key: Ghostty.Input.Key = rest == "up" ? .arrowUp : rest == "down" ? .arrowDown : .enter
            model.sendKeyEvent(.init(key: key, action: .press, text: key == .enter ? "\r" : nil))
            model.sendKeyEvent(.init(key: key, action: .release))
        case "editor":
            EditorPanel.shared.show(from: target)
        case "editorat":
            EditorPanel.shared.show(from: target, folder: rest)
        case "js":
            guard let target else { return }
            EditorPanel.shared.session(for: target).webView.evaluateJavaScript(rest)
        case "background":
            HousekeepingWindow.show()
        case "answer":
            if let surface = target?.focusedSurface {
                let sent = AgentPermissions.answer(rest == "deny" ? .deny : .allow, on: surface)
                note("answer \(rest) sent=\(sent)")
            }
        case "restorelast":
            if let surface = target?.focusedSurface, let turn = TurnCheckpoints.shared.lastTurn(for: surface) {
                note("restorelast: checkpoint “\(turn.title)” tree \(turn.tree.prefix(8))")
                TurnCheckpoints.shared.confirmAndRestore(turn, on: surface)
            } else {
                note("restorelast: no checkpoint (target \(target == nil ? "missing" : "ok"))")
            }
        case "visualfix":
            VisualFixPanel.shared.show(from: target, url: rest.isEmpty ? nil : URL(string: rest))
        case "editorhide":
            EditorPanel.shared.hide(returningFocusTo: target)
        case "palette":
            target?.toggleCommandPalette(nil)
        case "mission":
            MissionControl.show()
        case "localhost":
            LocalhostManager.show()
        case "review":
            ReviewInbox.show()
        case "activity":
            ActivityDashboard.toggle()
        case "close":
            AgentToolWindows.close(id: arg)
        case "race":
            guard let target, let folder = target.focusedSurface?.pwd else { return }
            AgentRaces.shared.start(task: rest, folder: folder, counts: [.claude: 1, .codex: 1],
                                    includeChanges: true, from: target) { result in
                if case .success(let race) = result { AgentRaces.show(race, from: target) }
            }
        case "mark":
            guard let marks else { return }
            let old = (try? String(contentsOfFile: marks, encoding: .utf8)) ?? ""
            let line = "\(arg) \(Date().timeIntervalSince1970)\n"
            try? (old + line).write(toFile: marks, atomically: true, encoding: .utf8)
        default:
            break
        }
    }
}
#else
/// Release builds have no demo director. Its notes, left at points a recording may want to
/// line up with, are dropped without building the message.
enum DemoDirector {
    static func note(_ line: @autoclosure () -> String) {}
}
#endif
#endif
