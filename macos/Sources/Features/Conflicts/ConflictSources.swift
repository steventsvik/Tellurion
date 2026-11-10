#if os(macOS)
import Foundation

/// Where the conflict radar learns which files an agent changed.
///
/// The agents' status events come first: a finished Edit or Write names its file
/// ("Edit: src/app.ts"). The hooks cut that text at 48 characters, and a patch names no file
/// at all, so when the event doesn't say where, the files are read from the end of the
/// session's own record instead: Claude Code's transcript (and the feeds the other agents'
/// hooks write in the same format), or the journal Codex's hook keeps.
enum ConflictSources {
    /// A file an agent changed, as it was reported: maybe relative, maybe to a folder the
    /// report names.
    struct Edit: Equatable {
        let path: String
        /// The folder a relative path is relative to, when the report says.
        var folder: String?
        var date: Date?
    }

    /// What one status event says about a file change.
    enum EventEdit: Equatable {
        /// Not a file change.
        case none
        /// A change to this file.
        case file(String)
        /// A change, but the event doesn't say where: the path was cut short, or the tool
        /// takes a patch.
        case unknown
    }

    /// The hooks cut an event's detail at this many characters.
    static let detailLimit = 48

    // MARK: Tools

    /// Whether a tool with this name changes files: Claude Code's Edit, Write, MultiEdit and
    /// NotebookEdit, Codex's apply_patch, and the other agents' own names for the same things.
    static func isEditTool(_ name: String) -> Bool {
        var tool = name.lowercased()
        // "functions.apply_patch", "mcp__files__write_file"
        if let dot = tool.lastIndex(of: ".") { tool = String(tool[tool.index(after: dot)...]) }
        if let range = tool.range(of: "__", options: .backwards) { tool = String(tool[range.upperBound...]) }
        guard !tool.isEmpty else { return false }
        // TodoWrite, update_plan, write_stdin and memory tools write no project files.
        for word in ["todo", "plan", "stdin", "memory", "read"] where tool.contains(word) { return false }
        if ["create", "create_file", "createfile"].contains(tool) { return true }
        return ["edit", "write", "patch", "replace"].contains { tool.contains($0) }
    }

    /// Whether the tool is given a patch (which names its files inside) rather than one path.
    static func takesPatch(_ name: String) -> Bool {
        name.lowercased().contains("patch")
    }

    // MARK: Events

    /// What a status event says was changed. Only a finished tool counts: one that's still
    /// waiting for permission hasn't changed anything.
    static func edit(inEvent event: String, detail: String?) -> EventEdit {
        guard event == "tool_complete", let detail, !detail.isEmpty else { return .none }
        let tool: String
        let argument: String
        if let split = detail.range(of: ": ") {
            tool = String(detail[..<split.lowerBound])
            argument = String(detail[split.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            tool = detail.hasSuffix(":") ? String(detail.dropLast()) : detail
            argument = ""
        }
        guard isEditTool(tool) else { return .none }
        if argument.isEmpty || takesPatch(tool) || argument.hasPrefix("*** ") { return .unknown }
        // Cut short by the hook: with an ellipsis (Claude Code's) or without (the others').
        if detail.hasSuffix("…") || detail.count >= detailLimit { return .unknown }
        return .file(argument)
    }

    // MARK: Session records

    /// The whole lines at the start of `data`, each decoded as a JSON object, and how many
    /// bytes they took. A last line that's still being written isn't read.
    static func records(in data: Data) -> (records: [[String: Any]], consumed: Int) {
        guard let end = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let whole = data[data.startIndex...end]
        var records: [[String: Any]] = []
        for line in whole.split(separator: 0x0A) {
            if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { records.append(record) }
        }
        return (records, whole.count)
    }

    private static let pathKeys = ["file_path", "filePath", "notebook_path", "absolute_path", "target_file", "path", "file"]

    private static func path(in input: [String: Any]) -> String? {
        for key in pathKeys {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The files a transcript record changed, in Claude Code's format:
    /// `{"type":"assistant","cwd":…,"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":…}}]}}`.
    static func claudeEdits(in record: [String: Any]) -> [Edit] {
        guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any] else { return [] }
        let folder = record["cwd"] as? String
        let date = (record["timestamp"] as? String).flatMap(Self.date)
        var edits: [Edit] = []
        for part in message["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "tool_use" {
            guard let name = part["name"] as? String, isEditTool(name) else { continue }
            let input = part["input"] as? [String: Any] ?? [:]
            if let path = path(in: input) {
                edits.append(Edit(path: path, folder: folder, date: date))
            } else if let patch = (input["command"] ?? input["patch"] ?? input["input"]) as? String {
                edits += patchPaths(patch).map { Edit(path: $0, folder: folder, date: date) }
            }
        }
        return edits
    }

    /// The files a record in Codex's hook journal changed:
    /// `{"event":"tool_complete","timestamp":…,"payload":{"tool_name":"apply_patch","cwd":…,"tool_input":{"command":"*** Begin Patch…"}}}`.
    static func codexEdits(in record: [String: Any]) -> [Edit] {
        guard record["event"] as? String == "tool_complete", let payload = record["payload"] as? [String: Any] else { return [] }
        let name = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let folder = input["workdir"] as? String ?? input["cwd"] as? String ?? payload["cwd"] as? String
        let date = (record["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        // A patch is a patch whichever tool carried it (Codex also sends them through its shell).
        let text = payload["tool_input"] as? String
            ?? (input["command"] ?? input["cmd"] ?? input["input"] ?? input["patch"]) as? String
            ?? (input["command"] as? [String])?.joined(separator: "\n")
        if let text, text.contains("*** Begin Patch") {
            return patchPaths(text).map { Edit(path: $0, folder: folder, date: date) }
        }
        guard isEditTool(name), let path = path(in: input) else { return [] }
        return [Edit(path: path, folder: folder, date: date)]
    }

    /// The files a patch in Codex's format changes, adds, deletes or moves to.
    static func patchPaths(_ patch: String) -> [String] {
        var paths: [String] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    private static let preciseDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDates = ISO8601DateFormatter()

    /// A transcript's timestamp, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        preciseDates.date(from: text) ?? plainDates.date(from: text)
    }
}
#endif
