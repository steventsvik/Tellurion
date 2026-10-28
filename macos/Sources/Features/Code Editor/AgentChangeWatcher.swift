#if os(macOS)
import CoreServices
import Foundation

/// Watches the agent's project on disk and reports exactly which lines each change added or
/// removed, however the change was made: an Edit or Write tool, a patch, a `sed -i`, a script,
/// or a sub-agent. The editor animates these, so it no longer has to guess where an edit
/// landed from the agent's transcript.
///
/// Each file's previous contents come from the last version seen, or else from the snapshot
/// taken when the agent's turn started (see `ReviewInbox`), or the last commit.
final class AgentChangeWatcher {
    /// Lines `start ..< start + count` (1-based, in the new file) were added; `removed` lines
    /// used to be just before `start`.
    struct Hunk {
        let start: Int
        let count: Int
        let removed: [String]

        var json: [String: Any] { ["start": start, "count": count, "removed": Array(removed.prefix(60))] }
    }

    struct Change {
        let path: String
        let hunks: [Hunk]
        let created: Bool
        let deleted: Bool
        let modified: Double

        var json: [String: Any] {
            ["path": path, "hunks": hunks.prefix(40).map(\.json), "created": created, "deleted": deleted, "mtime": modified]
        }
    }

    /// Called on the main queue.
    var onChange: ((Change) -> Void)?

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.agent-changes", qos: .userInitiated)
    private var stream: FSEventStreamRef?
    private(set) var root: String?
    private var repoRoot: String?
    private var baseline: String?
    private var shadow: [String: String] = [:]
    private var pending: Set<String> = []
    private var flushScheduled = false
    /// Whether git ignores a path (build output, secrets, caches), so it isn't the agent's change.
    private var ignored: [String: Bool] = [:]

    private static let maxSize = 1_000_000
    private static let skipped: Set<String> = [
        ".git", "node_modules", ".next", ".nuxt", ".svelte-kit", "dist", "build", ".build", "DerivedData", ".venv",
        "venv", "__pycache__", ".pytest_cache", ".mypy_cache", "target", ".zig-cache", "zig-out", ".turbo", ".cache",
        ".parcel-cache", "coverage", ".gradle", "Pods", ".open-next", ".vercel", ".wrangler", ".output", ".expo",
    ]

    deinit { stopStream() }

    // MARK: Watching

    /// Watches `folder`'s repository (or the folder itself). `baseline` is a git tree to
    /// diff against for files not seen yet.
    func watch(folder: String, repoRoot: String?, baseline: String?) {
        // File events use real paths (/private/tmp, not /tmp), so compare against those.
        let repoRoot = repoRoot.map(Self.realPath)
        let root = repoRoot ?? Self.realPath(folder)
        queue.async { [self] in
            if root == self.root {
                if let baseline, baseline != self.baseline { self.baseline = baseline }
                return
            }
            stopStream()
            self.root = root
            self.repoRoot = repoRoot
            self.baseline = baseline
            shadow.removeAll()
            pending.removeAll()
            ignored.removeAll()
            startStream(root)
        }
    }

    func stop() {
        queue.async { [self] in
            stopStream()
            root = nil
            shadow.removeAll()
        }
    }

    /// The editor saved this content itself; don't report it as the agent's change.
    func noteOwnWrite(path: String, content: String) {
        queue.async { self.shadow[Self.realPath(path)] = content }
    }

    private func startStream(_ root: String) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<AgentChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var files: [String] = []
            for index in 0..<count {
                let flag = Int(flags[index])
                guard flag & kFSEventStreamEventFlagItemIsFile != 0, index < list.count else { continue }
                files.append(list[index])
            }
            watcher.received(files)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.08, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func received(_ paths: [String]) {
        // Event paths are already real paths (standardizingPath would turn /private/tmp into /tmp).
        for path in paths where Self.isInteresting(path, root: root) {
            pending.insert(path)
        }
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        // Coalesce the several events one save produces (write, rename, attribute change).
        queue.asyncAfter(deadline: .now() + 0.12) { [self] in
            flushScheduled = false
            let paths = pending
            pending.removeAll()
            let ignoredNow = gitIgnored(paths)
            for path in paths.sorted() where !ignoredNow.contains(path) { process(path) }
        }
    }

    /// The paths among `paths` that the repository's .gitignore rules exclude. Asks git once
    /// per batch for paths it hasn't seen, and remembers the answers.
    private func gitIgnored(_ paths: Set<String>) -> Set<String> {
        guard let repoRoot else { return [] }
        let unknown = paths.filter { ignored[$0] == nil && $0.hasPrefix(repoRoot + "/") }
        if !unknown.isEmpty {
            let relatives = unknown.map { String($0.dropFirst(repoRoot.count + 1)) }
            var matched = Self.checkIgnore(relatives, in: repoRoot)
            if matched == nil {
                // One bad path (e.g. beyond a symlink) fails the whole batch: ask one at a time.
                matched = Set(relatives.prefix(200).flatMap { Self.checkIgnore([$0], in: repoRoot) ?? [] })
            }
            for path in unknown {
                ignored[path] = matched?.contains(String(path.dropFirst(repoRoot.count + 1))) ?? false
            }
        }
        return Set(paths.filter { ignored[$0] == true })
    }

