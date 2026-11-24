#if os(macOS)
import Foundation

/// Saves you the "do you trust this folder?" question Claude Code and Codex ask the first
/// time they start somewhere, for folders where the answer is already known:
///
/// - the app's own empty working folder (`~/.ghostty-extreme/board-agent`), which holds no
///   project and so nothing of anyone else's to run;
/// - a folder you picked in one of the app's folder choosers during this run, to start agents
///   in;
/// - a worktree the app made of a project that agent already trusts.
///
/// Nothing else is ever trusted for you: not a folder a board's file names (any program can
/// write that file), not the folder a terminal happens to be in, and never your home folder,
/// Downloads, a temporary folder, or anything macOS marked as downloaded. Those still get the
/// agent's own question.
///
/// It's the same record the agent writes when you answer yes: `hasTrustDialogAccepted` for
/// the folder in Claude Code's `.claude.json`, `trust_level = "trusted"` for it in Codex's
/// `config.toml`. Turn it off with `defaults write <bundle id> AgentPreTrust -bool false`.
enum AgentTrust {
    static let key = "AgentPreTrust"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Why a folder may be trusted without asking.
    enum Reason: Equatable {
        /// The app's own working folder.
        case appFolder
        /// Picked in a folder chooser in this run.
        case chosen
        /// A worktree the app made of this project, which the agent trusts.
        case worktree(of: String)
    }

    /// The folders picked in the app's folder choosers in this run. In memory only, like the
    /// tiles started without permission prompts: nothing on disk can add to it.
    private static var chosen: Set<String> = []
    /// What's been recorded already, so a launch doesn't read the agents' files again.
    private static var recorded: Set<String> = []
    private static let lock = NSLock()

    /// The app's own working folder, for agents that aren't working on a project.
    static var appFolder: String { AgentTools.root.appendingPathComponent("board-agent", isDirectory: true).path }

    /// You picked this folder, in a folder chooser, to start agents in.
    static func chose(_ folder: String) {
        let path = normalize(folder)
        lock.lock()
        chosen.insert(path)
        lock.unlock()
    }

    /// Called where the app starts `agent` in `folder`: records the folder as trusted for that
    /// agent if it's one of the cases above. `worktreeOf` is the project a worktree was made of.
    /// `environment` is the tile's, for agents signed in under another profile.
    static func prepare(folder: String?, agent: VerticalTabAgentKind?, worktreeOf project: String? = nil,
                        environment: [String: String] = [:]) {
        guard enabled, let folder, !folder.isEmpty, let agent, agent == .claude || agent == .codex else { return }
        let path = normalize(folder)
        let home = HookInstaller.home
        let store: URL = agent == .claude
            ? URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" } ?? home + "/.claude.json")
            : URL(fileURLWithPath: (environment["CODEX_HOME"] ?? home + "/.codex") + "/config.toml")
        let memo = "\(store.path)\n\(path)"
        lock.lock()
        let wasChosen = chosen.contains(path)
        let done = recorded.contains(memo)
        lock.unlock()
        guard !done else { return }

        let projectTrusted = project.map { project in
            let project = normalize(project)
            return agent == .claude ? claudeTrusts(project, in: store) : codexTrusts(project, in: store)
        } ?? false
        guard reason(folder: path, appFolder: normalize(appFolder), chosen: wasChosen,
                     worktreeOf: project.map(normalize), projectTrusted: projectTrusted,
                     home: normalize(home), downloaded: isDownloaded(path)) != nil else { return }

        let ok = agent == .claude ? trustClaude(path, in: store) : trustCodex(path, in: store)
        if ok {
            lock.lock()
            recorded.insert(memo)
            lock.unlock()
        }
    }

    // swiftlint:disable function_parameter_count
    /// Whether `folder` may be trusted without asking, and why. Paths are normalized.
    static func reason(folder: String, appFolder: String, chosen: Bool, worktreeOf project: String?,
                       projectTrusted: Bool, home: String, downloaded: Bool) -> Reason? {
        // The app's folder is the one place that needs no more checks: the app made it, empty.
        if folder == appFolder { return .appFolder }
        guard !isUnsafe(folder, home: home), !downloaded else { return nil }
        if chosen { return .chosen }
        if let project, projectTrusted, !isUnsafe(project, home: home) { return .worktree(of: project) }
        return nil
    }
    // swiftlint:enable function_parameter_count

