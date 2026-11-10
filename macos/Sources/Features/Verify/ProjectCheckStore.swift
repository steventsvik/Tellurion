#if os(macOS)
import Foundation
import os

/// One project's check: the command that has to pass before its agents' work counts as done.
struct ProjectCheck: Codable, Equatable {
    /// The shell line, exactly as it was typed in the Checks window.
    var command: String
    /// Seconds the command gets before it's stopped.
    var timeout: TimeInterval = ProjectCheck.defaultTimeout
    /// A failed check goes back to the agent whose turn set it off, without asking.
    var autoSend = false

    static let defaultTimeout: TimeInterval = 600
    static let timeoutRange: ClosedRange<TimeInterval> = 10...7200

    init(command: String, timeout: TimeInterval = ProjectCheck.defaultTimeout, autoSend: Bool = false) {
        self.command = command
        self.timeout = min(max(timeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        self.autoSend = autoSend
    }

    private enum CodingKeys: String, CodingKey { case command, timeout, autoSend }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(command: try container.decode(String.self, forKey: .command),
                  timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? Self.defaultTimeout,
                  autoSend: try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? false)
    }
}

/// The checks the user has saved, by project root, in Tellurion's own folder.
///
/// A check is only ever set here, from the Checks window. Nothing inside a repository is read
/// for it, so opening a clone can't make the app run something.
struct ProjectCheckStore {
    /// `~/.ghostty-extreme/checks/checks.json`.
    static var defaultURL: URL { folder.appendingPathComponent("checks.json") }
    static var folder: URL { AgentTools.root.appendingPathComponent("checks", isDirectory: true) }

    private struct File: Codable {
        var projects: [String: ProjectCheck]
    }

    private static let log = StoredFile.logger("Checks")

    let url: URL
    private(set) var checks: [String: ProjectCheck] = [:]
    /// The saved file was there and couldn't be read; it was set aside and the list starts empty.
    private(set) var wasUnreadable = false

    init(url: URL = ProjectCheckStore.defaultURL) {
        self.url = url
        switch StoredFile.load(File.self, from: url, what: "the project checks", log: Self.log) {
        case .loaded(let file): checks = file.projects.filter { !$0.value.command.isEmpty }
        case .unreadable: wasUnreadable = true
        case .missing: break
        }
    }

    /// A project root as it's keyed: no trailing slash, no `.` or `..` parts.
    static func key(_ root: String) -> String {
        (root as NSString).standardizingPath
    }

    func check(for root: String) -> ProjectCheck? {
        checks[Self.key(root)]
    }

    /// Saves `check` for `root`. Nil, or a command that's only spaces, removes it. The command
    /// keeps everything between its first and last visible character as typed.
    @discardableResult
    mutating func set(_ check: ProjectCheck?, for root: String) -> Bool {
        let command = check?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if var check, !command.isEmpty {
            check.command = command
            checks[Self.key(root)] = check
        } else {
            checks.removeValue(forKey: Self.key(root))
        }
        return StoredFile.write(json: File(projects: checks), to: url, what: "the project checks", log: Self.log)
    }

    /// The saved project that `folder` is in: itself or the nearest one above it.
    func root(containing folder: String) -> String? {
        let folder = Self.key(folder)
        return checks.keys
            .filter { folder == $0 || folder.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .max { $0.count < $1.count }
    }
}
#endif