    /// The ignored ones among `relatives`, or nil if git failed.
    private static func checkIgnore(_ relatives: [String], in repoRoot: String) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot] + AgentTools.gitGuards + ["check-ignore", "--stdin", "-z"]
        process.environment = AgentTools.gitEnvironment(in: repoRoot)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        input.fileHandleForWriting.write(Data((relatives.joined(separator: "\0") + "\0").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 0: some are ignored, 1: none are; anything else is an error.
        guard process.terminationStatus <= 1 else { return nil }
        return Set(data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isInteresting(_ path: String, root: String?) -> Bool {
        guard let root, path.hasPrefix(root) else { return false }
        let relative = path.dropFirst(root.count)
        for part in relative.split(separator: "/") {
            if skipped.contains(String(part)) { return false }
        }
        let name = (path as NSString).lastPathComponent
        // Editor swap/backup files and atomic-save temporaries.
        if name == ".DS_Store" || name.hasSuffix("~") || name.hasSuffix(".swp") || name.hasPrefix(".#") || name.hasPrefix(".!")
            || name.contains(".tmp.") || name.hasSuffix(".tmp") { return false }
        return true
    }

    private func process(_ path: String) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return }
        let current = exists ? Self.readText(path) : nil
        if exists && current == nil { return } // binary or too large
        let previous = shadow[path] ?? baselineContent(path)
        if let current { shadow[path] = current } else { shadow.removeValue(forKey: path) }
        guard previous != current else { return }

        let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let change: Change
        if let current {
            let created = previous == nil || previous == ""
            change = Change(path: path, hunks: Self.hunks(from: previous ?? "", to: current), created: created,
                            deleted: false, modified: modified)
        } else {
            change = Change(path: path, hunks: [], created: false, deleted: true, modified: modified)
        }
        DispatchQueue.main.async { self.onChange?(change) }
    }

    /// The file as of the baseline (the turn's snapshot or HEAD); "" if it didn't exist then,
    /// nil if unknown (not a git repository).
    private func baselineContent(_ path: String) -> String? {
        guard let repoRoot, path.hasPrefix(repoRoot + "/") else { return nil }
        let relative = String(path.dropFirst(repoRoot.count + 1))
        let result = AgentTools.git(["show", "\(baseline ?? "HEAD"):\(relative)"], in: repoRoot)
        return result.ok ? result.output : ""
    }

    private static func readText(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.size] as? Int ?? 0) <= maxSize,
              let data = FileManager.default.contents(atPath: path),
              !data.prefix(8000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Diffing

    /// Line hunks turning `old` into `new`.
    static func hunks(from old: String, to new: String) -> [Hunk] {
        let before = old.split(separator: "\n", omittingEmptySubsequences: false)
        let after = new.split(separator: "\n", omittingEmptySubsequences: false)
        // Very large rewrites: treat as one change rather than diffing line by line.
        guard before.count * after.count < 400_000_000 else {
            return [Hunk(start: 1, count: after.count, removed: [])]
        }
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if removedAt.contains(i) || insertedAt.contains(j) {
                var removed: [String] = []
                while i < before.count, removedAt.contains(i) { removed.append(String(before[i])); i += 1 }
                let start = j
                while j < after.count, insertedAt.contains(j) { j += 1 }
                hunks.append(Hunk(start: start + 1, count: j - start, removed: removed))
            } else {
                i += 1
                j += 1
            }
        }
        return hunks
    }

    // MARK: Catching up

    /// Everything that differs from the baseline right now, newest first: what the agent has
    /// done so far this turn. Also primes the last-seen contents, so later changes to these
    /// files diff against their current state.
    func catchUp(completion: @escaping ([Change]) -> Void) {
        queue.async { [self] in
            guard let repoRoot, let tree = ReviewInbox.snapshot(repoRoot) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let files = ReviewInbox.diff(from: baseline ?? "HEAD", to: tree, in: repoRoot)
            var changes: [Change] = []
            for file in files where !file.isBinary {
                let path = (repoRoot as NSString).appendingPathComponent(file.path)
                guard Self.isInteresting(path, root: repoRoot) else { continue }
                if let text = Self.readText(path) { shadow[path] = text }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970 ?? 0
                changes.append(Change(path: path, hunks: Self.hunks(of: file), created: file.status == .added,
                                      deleted: file.status == .deleted, modified: modified))
            }
            changes.sort { $0.modified > $1.modified }
            DispatchQueue.main.async { completion(changes) }
        }
    }

    /// A review diff's hunks in this watcher's form.
    private static func hunks(of file: ReviewFile) -> [Hunk] {
        var result: [Hunk] = []
        for hunk in file.hunks {
            var removed: [String] = []
            var start: Int?
            var count = 0
            var lastNew = 0
            func flush(nextLine: Int?) {
                if count > 0 || !removed.isEmpty {
                    result.append(Hunk(start: start ?? nextLine ?? 1, count: count, removed: removed))
                }
                removed = []
                start = nil
                count = 0
            }
            for line in hunk.lines {
                switch line.kind {
                case .removed:
                    if count > 0 { flush(nextLine: nil) }
                    removed.append(line.text)
                case .added:
                    if start == nil { start = line.newNumber }
                    count += 1
                    lastNew = line.newNumber ?? lastNew
                case .context:
                    flush(nextLine: line.newNumber)
                    lastNew = line.newNumber ?? lastNew
                }
            }
            flush(nextLine: lastNew + 1)
        }
        return result
    }
}
#endif
