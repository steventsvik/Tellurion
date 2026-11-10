#if os(macOS)
import Foundation

/// One transcript file on disk, from its name and what the file system says about it.
struct SessionFileInfo: Equatable {
    let url: URL
    /// "claude" or "codex".
    let agent: String
    /// The session it belongs to, as far as its path tells: Claude Code names the file (or,
    /// for a sub-agent, the folder) after it. For Codex this is only the file's name.
    let session: String
    let subagent: Bool
    let modified: Date
    let size: Int
}

/// A session's transcripts: its own first, then its sub-agents'.
struct SessionFiles: Equatable {
    let agent: String
    var files: [SessionFileInfo]
    /// When any of them was last written.
    var modified: Date

    var main: SessionFileInfo { files[0] }
}

/// Where transcripts are kept.
struct SessionSearchRoots {
    var claude: URL?
    var codex: URL?

    /// The same folders the activity window reads (see `ActivityStats`).
    static var standard: SessionSearchRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SessionSearchRoots(claude: home.appendingPathComponent(".claude/projects"),
                                  codex: home.appendingPathComponent(".codex/sessions"))
    }

    /// Every session under the roots, newest first. Only looks at names, dates and sizes.
    func sessions() -> [SessionFiles] {
        var claudeFiles: [String: [SessionFileInfo]] = [:]
        var found: [SessionFiles] = []
        for (root, agent) in [(claude, "claude"), (codex, "codex")] {
            guard let root else { continue }
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                // Claude Code: <project>/<session>.jsonl, and its sub-agents' anywhere under
                // <project>/<session>/subagents/.
                let folders = Array(url.pathComponents.dropLast())
                let below = agent == "claude" ? folders.lastIndex(of: "subagents").flatMap { $0 >= 2 ? $0 : nil } : nil
                let session = below.map { folders[$0 - 1] } ?? url.deletingPathExtension().lastPathComponent
                let file = SessionFileInfo(url: url, agent: agent, session: session, subagent: below != nil,
                                           modified: modified, size: values.fileSize ?? 0)
                if agent == "claude" {
                    // A project's folder holds its sessions, so the folder is part of the key.
                    let project = below.map { folders[..<($0 - 1)] } ?? folders[...]
                    claudeFiles[project.joined(separator: "/") + "/" + session, default: []].append(file)
                } else {
                    found.append(SessionFiles(agent: agent, files: [file], modified: modified))
                }
            }
        }
        for files in claudeFiles.values {
            let ordered = files.sorted { a, b in a.subagent != b.subagent ? !a.subagent : a.url.path < b.url.path }
            found.append(SessionFiles(agent: "claude", files: ordered, modified: files.map(\.modified).max() ?? .distantPast))
        }
        return found.sorted { a, b in a.modified != b.modified ? a.modified > b.modified : a.main.url.path < b.main.url.path }
    }
}

/// What a result needs to know about a session without searching it: enough for its title
/// and to resume it.
struct SessionSearchMeta: Codable, Equatable {
    var agent: String
    var session: String
    var cwd: String?
    /// Its first prompt.
    var title: String?
    /// For Codex: the provider it ran on and its latest model, which it has to resume on.
    var codexProvider: String?
    var codexModel: String?

