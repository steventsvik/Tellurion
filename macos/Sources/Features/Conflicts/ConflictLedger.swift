#if os(macOS)
import Foundation

/// Paths as the conflict radar compares them: absolute, with symlinks resolved, then
/// relative to the top of the working copy they're in.
enum ConflictPaths {
    /// `raw` as an absolute path with no `..` and no symlinks in it. A relative path is taken
    /// from `folder`; without one it can't be placed. A file that's gone (deleted since) keeps
    /// the real path of the nearest folder that's still there.
    static func resolve(_ raw: String, folder: String?) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path == "~" || path.hasPrefix("~/") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
            guard let folder, folder.hasPrefix("/") else { return nil }
            path = (folder as NSString).appendingPathComponent(path)
        }
        var head = (path as NSString).standardizingPath
        var tail: [String] = []
        while head != "/" && !head.isEmpty {
            if let real = real(head) {
                return tail.isEmpty ? real : (real as NSString).appendingPathComponent(tail.reversed().joined(separator: "/"))
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return "/" + tail.reversed().joined(separator: "/")
    }

    /// The path with every symlink resolved, if it exists.
    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` relative to `root`, if it's inside it and not part of git's own folder.
    static func relative(_ path: String, to root: String) -> String? {
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        guard !relative.isEmpty, relative != ".git", !relative.hasPrefix(".git/") else { return nil }
        return relative
    }

    /// The paths `git status --porcelain=v1 -z` lists: everything that differs from the last
    /// commit, is untracked or is ignored. A rename lists both of its names.
    static func changedPaths(porcelain: String) -> Set<String> {
        var paths: Set<String> = []
        var fields = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = fields.next() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.insert(String(entry.dropFirst(3)))
            // "R  new\0old\0": the name it had before follows.
            if status.contains("R") || status.contains("C"), let original = fields.next() { paths.insert(String(original)) }
        }
        return paths
    }
}

/// Which pane changed which file, and when: the conflict radar's memory.
///
/// A pane's files are capped (the ones changed longest ago are dropped first), forgotten
/// when its session ends or it closes, and each file is dropped once it's been committed
/// or hasn't been touched for `maxAge`.
struct ConflictLedger {
    /// A file in a working copy. Two worktrees of one repository have different roots, so
    /// the same path in each is a different file.
    struct File: Hashable {
        let root: String
        let path: String
    }

    /// A file a pane changed that other panes changed too.
    struct Hit: Equatable {
        let file: File
        /// The other panes, the one that changed it last first.
        let others: [UUID]
    }

    /// A conflict needs one of its changes to be this recent.
    static let recent: TimeInterval = 30 * 60
    /// A change is forgotten after this long.
    static let maxAge: TimeInterval = 8 * 3600
    /// The most files remembered per pane.
    static let filesPerPane = 300

    private(set) var edits: [UUID: [File: Date]] = [:]

    /// Notes that `pane` changed `file`. The latest time is the one kept.
    mutating func record(_ file: File, by pane: UUID, at date: Date) {
        var files = edits[pane] ?? [:]
        if let known = files[file], known >= date { return }
        files[file] = date
        if files.count > Self.filesPerPane {
            let oldest = files.sorted { $0.value < $1.value }.prefix(files.count - Self.filesPerPane)
            for (file, _) in oldest { files[file] = nil }
        }
        edits[pane] = files
    }

    /// A pane closed, or its agent started a new session.
    mutating func forget(_ pane: UUID) {
        edits[pane] = nil
    }

    /// Forgets every pane that isn't in `live`.
    mutating func keep(only live: Set<UUID>) {
        for pane in edits.keys where !live.contains(pane) { edits[pane] = nil }
    }

    /// Drops changes older than `maxAge`.
    mutating func expire(now: Date) {
        for (pane, files) in edits {
            let kept = files.filter { now.timeIntervalSince($0.value) <= Self.maxAge }
            if kept.count != files.count { edits[pane] = kept.isEmpty ? nil : kept }
        }
    }

    /// Files in `root` that match the last commit again (`clean`) are settled: nobody's
    /// change to them is pending any more. A change made after `before`, when the check
    /// started, stays.
    mutating func settle(root: String, clean: Set<String>, before: Date) {
        guard !clean.isEmpty else { return }
        for (pane, files) in edits {
            let kept = files.filter { !($0.key.root == root && clean.contains($0.key.path) && $0.value < before) }
            if kept.count != files.count { edits[pane] = kept.isEmpty ? nil : kept }
        }
    }

    /// Files more than one pane changed, with those panes.
    func shared() -> [File: [UUID]] {
        var panes: [File: [UUID]] = [:]
        for (pane, files) in edits {
            for file in files.keys { panes[file, default: []].append(pane) }
        }
        return panes.filter { $0.value.count > 1 }
    }

    /// Each pane's conflicts: the files it changed that another pane changed too, where at
    /// least one of those changes was in the last `recent` seconds. Sorted by path.
    func conflicts(now: Date) -> [UUID: [Hit]] {
        var result: [UUID: [Hit]] = [:]
        for (file, panes) in shared() {
            let dated = panes.compactMap { pane in edits[pane]?[file].map { (pane: pane, date: $0) } }
                .filter { now.timeIntervalSince($0.date) <= Self.maxAge }
            guard dated.count > 1, dated.contains(where: { now.timeIntervalSince($0.date) <= Self.recent }) else { continue }
            let ordered = dated.sorted { $0.date != $1.date ? $0.date > $1.date : $0.pane.uuidString < $1.pane.uuidString }
            for entry in ordered {
                result[entry.pane, default: []].append(Hit(file: file, others: ordered.map(\.pane).filter { $0 != entry.pane }))
            }
        }
        return result.mapValues { hits in
            hits.sorted { $0.file.path != $1.file.path ? $0.file.path < $1.file.path : $0.file.root < $1.file.root }
        }
    }
}

/// Which conflicts have been announced already: a pair of panes hears about a file once.
struct ConflictAnnouncements {
    /// Two panes and the files they newly share.
    struct Fresh: Equatable {
        let first: UUID
        let second: UUID
        var files: [ConflictLedger.File]
    }

    private var seen: Set<String> = []

    private static func key(_ file: ConflictLedger.File, _ a: UUID, _ b: UUID) -> String {
        let pair = [a.uuidString, b.uuidString].sorted()
        return [pair[0], pair[1], file.root, file.path].joined(separator: "\0")
    }

    /// The pairs and files in `conflicts` that haven't been announced, one entry per pair,
    /// now marked as announced.
    mutating func fresh(in conflicts: [UUID: [ConflictLedger.Hit]]) -> [Fresh] {
        var found: [Fresh] = []
        for pane in conflicts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            for hit in conflicts[pane] ?? [] {
                for other in hit.others where seen.insert(Self.key(hit.file, pane, other)).inserted {
                    let pair = [pane, other].sorted { $0.uuidString < $1.uuidString }
                    if let index = found.firstIndex(where: { $0.first == pair[0] && $0.second == pair[1] }) {
                        found[index].files.append(hit.file)
                    } else {
                        found.append(Fresh(first: pair[0], second: pair[1], files: [hit.file]))
                    }
                }
            }
        }
        return found
    }

    /// A pane closed: what was announced about it no longer needs remembering.
    mutating func forget(_ pane: UUID) {
        let id = pane.uuidString
        seen = seen.filter { key in !key.split(separator: "\0").prefix(2).contains { $0 == id } }
    }
}

/// The radar's wording, kept neutral: two agents on one file isn't always a mistake (a
/// writer and its reviewer, an orchestrator's agents).
enum ConflictText {
    /// "Otto", "Otto and Ada", "Otto and 2 others".
    static func names(_ names: [String]) -> String {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        switch unique.count {
        case 0: return "another agent"
        case 1: return unique[0]
        case 2: return "\(unique[0]) and \(unique[1])"
        default: return "\(unique[0]) and \(unique.count - 1) others"
        }
    }

    /// "2 files also edited by Otto".
    static func summary(files: Int, others: [String]) -> String {
        "\(files) \(files == 1 ? "file" : "files") also edited by \(names(others))"
    }

    /// "cart.py", "cart.py and api.py", "cart.py and 3 more files".
    static func files(_ paths: [String]) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        switch names.count {
        case 0: return "a file"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) more files"
        }
    }

    /// The one line an agent is sent about files another agent is changing too.
    static func headsUp(paths: [String], others: [String]) -> String {
        let listed = paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? " and \(paths.count - 3) more" : "")
        let verb = Set(others).count > 1 ? "are" : "is"
        return "Heads-up: \(names(others)) \(verb) also editing \(listed) in this same folder. "
            + "Read the current version before you change \(paths.count == 1 ? "it" : "them") again, so you don't overwrite each other's work."
    }
}
#endif
