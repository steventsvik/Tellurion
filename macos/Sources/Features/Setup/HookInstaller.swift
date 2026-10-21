#if os(macOS)
import AppKit

/// Installs the agent hooks the app carries (in `Contents/Resources/agent-hooks`) and
/// connects them to Claude Code, Codex and zsh. Every config file is backed up next to
/// itself before it's changed, and only our own entries are ever added or removed.
enum HookInstaller {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The home folder. Test-only: `GHOSTTY_EXTREME_TEST_HOME` points the installer and the
    /// setup check at a scratch folder instead of the user's real configs.
    static let home = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_HOME"] ?? NSHomeDirectory()
    static var hooksFolder: URL { URL(fileURLWithPath: HookConfig.hooksFolder(home: home), isDirectory: true) }
    static var binFolder: URL { URL(fileURLWithPath: home + "/.ghostty-extreme/bin", isDirectory: true) }
    static var claudeSettings: URL { URL(fileURLWithPath: home + "/.claude/settings.json") }
    static var codexHooks: URL { URL(fileURLWithPath: home + "/.codex/hooks.json") }
    static var zshrc: URL { URL(fileURLWithPath: home + "/.zshrc") }

    /// The hooks inside this app.
    static var bundled: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("agent-hooks", isDirectory: true) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// File name → where it's installed.
    private static var installedFiles: [(String, URL)] {
        [
            ("agent-hook.sh", hooksFolder),
            ("ghostty-extreme.zsh", hooksFolder),
            ("codex-hook.py", hooksFolder),
            ("memory_context.py", hooksFolder),
            ("agent-event.py", hooksFolder),
            ("opencode-plugin.js", hooksFolder),
            ("amp-plugin.ts", hooksFolder),
            ("local-chat.py", hooksFolder),
            ("localhost", binFolder),
            ("localhost-run", binFolder),
            ("tellurion", binFolder),
            ("ghostty-extreme", binFolder),
        ]
    }

    private static let executables: Set<String> = ["agent-hook.sh", "agent-event.py", "local-chat.py", "localhost", "localhost-run", "tellurion", "ghostty-extreme"]

    // MARK: Hook files

    enum FilesState: Equatable {
        case current
        case missing
        /// Installed, but different from the ones in this app (installed by another build).
        case outdated
        /// This app doesn't carry the hooks (a build without them).
        case unavailable
    }

    static func filesState() -> FilesState {
        guard let bundled else { return .unavailable }
        var anyInstalled = false
        var anyDifferent = false
        for (name, folder) in installedFiles {
            let installed = try? Data(contentsOf: folder.appendingPathComponent(name))
            if installed != nil { anyInstalled = true }
            if installed != (try? Data(contentsOf: bundled.appendingPathComponent(name))) { anyDifferent = true }
        }
        return !anyInstalled ? .missing : anyDifferent ? .outdated : .current
    }

    /// Copies the hooks and the `localhost` and `tellurion` commands out of the app.
    static func installFiles() throws {
        guard let bundled else { throw Failure(message: "This build of Tellurion doesn't include the agent hooks.") }
        let fm = FileManager.default
        var folders = [hooksFolder, binFolder]
        // Agents may still run the pre-rebrand copy (Codex ties approvals to the exact path).
        let legacy = URL(fileURLWithPath: HookConfig.legacyHooksFolder(home: home), isDirectory: true)
        if fm.fileExists(atPath: legacy.path) { folders.append(legacy) }
        for folder in folders { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        for (name, folder) in installedFiles {
            try copy(bundled.appendingPathComponent(name), to: folder.appendingPathComponent(name), executable: executables.contains(name))
            if folder == hooksFolder, folders.contains(legacy) {
                try copy(bundled.appendingPathComponent(name), to: legacy.appendingPathComponent(name), executable: executables.contains(name))
            }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: installedAtKey)
    }

    /// When the hooks were last installed or repaired from here; older hook errors are history.
    static let installedAtKey = "ExtremeHooksInstalledAt"

    /// After a rebuild, the installed hooks are brought up to date with the app's own, but
    /// only when they were installed before and only from the real app (test copies have
    /// their own bundle id and leave the user's hooks alone).
    static func refreshIfInstalled() {
        guard Bundle.main.bundleIdentifier == "com.steventsvik.ghostty-extreme",
              filesState() == .outdated else { return }
        try? installFiles()
    }

    private static func copy(_ source: URL, to destination: URL, executable: Bool) throws {
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: destination.path)
    }

