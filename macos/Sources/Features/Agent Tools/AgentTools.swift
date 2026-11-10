#if os(macOS)
import AppKit

/// Shared plumbing for Mission Control, agent races and handoffs: running git, and starting
/// an agent CLI with a long prompt in a new tab or split.
enum AgentTools {
    /// Where races and handoff prompts are kept (no spaces, so paths paste cleanly into shells).
    /// Boards and the board agent's files live here too. Test-only: `TELLURION_TEST_HOME`
    /// moves it, as it does the hooks, so a test copy stays out of your boards (an app's
    /// NSHomeDirectory ignores HOME).
    static let root = URL(fileURLWithPath: HookInstaller.home).appendingPathComponent(".ghostty-extreme", isDirectory: true)

    /// The app's folder in Application Support (`GhosttyEXTREME`). Test-only:
    /// `TELLURION_TEST_HOME` moves it under that folder, like `root`.
    static var supportFolder: URL {
        let library = TestHooks.home.map { URL(fileURLWithPath: $0).appendingPathComponent("Library/Application Support", isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("GhosttyEXTREME", isDirectory: true)
    }

    struct Result {
        let status: Int32
        let output: String
        let error: String
        var ok: Bool { status == 0 }
    }

    /// Settings a repository's own config can't set when the app runs git by itself.
    ///
    /// A clone's `.git/config` can name programs for git to run: a file monitor, hooks, a
    /// credential helper, an askpass program, a signing program. The app's own commands never
    /// want any of them, so a repository doesn't get to run something just by being open in
    /// a tab or the editor. A caller's own `-c` comes after these and wins. Diffs add
    /// `diffGuards` themselves, since those are options of the diff command. No `ext::`
    /// remotes (a URL rewrite can turn any remote into one), and no signature checks in logs,
    /// which would run the configured gpg program.
    ///
    /// Filter programs have names of the repository's choosing, so no fixed setting reaches
    /// them: `gitEnvironment(in:)` switches off the ones a repository's config defines.
    static let gitGuards: [String] = [
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
        "-c", "tag.gpgsign=false", "-c", "core.askPass=", "-c", "credential.helper=",
        "-c", "protocol.ext.allow=never", "-c", "log.showSignature=false",
    ]

    /// For `git diff`: no external diff programs and no text converters, which a repository
    /// can also name in its config.
    static let diffGuards = ["--no-ext-diff", "--no-textconv"]

    /// The environment for a git the app runs in `directory`: the app's own without the event
    /// token, never prompting, plus settings that switch off every filter program the
    /// repository's own config defines (`git add`, `diff`, `restore` and `stash` run a file's
    /// filter through the shell). Filters from your global config, such as Git LFS's, stay.
    /// `leading` is any `--git-dir`/`--work-tree` the command itself starts with.
    ///
    /// The settings go in git's environment rather than `-c`, which can't name a filter
    /// whose name contains "=".
    static func gitEnvironment(in directory: String, leading: [String] = []) -> [String: String] {
        var environment = EventToken.scrubbed(ProcessInfo.processInfo.environment)
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let listing = run(["-C", directory] + leading + gitGuards
                          + ["config", "--show-scope", "-z", "--get-regexp", #"^filter\..*\.(clean|smudge|process)$"#],
                          environment: environment)
        return withSettings(filterOverrides(listing.output), environment)
    }

    /// Git LFS's own drivers, as `git lfs install --local` writes them.
    private static let lfsDrivers: Set<String> = ["git-lfs clean -- %f", "git-lfs smudge -- %f", "git-lfs filter-process"]

    /// Empty drivers for each filter that `git config --show-scope -z` lists from the
    /// repository's own config (local or worktree scope), apart from Git LFS's.
    static func filterOverrides(_ listing: String) -> [(key: String, value: String)] {
        let fields = listing.split(separator: "\0", omittingEmptySubsequences: false)
        var names: [String] = []
        for index in stride(from: 0, to: fields.count - 1, by: 2) where ["local", "worktree"].contains(String(fields[index])) {
            let entry = fields[index + 1]
            let key = entry.prefix { $0 != "\n" }
            let value = String(entry.dropFirst(key.count + 1))
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot > key.index(key.startIndex, offsetBy: 6),
                  !lfsDrivers.contains(value) else { continue }
            let name = String(key[key.index(key.startIndex, offsetBy: 7)..<dot])
            if !names.contains(name) { names.append(name) }
        }
        return names.flatMap { name in
            ["clean", "smudge", "process"].map { (key: "filter.\(name).\($0)", value: "") }
                + [(key: "filter.\(name).required", value: "false")]
        }
    }

    /// `environment` with `settings` added the way `git -c` would, after any it already has.
    static func withSettings(_ settings: [(key: String, value: String)], _ environment: [String: String]) -> [String: String] {
        guard !settings.isEmpty else { return environment }
        var environment = environment
        var count = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
        for setting in settings {
            environment["GIT_CONFIG_KEY_\(count)"] = setting.key
            environment["GIT_CONFIG_VALUE_\(count)"] = setting.value
            count += 1
        }
        environment["GIT_CONFIG_COUNT"] = String(count)
        return environment
    }

    /// Runs git synchronously, with `gitGuards` and `gitEnvironment(in:)`; `environment` goes
    /// on top of that. Call off the main thread for anything that can be slow.
    @discardableResult
    static func git(_ args: [String], in directory: String, gitPath: String = "/usr/bin/git",
                    environment extra: [String: String] = [:]) -> Result {
        run(gitProcess(args, in: directory, gitPath: gitPath, environment: extra))
    }

    /// A git process set up like `git(_:in:)` runs one, for a caller that has to feed its
    /// standard input. The guards and the environment are the same.
    static func gitProcess(_ args: [String], in directory: String, gitPath: String = "/usr/bin/git",
                           environment extra: [String: String] = [:]) -> Process {
        let leading = Array(args.prefix { $0.hasPrefix("--git-dir=") || $0.hasPrefix("--work-tree=") })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", directory] + gitGuards + args
        process.environment = gitEnvironment(in: directory, leading: leading).merging(extra) { $1 }
        return process
    }

    private static func run(_ arguments: [String], environment: [String: String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = environment
        return run(process)
    }

    /// Runs a process to the end and collects what it wrote. Git's own commands here are
    /// local, so one that's still going after `timeout` seconds is stuck, and is stopped.
    private static func run(_ process: Process, timeout: TimeInterval = 300) -> Result {
        let result = ProcessRunner.run(process, timeout: timeout)
        if let failure = result.launchError { return Result(status: -1, output: "", error: failure) }
        return Result(status: result.status, output: result.text,
                      error: result.timedOut && result.stderr.isEmpty ? "Timed out after \(Int(timeout)) seconds" : result.errorText)
    }

    /// The repository containing `folder`, if any.
    static func repoRoot(of folder: String) -> String? {
        let result = git(["rev-parse", "--show-toplevel"], in: folder)
        let root = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && !root.isEmpty ? root : nil
    }

    /// `s` as one shell argument. Control characters are left out: these lines are typed
    /// into a terminal, where one acts as a key (Ctrl-U erases the line, Return runs it)
    /// before the shell reads any quotes.
    static func shellQuote(_ s: String) -> String {
        let plain = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.properties.generalCategory != .control }))
        return "'" + plain.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `line` if it's safe to type into a shell as it is: no control characters apart from
    /// one newline at the end. Nil otherwise, and then nothing should be typed.
    static func typedLine(_ line: String) -> String? {
        let body = line.hasSuffix("\n") ? String(line.dropLast()) : line
        return Ghostty.Shell.containsControlCharacters(body) ? nil : line
    }

    /// The shell line that starts `agent` with the prompt stored in `promptFile`. The prompt
    /// is read by the shell, so it can be any length and contain any characters.
    static func agentCommand(_ agent: VerticalTabAgentKind, promptFile: URL) -> String {
        let binary = agent == .codex ? "codex" : "claude"
        return "\(binary) \"$(cat \(shellQuote(promptFile.path)))\"\n"
    }

    /// Saves a prompt under ~/.ghostty-extreme/<folder>/ and returns its file.
    static func writePrompt(_ text: String, folder: String, name: String) -> URL? {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    /// The agent's most recent reply, read from the end of its transcript.
    static func lastAssistantMessage(transcript path: String?) -> String? {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("assistant") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            // Claude Code: {"type":"assistant","message":{"content":[{"type":"text","text":...}]}}
            if record["type"] as? String == "assistant", let message = record["message"] as? [String: Any] {
                let parts = (message["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
            // Codex: {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":...}]}}
            if let payload = record["payload"] as? [String: Any], payload["type"] as? String == "message",
               payload["role"] as? String == "assistant" {
                let parts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                if !parts.isEmpty { return parts.joined(separator: "\n") }
            }
        }
        return nil
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…(cut)" : text
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
#endif