    /// Reads it from the start of the transcript (and, for Codex, the end, for the latest
    /// model). Never more than a few megabytes, however large the file.
    static func read(_ file: SessionFileInfo) -> SessionSearchMeta {
        let named = SessionSearchMeta(agent: file.agent, session: file.session)
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return named }
        defer { try? handle.close() }
        return autoreleasepool { named.reading(handle, file) }
    }

    private func reading(_ handle: FileHandle, _ file: SessionFileInfo) -> SessionSearchMeta {
        var meta = self
        let head = (try? handle.read(upToCount: Self.headBytes)) ?? Data()
        for line in head.split(separator: UInt8(ascii: "\n")).prefix(Self.headLines) {
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if file.agent == "codex" { meta.takeCodex(record) } else { meta.takeClaude(record) }
            if meta.cwd != nil, meta.title != nil, file.agent != "codex" || meta.codexModel != nil { break }
        }
        if file.agent == "codex", file.size > head.count {
            let tail = max(UInt64(head.count), UInt64(max(0, file.size - Self.tailBytes)))
            if (try? handle.seek(toOffset: tail)) != nil, let data = try? handle.readToEnd() {
                for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                    guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          record["type"] as? String == "turn_context",
                          let model = (record["payload"] as? [String: Any])?["model"] as? String, !model.isEmpty else { continue }
                    meta.codexModel = model
                    break
                }
            }
        }
        return meta
    }

    private static let headBytes = 2 << 20
    private static let headLines = 600
    private static let tailBytes = 512 << 10

    private mutating func takeClaude(_ record: [String: Any]) {
        if cwd == nil { cwd = record["cwd"] as? String }
        guard title == nil, record["type"] as? String == "user", record["isMeta"] as? Bool != true,
              record["isSidechain"] as? Bool != true, let message = record["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            title = Self.prompt(text)
        } else if let parts = message["content"] as? [[String: Any]],
                  !parts.contains(where: { $0["type"] as? String == "tool_result" }),
                  let text = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
            title = Self.prompt(text)
        }
    }

    private mutating func takeCodex(_ record: [String: Any]) {
        let payload = record["payload"] as? [String: Any] ?? [:]
        let kind = payload["type"] as? String
        switch record["type"] as? String {
        case "session_meta":
            if let id = payload["id"] as? String { session = id }
            cwd = payload["cwd"] as? String ?? cwd
            codexProvider = payload["model_provider"] as? String ?? codexProvider
        case "turn_context":
            if cwd == nil { cwd = payload["cwd"] as? String }
            if let model = payload["model"] as? String, !model.isEmpty { codexModel = model }
        case "event_msg" where kind == "user_message":
            if title == nil, let text = payload["message"] as? String { title = Self.prompt(text) }
        case "response_item" where kind == "message" && payload["role"] as? String == "user":
            guard title == nil else { return }
            let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            if let prompt = Self.prompt(text), !prompt.hasPrefix("# AGENTS.md") { title = prompt }
        default:
            break
        }
    }

    /// A real prompt, cleaned and cut short; nil for the notes an agent's own program writes
    /// in the user's place.
    private static func prompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:"),
              !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return SearchSnippets.clean(trimmed, limit: 200)
    }
}

/// Remembers each transcript's `SessionSearchMeta` by its path, size and date, so a second
/// search doesn't open files just to name them. Safe from any thread.
final class SessionMetaCache {
    private struct Entry: Codable {
        let size: Int
        let modified: Double
        let meta: SessionSearchMeta
    }

    private var entries: [String: Entry] = [:]
    private var dirty = false
    private let lock = NSLock()
    private let file: URL?
    private let limit: Int
    private let read: (SessionFileInfo) -> SessionSearchMeta

