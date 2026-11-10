#if os(macOS)
import Foundation

/// Codex stores children alongside other date-filed rollouts, linked by thread identity.
/// Folder equality alone is deliberately not used to bind a known Codex session.
enum CodexTracking {
    struct Session {
        let id: String
        let parent: String?
        let path: String
        let label: String
        let historyStart: Int?
    }

    static var root: String { NSHomeDirectory() + "/.codex/sessions" }
    static var hooksRoot: String { AgentTools.root.appendingPathComponent("codex-tracking").path }

    static func hookPath(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 100,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return hooksRoot + "/" + id + ".jsonl"
    }

    static func metadata(_ path: String) -> Session? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65536)) ?? Data()
        guard let line = data.split(separator: 0x0A).first,
              let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any],
              let id = payload["id"] as? String else { return nil }
        return metadata(payload, path: path, id: id)
    }

    static func metadata(_ payload: [String: Any], path: String, id: String) -> Session {
        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let parent = payload["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
        let agentPath = payload["agent_path"] as? String ?? spawn?["agent_path"] as? String
        let nickname = payload["agent_nickname"] as? String ?? spawn?["agent_nickname"] as? String
        let label = agentPath.map { ($0 as NSString).lastPathComponent } ?? nickname ?? "Codex \(id.prefix(8))"
        return Session(id: id, parent: parent, path: path, label: label,
                       historyStart: payload["subagent_history_start_ordinal"] as? Int)
    }

    /// The hook journal includes the exact transcript, even when the OSC path would be
    /// too long. A known id never falls back to a different session sharing its cwd.
    static func reportedTranscript(session id: String) -> String? {
        guard hookPath(id) != nil else { return nil }
        if let data = FileManager.default.contents(atPath: hooksRoot + "/" + id + ".json"),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = manifest["transcript"] as? String, metadata(path)?.id == id { return path }
        return nil
    }

    static func transcript(session id: String) -> String? {
        guard hookPath(id) != nil else { return nil }
        if let path = reportedTranscript(session: id) { return path }
        if let journal = hookPath(id), let handle = FileHandle(forReadingAtPath: journal) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 131072 ? size - 131072 : 0)
            for line in handle.readDataToEndOfFile().split(separator: 0x0A).reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any],
                      let path = payload["transcript_path"] as? String,
                      let meta = metadata(path), meta.id == id else { continue }
                return path
            }
        }
        // Resumed rollouts may be filed under an older day. Search filenames for this id
        // only; no content from unrelated transcripts is read.
        guard hookPath(id) != nil,
              let walker = FileManager.default.enumerator(atPath: root) else { return nil }
        for case let relative as String in walker where relative.hasSuffix("-\(id).jsonl") {
            let path = root + "/" + relative
            if metadata(path)?.id == id { return path }
        }
        return nil
    }

    static func children(of session: Session, cached: inout [String: Session]) -> [Session] {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        var directories: Set<String> = [(session.path as NSString).deletingLastPathComponent]
        for offset in 0...2 {
            directories.insert(root + "/" + formatter.string(from: Date().addingTimeInterval(Double(-offset * 86400))))
        }
        for dir in directories {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                if cached[path] == nil, let meta = metadata(path) { cached[path] = meta }
            }
        }
        var family: Set<String> = [session.id]
        var children: [Session] = []
        var changed = true
        while changed {
            changed = false
            for child in cached.values where !family.contains(child.id) {
                guard let parent = child.parent, family.contains(parent) else { continue }
                family.insert(child.id)
                children.append(child)
                changed = true
            }
        }
        return children.sorted { $0.id < $1.id }
    }
}
#endif