    // MARK: Agent configs

    static func file(for agent: HookConfig.Agent) -> URL {
        agent == .claude ? claudeSettings : codexHooks
    }

    /// The agent's config, or an empty one when there's no file yet. Throws when the file
    /// exists but isn't JSON we can safely rewrite.
    static func readConfig(_ agent: HookConfig.Agent) throws -> [String: Any] {
        let url = file(for: agent)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "\(display(url)) isn't valid JSON, so it was left alone. Fix it and try again.")
        }
        return object
    }

    static func report(_ agent: HookConfig.Agent) -> HookConfig.Report? {
        (try? readConfig(agent)).map { HookConfig.report($0, agent: agent, home: home) }
    }

    /// Adds our hook entries to the agent's config. Returns what changed.
    @discardableResult
    static func connect(_ agent: HookConfig.Agent) throws -> [String] {
        let merge = HookConfig.merge(try readConfig(agent), agent: agent, home: home)
        guard !merge.changes.isEmpty else { return [] }
        try write(merge.config, to: file(for: agent))
        return merge.changes
    }

    @discardableResult
    static func disconnect(_ agent: HookConfig.Agent) throws -> [String] {
        let merge = HookConfig.remove(try readConfig(agent), agent: agent)
        guard !merge.changes.isEmpty else { return [] }
        try write(merge.config, to: file(for: agent))
        return merge.changes
    }

    private static func write(_ config: [String: Any], to link: URL) throws {
        // A symlinked settings file (a dotfiles repo) stays a link: write to what it points at.
        let url = link.resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).ghostty-extreme-backup-\(AgentTools.timestamp())")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Everything at once

    /// What the welcome window's "Set up" does: installs the hooks and connects whichever of
    /// Claude Code, Codex and zsh are chosen. Returns what was done, for the user.
    static func setUp(claude: Bool, codex: Bool, shell: Bool) throws -> [String] {
        var done: [String] = []
        if filesState() != .current {
            try installFiles()
            done.append("hooks installed")
        }
        if claude, try !connect(.claude).isEmpty { done.append("Claude Code connected") }
        if codex, try !connect(.codex).isEmpty { done.append("Codex connected") }
        if shell && zshIsLoginShell && !shellIntegrationInstalled() {
            try addShellIntegration()
            done.append("~/.zshrc updated")
        }
        return done
    }

    // MARK: Shell

    static var zshIsLoginShell: Bool {
        (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").hasSuffix("/zsh")
    }

    static func shellIntegrationInstalled() -> Bool {
        HookConfig.zshrcHasIntegration((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "")
    }

    static func addShellIntegration() throws {
        let text = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !HookConfig.zshrcHasIntegration(text) else { return }
        // Appended, not rewritten: the rest of the file is untouched.
        let handle = try FileHandle(forWritingTo: ensureExists(zshrc))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(HookConfig.zshrcBlock.utf8))
    }

    static func removeShellIntegration() throws {
        guard let text = try? String(contentsOf: zshrc, encoding: .utf8), text.contains(HookConfig.zshrcBlock) else { return }
        try HookConfig.zshrcRemovingIntegration(text).write(to: zshrc, atomically: true, encoding: .utf8)
    }

    private static func ensureExists(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        return url
    }

    /// `~/.claude/settings.json` rather than the full path.
    static func display(_ url: URL) -> String {
        url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
#endif
