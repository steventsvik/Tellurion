#if os(macOS)
import Foundation

/// Finds command line tools the app runs itself (jj, gt, but…). The app doesn't get the
/// login shell's PATH, so this looks where installers put them, then (off the main thread)
/// on the login shell's PATH. A tool found once is remembered; one that wasn't found is
/// looked for again after a short while, so a tool installed since turns up.
enum ToolPath {
    private static let lock = NSLock()
    private static var found: [String: String] = [:]
    /// Tools not found, when, and whether the login shell's PATH was searched too.
    private static var missed: [String: (at: Date, thorough: Bool)] = [:]
    /// How long a miss is remembered.
    static let missExpiry: TimeInterval = 30

    static func find(_ names: String...) -> String? {
        let home = NSHomeDirectory()
        let common = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/.local/bin",
                      home + "/.bun/bin", home + "/.npm-global/bin", home + "/.nix-profile/bin",
                      "/run/current-system/sw/bin", home + "/.local/share/mise/shims"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // The login shell is only asked off the main thread (the first time takes seconds).
        let thorough = !Thread.isMainThread
        return find(names, in: path + common, thorough: thorough, locate: thorough ? SetupChecks.locate : nil)
    }

    /// `find`, with the folders and the slower lookup given (for tests). The lock is never
    /// held while looking: this is called from views, and `locate` can take seconds.
    static func find(_ names: [String], in folders: [String], thorough: Bool, now: Date = Date(),
                     locate: ((String) -> String?)?) -> String? {
        lock.lock()
        for name in names {
            if let path = found[name] {
                lock.unlock()
                return path
            }
        }
        let wanted = names.filter { name in
            guard let miss = missed[name], now.timeIntervalSince(miss.at) < missExpiry else { return true }
            // A quick look that found nothing doesn't stand in for a thorough one.
            return thorough && !miss.thorough
        }
        lock.unlock()
        for name in wanted {
            let hit = folders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? locate?(name)
            lock.lock()
            if let hit {
                found[name] = hit
                missed[name] = nil
            } else {
                missed[name] = (now, thorough)
            }
            lock.unlock()
            if let hit { return hit }
        }
        return nil
    }

    /// Forgets what was found and missed (for tests).
    static func forgetAll() {
        lock.lock()
        found = [:]
        missed = [:]
        lock.unlock()
    }

    /// Runs `tool` synchronously in `directory`. Call off the main thread.
    static func run(_ tool: String, _ args: [String], in directory: String, environment extra: [String: String] = [:]) -> AgentTools.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.merge(extra) { $1 }
        process.environment = EventToken.scrubbed(environment)
        // These can be network operations (a push), so the limit is generous.
        let result = ProcessRunner.run(process, timeout: 600)
        if let failure = result.launchError { return AgentTools.Result(status: -1, output: "", error: failure) }
        return AgentTools.Result(status: result.status,
                                 output: String(bytes: result.stdout, encoding: .utf8) ?? "",
                                 error: String(bytes: result.stderr, encoding: .utf8) ?? "")
    }
}
#endif