    /// `file`: where it's kept between launches (nil keeps it in memory only). `limit`: the
    /// most transcripts remembered; the oldest are forgotten first.
    init(file: URL?, limit: Int = 4000, read: @escaping (SessionFileInfo) -> SessionSearchMeta = SessionSearchMeta.read) {
        self.file = file
        self.limit = limit
        self.read = read
        if let file, let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func meta(for info: SessionFileInfo) -> SessionSearchMeta {
        let modified = info.modified.timeIntervalSinceReferenceDate
        lock.lock()
        let cached = entries[info.url.path]
        lock.unlock()
        if let cached, cached.size == info.size, abs(cached.modified - modified) < 0.001 { return cached.meta }
        let meta = read(info)
        lock.lock()
        entries[info.url.path] = Entry(size: info.size, modified: modified, meta: meta)
        dirty = true
        lock.unlock()
        return meta
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// What to write and where, if anything changed since the last time; nil when there's
    /// nothing to do. This is also when it's cut down to `limit`.
    func pendingSave() -> (data: Data, file: URL)? {
        lock.lock()
        defer { lock.unlock() }
        guard dirty, let file else { return nil }
        if entries.count > limit {
            let kept = entries.sorted { $0.value.modified > $1.value.modified }.prefix(limit)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return nil }
        dirty = false
        return (data, file)
    }
}

/// Filters that need no file to be opened, or only its first lines.
struct SessionSearchFilters: Equatable {
    /// "claude" or "codex"; nil for both.
    var agent: String?
    /// Sessions started in this folder or under it; nil for everywhere.
    var project: String?
    /// Sessions written to since then; nil for any time.
    var since: Date?
    var kinds: Set<SearchLineKind> = SearchLineKind.standard

    func includes(folder: String?) -> Bool {
        guard let project else { return true }
        guard let folder else { return false }
        let root = project.hasSuffix("/") ? project : project + "/"
        return folder + "/" == root || folder.hasPrefix(root)
    }
}

/// How much one search reads and keeps.
struct SessionSearchLimits: Equatable {
    /// The most of one file that's read: its latest part, when it's larger.
    var bytesPerFile = 64 << 20
    /// Snippets kept per session, and the matches after which a session isn't read further.
    var snippetsPerSession = 30
    var matchesPerSession = 200
    /// How much is skimmed between checks for a cancel.
    var block = 1 << 20
}

/// One session with matches.
struct SessionSearchResult: Identifiable, Equatable {
    let id: String
    let meta: SessionSearchMeta
    /// The session's own transcript.
    let transcript: URL
    let modified: Date
    var snippets: [SearchSnippet] = []
    var matches = 0
    /// It stopped counting at `matchesPerSession`.
    var more = false
}

/// The footer's numbers.
struct SessionSearchSummary: Equatable {
    /// Sessions looked through (those the filters let in).
    var sessions = 0
    var results = 0
    var matches = 0
    /// Files too large to read whole.
    var cutFiles = 0
    /// It stopped at the most results asked for; there may be more.
    var capped = false
    var cancelled = false
}

/// Stops a search. Safe from any thread.
final class SessionSearchToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Reads one transcript for matches without loading it: the file is mapped, skimmed for the
/// query's bytes, and only lines that have them are decoded.
enum SessionFileScanner {
    struct Outcome: Equatable {
        /// The file was larger than the limit, so only its latest part was read.
        var cut = false
        var cancelled = false
        /// Lines that were decoded.
        var decoded = 0
        var bytes = 0
    }

    /// `onMatch` gets each matching piece's kind and text (as UTF-8) and returns false to stop.
    static func scan(_ url: URL, agent: String, matcher: SearchMatcher, kinds: Set<SearchLineKind>,
                     limits: SessionSearchLimits = SessionSearchLimits(), isCancelled: () -> Bool,
                     onMatch: (SearchLineKind, UnsafeBufferPointer<UInt8>) -> Bool) -> Outcome {
        var outcome = Outcome()
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return outcome }
        let newline = UInt8(ascii: "\n")
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var position = 0
            if count > limits.bytesPerFile {
                outcome.cut = true
                position = count - limits.bytesPerFile
                // On to the next whole line.
                while position < count, bytes[position - 1] != newline { position += 1 }
            }
            outcome.bytes = count - position
            let anchor = matcher.prefilter.first
            while position < count {
                if isCancelled() {
                    outcome.cancelled = true
                    return
                }
                var blockEnd = min(count, position + max(limits.block, 1))
                while blockEnd < count, bytes[blockEnd] != newline { blockEnd += 1 }
                var cursor = position
                while cursor < blockEnd {
                    var lineStart = cursor
                    var lineEnd = cursor
                    if let anchor {
                        guard let hit = SearchBytes.find(anchor, in: bytes, from: cursor, to: blockEnd, fold: matcher.fold) else { break }
                        lineStart = hit
                        while lineStart > cursor, bytes[lineStart - 1] != newline { lineStart -= 1 }
                        lineEnd = hit + anchor.count
                    }
                    while lineEnd < blockEnd, bytes[lineEnd] != newline { lineEnd += 1 }
                    cursor = lineEnd + 1
                    let line = UnsafeBufferPointer(rebasing: bytes[lineStart..<lineEnd])
                    guard !line.isEmpty, matcher.mayMatch(line, skipFirst: anchor != nil) else { continue }
                    if isCancelled() {
                        outcome.cancelled = true
                        return
                    }
                    outcome.decoded += 1
                    // Decoding leaves a lot behind; let go of it line by line.
                    let goOn = autoreleasepool { () -> Bool in
                        for segment in SessionLineParser.segments(of: line, agent: agent, wanted: kinds) {
                            var text = segment.text
                            let goOn = text.withUTF8 { utf8 -> Bool in
                                guard matcher.matches(text: utf8, paths: segment.paths,
                                                      pathsInText: segment.kind == .command || segment.kind == .edit) else { return true }
                                return onMatch(segment.kind, utf8)
                            }
                            if !goOn { return false }
                        }
                        return true
                    }
                    if !goOn { return }
                }
                position = blockEnd + 1
            }
        }
        return outcome
    }
}

/// Searches every session: a scan, newest session first, a few files at a time. Nothing is
/// indexed and nothing leaves this Mac.
enum SessionSearchEngine {
    struct Request {
        var query: SessionSearchQuery
        var filters = SessionSearchFilters()
        /// The most sessions to return.
        var limit = 200
    }

