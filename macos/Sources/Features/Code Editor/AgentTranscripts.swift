#if os(macOS)
import Foundation

/// Finds an agent's session transcript on disk from the folder it runs in.
///
/// The agent hooks normally tell the app where the transcript is, but that signal can go
/// missing (it's only sent when a session starts or a prompt is submitted, and the app may
/// not receive it). Without it the editor has nothing to follow, so it looks it up instead.
enum AgentTranscripts {
    /// The transcript most recently written in `folder` by this kind of agent, if it was
    /// written within `recent` seconds.
    static func find(kind: VerticalTabAgentKind, folder: String, recent: TimeInterval = 15 * 60) -> String? {
        switch kind {
        case .claude: return newest(in: claudeProjectDir(for: folder), recent: recent)
        case .codex: return codex(folder: folder, recent: recent)
        default: return nil
        }
    }

    /// When the agent is working but `path` has gone quiet, a newer transcript in the same
    /// place (after `/clear` or a resumed session, say) is probably the live one.
    static func newer(than path: String, kind: VerticalTabAgentKind, folder: String) -> String? {
        guard let found = find(kind: kind, folder: folder, recent: 120), found != path else { return nil }
        return modified(found) > modified(path) + 5 ? found : nil
    }

    /// Claude Code keeps a folder per project: the path with every character that isn't a
    /// letter or digit replaced by "-".
    private static func claudeProjectDir(for folder: String) -> String {
        let name = String(folder.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
        return NSHomeDirectory() + "/.claude/projects/" + name
    }

    private static func newest(in dir: String, recent: TimeInterval) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let best = names.filter { $0.hasSuffix(".jsonl") }
            .map { dir + "/" + $0 }
            .max { modified($0) < modified($1) }
        guard let best, Date().timeIntervalSince1970 - modified(best) < recent else { return nil }
        return best
    }

    /// Codex files sessions by date (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`); the
    /// first line names the folder the session runs in.
    private static func codex(folder: String, recent: TimeInterval) -> String? {
        let root = NSHomeDirectory() + "/.codex/sessions"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let days = [Date(), Date().addingTimeInterval(-86400)].map { root + "/" + formatter.string(from: $0) }
        let now = Date().timeIntervalSince1970
        let candidates = days.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
        }
        .filter { now - modified($0) < recent }
        .sorted { modified($0) > modified($1) }
        let target = (folder as NSString).standardizingPath.lowercased()
        return candidates.first { path in
            guard let cwd = codexFolder(path) else { return false }
            return (cwd as NSString).standardizingPath.lowercased() == target
        }
    }

    private static func codexFolder(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
        guard let line = data.split(separator: 0x0A).first,
              let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    private static func modified(_ path: String) -> TimeInterval {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return date?.timeIntervalSince1970 ?? 0
    }
}
/// An agent's transcript: the one its hooks reported, or else found on disk. Also moves to a
/// newer one when the reported transcript goes quiet while the agent works. One per agent
/// being followed, since it remembers what it found.
final class AgentTranscriptLookup {
    private var lastLookup = Date.distantPast
    private var found: String?
    /// The reported transcript `found` was looked up against: one found before the hooks
    /// reported theirs doesn't outrank the report.
    private var foundAgainst: String?

    func reset() { found = nil }

    func transcript(for info: VerticalTabAgentInfo, in folder: String?) -> String? {
        if info.kind == .codex, let id = info.codexSessionID {
            if let reported = info.transcriptPath, CodexTracking.metadata(reported)?.id == id { return reported }
            if let found, CodexTracking.metadata(found)?.id == id { return found }
            if Date().timeIntervalSince(lastLookup) > 3 {
                lastLookup = Date()
                found = CodexTracking.transcript(session: id)
            }
            return found.flatMap { CodexTracking.metadata($0)?.id == id ? $0 : nil }
        }
        let reported = info.transcriptPath
        guard let folder, info.kind == .claude || info.kind == .codex else { return reported }
        if found != nil, foundAgainst != reported { found = nil }
        let quiet = reported.map { !Self.recentlyModified($0, within: 20) } ?? true
        if reported == nil || (quiet && info.activity == .working), Date().timeIntervalSince(lastLookup) > 3 {
            lastLookup = Date()
            foundAgainst = reported
            if let reported {
                found = AgentTranscripts.newer(than: reported, kind: info.kind, folder: folder)
            } else {
                found = AgentTranscripts.find(kind: info.kind, folder: folder)
            }
        }
        return found ?? reported
    }

    private static func recentlyModified(_ path: String, within seconds: TimeInterval) -> Bool {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return date.map { Date().timeIntervalSince($0) < seconds } ?? false
    }
}
#endif
