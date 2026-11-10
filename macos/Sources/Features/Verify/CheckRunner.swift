#if os(macOS)
import Foundation

/// Runs a project's check to the end and says how it went.
enum CheckRunner {
    struct Outcome: Equatable {
        var state: CheckResult.State
        /// The command's exit status; nil when it couldn't be started.
        var status: Int32?
        var summary: String
    }

    /// The user's login shell, or zsh when `SHELL` doesn't name a program.
    static var loginShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    /// The process that runs `command` in `root` through `shell -lc`, everything it prints
    /// going to `log`.
    ///
    /// The command is handed over as one argument, exactly as it was typed; the line `sh`
    /// itself reads is fixed, and only swaps in the login shell with its output pointed at
    /// the log.
    static func process(command: String, root: String, shell: String, log: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"exec "$0" -lc "$1" >"$2" 2>&1"#, shell, command, log.path]
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        return process
    }

    /// Runs the check and waits for it; call off the main thread. The environment is the
    /// app's own without the event token (see `ProcessRunner`). The log is then cut to its
    /// last `CheckOutput.logLimit` bytes.
    static func run(command: String, in root: String, timeout: TimeInterval, log: URL,
                    shell: String = CheckRunner.loginShell) -> Outcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Its own file, readable by the user only: a check's output can hold anything.
        try? fm.removeItem(at: log)
        guard fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            return Outcome(state: .failed, status: nil, summary: "Couldn't write the check's log")
        }
        let output = ProcessRunner.run(process(command: command, root: root, shell: shell, log: log), timeout: timeout)
        let kept = CheckOutput.tail(of: log) ?? Data()
        if let size = (try? fm.attributesOfItem(atPath: log.path))?[.size] as? Int, size > kept.count {
            try? kept.write(to: log, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        }
        return outcome(of: output, printed: String(decoding: kept, as: UTF8.self), timeout: timeout)
    }

    /// How a finished run went, from the process's result and what it printed.
    static func outcome(of output: ProcessRunner.Output, printed: String, timeout: TimeInterval) -> Outcome {
        if output.launchError != nil {
            return Outcome(state: .failed, status: nil, summary: "Couldn't start the check")
        }
        if output.timedOut {
            return Outcome(state: .timedOut, status: output.status, summary: "Stopped after \(CheckOutput.duration(timeout))")
        }
        let last = CheckOutput.summary(of: printed)
        if output.status == 0 {
            return Outcome(state: .passed, status: 0, summary: last.isEmpty ? "Passed" : last)
        }
        return Outcome(state: .failed, status: output.status, summary: last.isEmpty ? "Exit status \(output.status)" : last)
    }
}

/// A cheap picture of a project's files, to tell whether a turn changed anything: the commit
/// it's on, what git lists as changed, and each of those files' size and date. Nothing is
/// written to the repository.
enum CheckFingerprint {
    /// Call off the main thread. Nil when git can't say (then the check just runs).
    static func take(_ root: String) -> String? {
        let status = AgentTools.git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
        guard status.ok else { return nil }
        let head = AgentTools.git(["rev-parse", "--verify", "--quiet", "HEAD"], in: root).output
        return compose(head: head.trimmingCharacters(in: .whitespacesAndNewlines), status: status.output) { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: (root as NSString).appendingPathComponent(path))
            guard let attributes else { return "-" }
            let size = attributes[.size] as? Int ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size):\(modified)"
        }
    }

    static func compose(head: String, status: String, stamp: (String) -> String) -> String {
        ([head, status] + paths(inStatus: status).map { "\($0)=\(stamp($0))" }).joined(separator: "\n")
    }

    /// The paths in `git status --porcelain=v1 -z` output. A rename's entry is followed by
    /// the path it was renamed from, which is skipped.
    static func paths(inStatus status: String) -> [String] {
        let fields = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            guard entry.count > 3 else { continue }
            if entry.prefix(2).contains(where: { $0 == "R" || $0 == "C" }) { index += 1 }
            paths.append(String(entry.dropFirst(3)))
        }
        return paths
    }
}
#endif