    /// Runs a search to the end (or to `token`'s cancel) on the calling thread and a few
    /// others; call off the main thread. `onResult` gets each session with matches, newest
    /// first, and `onProgress` the running numbers; both are called from background threads,
    /// one at a time.
    @discardableResult
    static func search(_ request: Request, roots: SessionSearchRoots, cache: SessionMetaCache,
                       limits: SessionSearchLimits = SessionSearchLimits(), workers: Int = 4,
                       token: SessionSearchToken = SessionSearchToken(),
                       onProgress: ((SessionSearchSummary) -> Void)? = nil,
                       onResult: @escaping (SessionSearchResult) -> Void) -> SessionSearchSummary {
        var summary = SessionSearchSummary()
        guard !request.query.isEmpty, !request.filters.kinds.isEmpty, request.limit > 0 else { return summary }
        let filters = request.filters
        let sessions = roots.sessions().filter { session in
            (filters.agent == nil || filters.agent == session.agent) && (filters.since.map { session.modified >= $0 } ?? true)
        }
        let matcher = SearchMatcher(request.query)

        // Sessions are read a few at a time but handed on in order, so the newest come first
        // and the same search always stops at the same place.
        let lock = NSLock()
        var next = 0
        var frontier = 0
        var finished: [Int: Scanned] = [:]
        var stop = false
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, sessions.count))) { _ in
            while true {
                lock.lock()
                guard !stop, next < sessions.count else {
                    lock.unlock()
                    return
                }
                let index = next
                next += 1
                lock.unlock()

                let scanned = scan(sessions[index], matcher: matcher, filters: filters, cache: cache, limits: limits, token: token)

                lock.lock()
                finished[index] = scanned
                while !stop, let ready = finished.removeValue(forKey: frontier) {
                    frontier += 1
                    if ready.cancelled {
                        stop = true
                        summary.cancelled = true
                        break
                    }
                    if ready.searched { summary.sessions += 1 }
                    summary.cutFiles += ready.cutFiles
                    if let result = ready.result {
                        summary.results += 1
                        summary.matches += result.matches
                        onResult(result)
                        if summary.results >= request.limit {
                            stop = true
                            summary.capped = frontier < sessions.count
                        }
                    }
                }
                onProgress?(summary)
                lock.unlock()
            }
        }
        if token.isCancelled { summary.cancelled = true }
        return summary
    }

    /// The same, collected: every result, newest first.
    static func results(_ request: Request, roots: SessionSearchRoots, cache: SessionMetaCache,
                        limits: SessionSearchLimits = SessionSearchLimits(), workers: Int = 4,
                        token: SessionSearchToken = SessionSearchToken()) -> (results: [SessionSearchResult], summary: SessionSearchSummary) {
        var found: [SessionSearchResult] = []
        let summary = search(request, roots: roots, cache: cache, limits: limits, workers: workers, token: token) { found.append($0) }
        return (found, summary)
    }

    /// The folders sessions were started in, most recent first, each once.
    static func folders(roots: SessionSearchRoots, cache: SessionMetaCache) -> [String] {
        var seen: Set<String> = []
        return roots.sessions().compactMap { cache.meta(for: $0.main).cwd }.filter { seen.insert($0).inserted }
    }

    private struct Scanned {
        var result: SessionSearchResult?
        /// The filters let it in.
        var searched = false
        var cutFiles = 0
        var cancelled = false
    }

    private static func scan(_ session: SessionFiles, matcher: SearchMatcher, filters: SessionSearchFilters,
                             cache: SessionMetaCache, limits: SessionSearchLimits, token: SessionSearchToken) -> Scanned {
        var scanned = Scanned()
        guard !token.isCancelled else {
            scanned.cancelled = true
            return scanned
        }
        let meta = cache.meta(for: session.main)
        guard filters.includes(folder: meta.cwd) else { return scanned }
        scanned.searched = true
        var result = SessionSearchResult(id: session.agent + ":" + session.main.url.path, meta: meta,
                                         transcript: session.main.url, modified: session.modified)
        // The same words are often recorded twice (as an event and as a message).
        var seen: Set<Int> = []
        for file in session.files where !result.more {
            let outcome = SessionFileScanner.scan(file.url, agent: file.agent, matcher: matcher, kinds: filters.kinds, limits: limits,
                                                  isCancelled: { token.isCancelled }, onMatch: { kind, text in
                var hasher = Hasher()
                hasher.combine(kind)
                hasher.combine(bytes: UnsafeRawBufferPointer(trimmed(text)))
                guard seen.insert(hasher.finalize()).inserted else { return true }
                result.matches += 1
                if result.snippets.count < limits.snippetsPerSession {
                    let excerpt = SearchSnippets.excerpt(of: text, terms: matcher.highlighted, fold: matcher.fold)
                    result.snippets.append(SearchSnippet(id: result.matches, kind: kind, text: excerpt.text, highlights: excerpt.highlights))
                }
                result.more = result.matches >= limits.matchesPerSession
                return !result.more
            })
            if outcome.cut { scanned.cutFiles += 1 }
            if outcome.cancelled {
                scanned.cancelled = true
                return scanned
            }
        }
        if result.matches > 0 { scanned.result = result }
        return scanned
    }

    /// `text` without the ASCII space around it.
    private static func trimmed(_ text: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var start = 0
        var end = text.count
        while start < end, text[start] <= 0x20 { start += 1 }
        while end > start, text[end - 1] <= 0x20 { end -= 1 }
        return UnsafeBufferPointer(rebasing: text[start..<end])
    }
}
#endif