    /// Places that are never trusted on your behalf, whoever picked them: too broad (the
    /// disk, your home folder and the folders it's made of), or where other people's files
    /// land (Downloads, temporary folders).
    static func isUnsafe(_ folder: String, home: String) -> Bool {
        if folder == "/" || folder == home || !folder.hasPrefix("/") { return true }
        if (home + "/").hasPrefix(folder + "/") { return true }
        let broad = ["Desktop", "Documents", "Library", "Public", "Movies", "Music", "Pictures", "Applications"]
        if broad.contains(where: { folder == home + "/" + $0 }) { return true }
        let roots = [home + "/Downloads", home + "/.Trash", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
                     "/var/folders", "/private/var/folders", "/Volumes", "/Users/Shared"]
        return roots.contains { folder == $0 || folder.hasPrefix($0 + "/") }
    }

    /// The path as agents see it: no trailing slash, no `..`, symbolic links followed.
    static func normalize(_ folder: String) -> String {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether macOS marked the folder as downloaded (unpacked from a downloaded archive,
    /// cloned by a quarantining app), or it isn't a folder at all.
    static func isDownloaded(_ folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return true }
        return getxattr(folder, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    // MARK: Claude Code

    static func claudeTrusts(_ folder: String, in store: URL) -> Bool {
        guard let data = try? Data(contentsOf: store), data.count < 64_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return false }
        return (projects[folder] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
    }

    /// Records the folder as trusted, as Claude Code does when you say yes. The file is shared
    /// with every running session and holds much more than this, so only the one value is
    /// put into its text (nothing else is rewritten or reordered), in one step, only when
    /// there's something to add, and not at all if it changed while this was reading it.
    @discardableResult
    static func trustClaude(_ folder: String, in store: URL) -> Bool {
        for _ in 0..<3 {
            let before = modified(store)
            // No file yet means Claude Code hasn't been set up; it'll ask its own questions.
            guard let data = try? Data(contentsOf: store), data.count < 64_000_000,
                  let old = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else { return false }
            if ((old["projects"] as? NSDictionary)?[folder] as? NSDictionary)?["hasTrustDialogAccepted"] as? Bool == true { return true }
            guard let added = JSONText.set(true, at: ["projects", folder, "hasTrustDialogAccepted"], in: data),
                  // What's written must be the old file with exactly that value set.
                  let new = try? JSONSerialization.jsonObject(with: added) as? NSDictionary,
                  new == expected(old, trusting: folder) else { return false }
            guard modified(store) == before else { continue }
            return write(added, to: store)
        }
        return false
    }

    private static func expected(_ old: NSDictionary, trusting folder: String) -> NSDictionary {
        let root = NSMutableDictionary(dictionary: old)
        let projects = NSMutableDictionary(dictionary: old["projects"] as? NSDictionary ?? [:])
        let project = NSMutableDictionary(dictionary: projects[folder] as? NSDictionary ?? [:])
        project["hasTrustDialogAccepted"] = true
        projects[folder] = project
        root["projects"] = projects
        return root
    }

    // MARK: Codex

    static func codexTrusts(_ folder: String, in store: URL) -> Bool {
        guard let text = try? String(contentsOf: store, encoding: .utf8), let header = codexHeader(folder) else { return false }
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line == header; continue }
            if inside, line.replacingOccurrences(of: " ", with: "") == "trust_level=\"trusted\"" { return true }
        }
        return false
    }

    /// The table Codex keeps a project's trust in, or nil for a path that can't be written
    /// plainly in TOML (those are left to Codex).
    static func codexHeader(_ folder: String) -> String? {
        guard !folder.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.properties.generalCategory == .control }) else { return nil }
        return "[projects.\"\(folder)\"]"
    }

    /// Adds the folder's table to the end of Codex's config. Never when the file already
    /// mentions the folder in any form, since a second table for it would stop Codex reading
    /// its config at all.
    @discardableResult
    static func trustCodex(_ folder: String, in store: URL) -> Bool {
        guard let header = codexHeader(folder) else { return false }
        for _ in 0..<3 {
            let before = modified(store)
            // No config yet means Codex hasn't been set up; it'll ask its own questions.
            guard let text = try? String(contentsOf: store, encoding: .utf8) else { return false }
            if codexTrusts(folder, in: store) { return true }
            guard !text.contains(folder + "\""), !text.contains(folder + "'") else { return false }
            let added = text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + "\n\(header)\ntrust_level = \"trusted\"\n"
            guard modified(store) == before else { continue }
            return write(Data(added.utf8), to: store)
        }
        return false
    }

    // MARK: Files

    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Replaces the file in one step, keeping who may read it.
    private static func write(_ data: Data, to file: URL) -> Bool {
        // The file itself, not a link to it (configs kept in a dotfiles folder).
        let file = file.resolvingSymlinksInPath()
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: file.path))?[.posixPermissions]
        let draft = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).tellurion-\(UUID().uuidString.prefix(8))")
        guard manager.createFile(atPath: draft.path, contents: data, attributes: [.posixPermissions: permissions ?? 0o600]) else { return false }
        guard rename(draft.path, file.path) == 0 else {
            try? manager.removeItem(at: draft)
            return false
        }
        return true
    }
}

