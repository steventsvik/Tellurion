#if os(macOS)
import AppKit

/// Brings back what was running when Tellurion restarts to install an update.
///
/// Right before the relaunch, every pane's Claude Code or Codex session and every localhost
/// server is written to a small file, and macOS is told to keep the windows for this one
/// quit (it restores tabs, splits and folders). After the relaunch, each agent is resumed in
/// its own pane (`claude --resume <id>`, `codex resume <id>`) and each server is started
/// again in its tab. A pane whose window didn't come back gets a new tab instead.
enum ResumeAfterUpdate {
    struct Entry: Codable {
        enum Kind: String, Codable { case claude, codex, localhost }
        let kind: Kind
        /// The pane it ran in; restored windows keep their panes' ids.
        let surface: String
        let cwd: String?
        /// The agent's session id, or the server's command.
        let value: String
        /// The Venice model a Codex pane ran on, so it comes back on Venice and not on another
        /// provider ("" if it was given on its command line).
        var venice: String?
        /// The model on this Mac a Codex pane ran on, and Codex's name for its host ("ollama"),
        /// so it comes back there and not on another provider.
        var localModel: String?
        var localProvider: String?
    }

    private struct Plan: Codable {
        let saved: Date
        let entries: [Entry]
    }

    private static var file: URL { AgentTools.root.appendingPathComponent("resume-after-update.json") }

    /// A plan older than this is from an update that never finished; it's ignored.
    private static let maxAge: TimeInterval = 30 * 60

    // MARK: Before the relaunch

    /// What's running now, pane by pane.
    static func entries() -> [Entry] {
        var result: [Entry] = []
        for controller in TerminalController.all {
            if TellurionSettings.isOn(.localhost), let session = LocalhostSessions.shared.session(for: controller),
               let surface = controller.surfaceTree.first {
                result.append(Entry(kind: .localhost, surface: surface.id.uuidString, cwd: session.cwd, value: session.command))
                continue
            }
            for surface in controller.surfaceTree {
                guard let info = VerticalTabsAgents.shared.info(for: surface), let id = session(for: info) else { continue }
                let kind: Entry.Kind = info.kind == .claude ? .claude : .codex
                result.append(Entry(kind: kind, surface: surface.id.uuidString, cwd: surface.pwd, value: id, venice: info.veniceModel,
                                    localModel: info.localCodex?.model, localProvider: info.localCodex?.provider))
            }
        }
        return result
    }

    /// The session id a Claude Code or Codex pane can be resumed with.
    static func session(for info: VerticalTabAgentInfo) -> String? {
        switch info.kind {
        case .claude:
            // Claude Code names its transcript after the session: <id>.jsonl.
            guard let path = info.transcriptPath else { return nil }
            let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return UUID(uuidString: id) != nil ? id : nil
        case .codex:
            guard let id = info.codexSessionID, UUID(uuidString: id) != nil else { return nil }
            return id
        default:
            return nil
        }
    }

    /// Called right before the app quits to relaunch into the update.
    static func prepare() {
        let entries = entries()
        if !entries.isEmpty {
            // Without it the agents aren't resumed after the relaunch, so a failure is logged.
            StoredFile.write(json: Plan(saved: Date(), entries: entries), to: file, what: "the agents to resume after the update",
                             log: StoredFile.logger("Update"), encoder: JSONEncoder())
        }
        // Keep the windows for this quit whatever the system setting says; the next launch
        // sets this back from `window-save-state`.
        UserDefaults.ghostty.setValue(true, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }

    // MARK: After the relaunch

    /// Called once at launch. Waits for restored windows, then resumes what ran in them.
    @MainActor
    static func resumeIfNeeded() {
        guard let data = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        guard let plan = try? JSONDecoder().decode(Plan.self, from: data),
              Date().timeIntervalSince(plan.saved) < maxAge, !plan.entries.isEmpty else { return }
        resume(plan.entries, attempt: 0)
    }

    private static func surface(_ id: String) -> (Ghostty.SurfaceView, TerminalController)? {
        for controller in TerminalController.all {
            for surface in controller.surfaceTree where surface.id.uuidString == id {
                return (surface, controller)
            }
        }
        return nil
    }

    @MainActor
    private static func resume(_ entries: [Entry], attempt: Int) {
        // Restored windows show up shortly after launch; give their shells a moment too.
        let pending = entries.filter { entry in
            guard let (surface, _) = surface(entry.surface) else { return true }
            return surface.surfaceModel == nil || surface.pwd == nil
        }
        if !pending.isEmpty && attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { resume(entries, attempt: attempt + 1) } }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated {
            var resumed = 0
            for entry in entries {
                if let (surface, controller) = surface(entry.surface) {
                    switch entry.kind {
                    case .localhost:
                        if let server = command(for: entry),
                           LocalhostSessions.shared.restart(command: server, in: entry.cwd ?? surface.pwd ?? NSHomeDirectory(),
                                                            tab: controller) { resumed += 1 }
                    case .claude, .codex:
                        // A leading space keeps it out of shell history.
                        if let model = surface.surfaceModel, let line = command(for: entry) {
                            Self.run(" \(line)", in: model)
                            resumed += 1
                        }
                    }
                } else {
                    // The window didn't come back: open the session in a new tab.
                    resumed += reopen(entry) ? 1 : 0
                }
            }
            DemoDirector.note("resume after update: \(resumed) of \(entries.count)")
        } }
    }

    /// Types a command at the shell prompt and presses Enter. Text arrives as a paste, so
    /// a newline inside it wouldn't run it.
    @MainActor
    static func run(_ command: String, in model: Ghostty.Surface) {
        model.sendText(command)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                model.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
                model.sendKeyEvent(.init(key: .enter, action: .release))
            }
        }
    }

    /// What an entry types (or, for a server, runs), or nil for one that isn't brought back.
    /// The plan is plain JSON that any program running as you can write, so an agent's
    /// session id must be a real one, and a server's command can't hide control characters.
    static func command(for entry: Entry) -> String? {
        switch entry.kind {
        case .claude:
            return AgentResume.command(.claude, session: entry.value)
        case .codex:
            if entry.localModel != nil || entry.localProvider != nil {
                return AgentResume.command(.codex, session: entry.value, on: .local(provider: entry.localProvider, model: entry.localModel))
            }
            return AgentResume.command(.codex, session: entry.value, on: entry.venice.map { AgentResume.Backend.venice(model: $0) } ?? .plain)
        case .localhost:
            return Ghostty.Shell.containsControlCharacters(entry.value) ? nil : entry.value
        }
    }

    private static func reopen(_ entry: Entry) -> Bool {
        let owner = TerminalController.all.first { $0.window?.isVisible == true } ?? TerminalController.all.first
        guard let line = command(for: entry) else { return false }
        if entry.kind == .localhost {
            return LocalhostSessions.shared.start(command: line, in: entry.cwd ?? NSHomeDirectory(), from: owner) != nil
        }
        guard let owner else { return false }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = entry.cwd
        config.initialInput = " \(line)\n"
        return TerminalController.newTab(owner.ghostty, from: owner.window, withBaseConfig: config) != nil
    }
}
#endif