/// Sets one true/false value inside JSON text and leaves every other byte as it was: the
/// file's order, spacing and number spellings belong to the program that owns it.
enum JSONText {
    /// The text with `value` at `path` (keys of nested objects, made where missing), or nil
    /// if the text isn't an object or something on the way isn't one.
    static func set(_ value: Bool, at path: [String], in data: Data) -> Data? {
        var bytes = [UInt8](data)
        var index = skipSpace(bytes, 0)
        let literal = Array((value ? "true" : "false").utf8)
        for (depth, key) in path.enumerated() {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
            let open = index
            if let found = member(key, in: bytes, objectAt: open) {
                if depth == path.count - 1 {
                    bytes.replaceSubrange(found, with: literal)
                    return Data(bytes)
                }
                index = found.lowerBound
                continue
            }
            // Not there: this key and whatever's below it go in as the object's first member.
            guard let keys = try? path[depth...].map({ try quoted($0) }) else { return nil }
            var text = keys.joined(separator: ":{") + ":" + String(decoding: literal, as: UTF8.self)
            text += String(repeating: "}", count: keys.count - 1)
            let next = skipSpace(bytes, open + 1)
            guard next < bytes.count else { return nil }
            if bytes[next] != UInt8(ascii: "}") { text += "," }
            bytes.insert(contentsOf: Array(text.utf8), at: open + 1)
            return Data(bytes)
        }
        return nil
    }

    private static func quoted(_ string: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Where the value of `key` is in the object that opens at `open`.
    private static func member(_ key: String, in bytes: [UInt8], objectAt open: Int) -> Range<Int>? {
        var index = skipSpace(bytes, open + 1)
        while index < bytes.count, bytes[index] == UInt8(ascii: "\"") {
            guard let keyEnd = endOfString(bytes, index) else { return nil }
            let name = try? JSONSerialization.jsonObject(with: Data(bytes[index..<keyEnd]), options: .fragmentsAllowed) as? String
            index = skipSpace(bytes, keyEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            let start = skipSpace(bytes, index + 1)
            guard let end = endOfValue(bytes, start) else { return nil }
            if name == key { return start..<end }
            index = skipSpace(bytes, end)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ",") else { return nil }
            index = skipSpace(bytes, index + 1)
        }
        return nil
    }

    private static func skipSpace(_ bytes: [UInt8], _ from: Int) -> Int {
        var index = from
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        return index
    }

    /// The index after the string that opens at `from`.
    private static func endOfString(_ bytes: [UInt8], _ from: Int) -> Int? {
        var index = from + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
            if bytes[index] == UInt8(ascii: "\"") { return index + 1 }
            index += 1
        }
        return nil
    }

    /// The index after the value that starts at `from`.
    private static func endOfValue(_ bytes: [UInt8], _ from: Int) -> Int? {
        guard from < bytes.count else { return nil }
        switch bytes[from] {
        case UInt8(ascii: "\""):
            return endOfString(bytes, from)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var index = from
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    guard let end = endOfString(bytes, index) else { return nil }
                    index = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        default:
            var index = from
            let ends: [UInt8] = [0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D]
            while index < bytes.count, !ends.contains(bytes[index]) { index += 1 }
            return index > from ? index : nil
        }
    }
}
#endif
