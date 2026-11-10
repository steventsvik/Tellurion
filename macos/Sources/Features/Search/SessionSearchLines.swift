#if os(macOS)
import Foundation

/// What a line of a transcript is, as far as searching goes.
enum SearchLineKind: String, CaseIterable, Identifiable, Codable {
    /// Something you typed.
    case prompt
    /// What the agent wrote, its reasoning included.
    case agent
    /// A command the agent ran.
    case command
    /// A file the agent edited, by its path.
    case edit
    /// Everything else: what tools printed, what an edit put in a file, other tool calls
    /// and lines of a shape this doesn't know. Large and noisy, so it's off to start with.
    case output

    var id: String { rawValue }

    /// The label on a snippet.
    var label: String {
        switch self {
        case .prompt: return "You"
        case .agent: return "Agent"
        case .command: return "Ran"
        case .edit: return "Edited"
        case .output: return "Output"
        }
    }

    /// Its name among the things to search.
    var title: String {
        switch self {
        case .prompt: return "Prompts"
        case .agent: return "Agent messages"
        case .command: return "Commands"
        case .edit: return "Edited files"
        case .output: return "Tool output"
        }
    }

    /// What's searched until you say otherwise.
    static let standard: Set<SearchLineKind> = [.prompt, .agent, .command, .edit]
}

/// One searchable piece of a transcript line. A line can hold several: an agent's message
/// and the command it ran, say.
struct SearchSegment: Equatable {
    let kind: SearchLineKind
    let text: String
    /// The files it's about, for `file:`.
    var paths: [String] = []
}

/// Takes one line of a Claude Code or Codex transcript apart into what can be searched.
enum SessionLineParser {
    /// Longer lines than this aren't decoded; they're searched as they are, as tool output.
    static let lineLimit = 8 << 20

    /// The pieces of `line` among `wanted`. A line that isn't JSON, or isn't a shape known
    /// here, is one piece of tool output: its own text.
    static func segments(of line: UnsafeBufferPointer<UInt8>, agent: String, wanted: Set<SearchLineKind>) -> [SearchSegment] {
        var known: [SearchSegment]?
        if line.count <= lineLimit,
           let record = try? JSONSerialization.jsonObject(with: Data(buffer: line)) as? [String: Any] {
            known = agent == "codex" ? codex(record) : claude(record)
        }
        if let known { return known.filter { wanted.contains($0.kind) && !$0.text.isEmpty } }
        guard wanted.contains(.output) else { return [] }
        return [SearchSegment(kind: .output, text: String(decoding: line, as: UTF8.self))]
    }

    // MARK: Claude Code

    /// {"type":"user","message":{"content":"…" or [{"type":"text"…},{"type":"tool_result"…}]}}
    /// {"type":"assistant","message":{"content":[{"type":"text"|"thinking"|"tool_use"…}]}}
    static func claude(_ record: [String: Any]) -> [SearchSegment]? {
        let type = record["type"] as? String
        guard type == "user" || type == "assistant", let message = record["message"] as? [String: Any] else { return nil }
        let parts = message["content"] as? [[String: Any]] ?? []
        var found: [SearchSegment] = []
        if type == "user" {
            // A sub-agent's "user" is the agent that started it.
            let typed: SearchLineKind = record["isSidechain"] as? Bool == true ? .agent
                : record["isMeta"] as? Bool == true ? .output : .prompt
            if let text = message["content"] as? String { found.append(said(text, as: typed)) }
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    if let text = part["text"] as? String { found.append(said(text, as: typed)) }
                case "tool_result":
                    found.append(SearchSegment(kind: .output, text: flatten(part["content"])))
                default:
                    break
                }
            }
            return found
        }
        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String { found.append(SearchSegment(kind: .agent, text: text)) }
            case "thinking":
                if let text = part["thinking"] as? String { found.append(SearchSegment(kind: .agent, text: text)) }
            case "tool_use":
                found += claudeTool(part["name"] as? String ?? "", part["input"] as? [String: Any] ?? [:])
            default:
                break
            }
        }
        return found
    }

    private static func claudeTool(_ name: String, _ input: [String: Any]) -> [SearchSegment] {
        if name == "Bash", let command = input["command"] as? String {
            return [SearchSegment(kind: .command, text: command)]
        }
        let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
        let paths = path.map { [$0] } ?? []
        if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(name), let path {
            let body = strings(in: input.filter { $0.key != "file_path" && $0.key != "notebook_path" })
            return [SearchSegment(kind: .edit, text: path, paths: paths),
                    SearchSegment(kind: .output, text: body.joined(separator: "\n"), paths: paths)]
        }
        return [SearchSegment(kind: .output, text: ([name] + strings(in: input)).joined(separator: " "), paths: paths)]
    }

    // MARK: Codex

    /// {"type":"event_msg","payload":{"type":"user_message"|"agent_message"|"agent_reasoning"…}}
    /// {"type":"response_item","payload":{"type":"message"|"reasoning"|"function_call"|
    ///   "custom_tool_call"|"local_shell_call"|"function_call_output"|"custom_tool_call_output"…}}
    static func codex(_ record: [String: Any]) -> [SearchSegment]? {
        guard let payload = record["payload"] as? [String: Any] else { return nil }
        let kind = payload["type"] as? String
        switch record["type"] as? String {
        case "event_msg":
            switch kind {
            case "user_message":
                return (payload["message"] as? String).map { [said($0, as: .prompt)] }
            case "agent_message":
                return (payload["message"] as? String).map { [SearchSegment(kind: .agent, text: $0)] }
            case "agent_reasoning":
                return (payload["text"] as? String).map { [SearchSegment(kind: .agent, text: $0)] }
            default:
                return nil
            }
        case "response_item":
            switch kind {
            case "message":
                let text = texts(payload["content"])
                switch payload["role"] as? String {
                case "user": return [said(text, as: .prompt)]
                case "assistant": return [SearchSegment(kind: .agent, text: text)]
                default: return [SearchSegment(kind: .output, text: text)]
                }
            case "reasoning":
                return [SearchSegment(kind: .agent, text: texts(payload["summary"]))]
            case "function_call", "custom_tool_call", "local_shell_call":
                return codexTool(payload, shell: kind == "local_shell_call")
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                return [SearchSegment(kind: .output, text: flatten(payload["output"]))]
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static let shells: Set<String> = ["shell", "shell_command", "exec_command", "local_shell", "container.exec"]
    private static let patchMarkers = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]

    private static func codexTool(_ payload: [String: Any], shell: Bool) -> [SearchSegment] {
        let name = payload["name"] as? String ?? ""
        let body = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
        let arguments = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        if shell || shells.contains(name) {
            let action = payload["action"] as? [String: Any]
            let command = commandText(action?["command"] ?? arguments?["cmd"] ?? arguments?["command"]) ?? body
            return [SearchSegment(kind: .command, text: command)] + patch(command)
        }
        if name == "apply_patch" || body.contains("*** Begin Patch") {
            // The patch as text, whether it came by itself or inside the call's JSON.
            let text = arguments?["input"] as? String ?? arguments?["patch"] as? String
                ?? (arguments == nil && payload["arguments"] != nil ? body.replacingOccurrences(of: "\\n", with: "\n") : body)
            return patch(text)
        }
        // Code mode: the commands are calls inside a script.
        if name == "exec" { return [SearchSegment(kind: .command, text: body)] }
        return [SearchSegment(kind: .output, text: name + " " + body)]
    }

    /// A command as one line of text: Codex records it as a string, or as the arguments of
    /// a shell (`["bash", "-lc", "…"]`).
    private static func commandText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let words = value as? [String], !words.isEmpty else { return nil }
        if words.count == 3, ["bash", "zsh", "sh"].contains((words[0] as NSString).lastPathComponent), words[1].hasPrefix("-") {
            return words[2]
        }
        return words.joined(separator: " ")
    }

    /// The files a patch changes, each as an edit, and the patch itself as tool output.
    private static func patch(_ text: String) -> [SearchSegment] {
        guard text.contains("*** Begin Patch") else { return [] }
        var paths: [String] = []
        for line in text.split(separator: "\n") {
            for marker in patchMarkers where line.hasPrefix(marker) {
                let path = line.dropFirst(marker.count).trimmingCharacters(in: CharacterSet(charactersIn: "\"\\ \r"))
                if !path.isEmpty, !paths.contains(path) { paths.append(path) }
            }
        }
        return paths.map { SearchSegment(kind: .edit, text: $0, paths: [$0]) }
            + [SearchSegment(kind: .output, text: text, paths: paths)]
    }

    // MARK: Shared

    /// Something said in the user's place: a prompt, unless it's one of the notes the agent's
    /// own program writes there (they start with a tag) or the project's instructions.
    private static func said(_ text: String, as kind: SearchLineKind) -> SearchSegment {
        guard kind == .prompt else { return SearchSegment(kind: kind, text: text) }
        let start = text.drop { $0.isWhitespace }
        let note = start.hasPrefix("<") || start.hasPrefix("Caveat:") || start.hasPrefix("[Request interrupted")
            || start.hasPrefix("# AGENTS.md")
        return SearchSegment(kind: note ? .output : .prompt, text: text)
    }

    /// The text of a list of content parts ([{"text": "…"}]).
    private static func texts(_ value: Any?) -> String {
        (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A tool's result as text: a string, a list of text parts, or whatever strings it holds.
    private static func flatten(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]], parts.contains(where: { $0["text"] is String }) { return texts(parts) }
        return strings(in: value as Any).joined(separator: "\n")
    }

    /// Every string in a decoded JSON value, in a steady order.
    private static func strings(in value: Any, depth: Int = 0) -> [String] {
        if let text = value as? String { return [text] }
        guard depth < 6 else { return [] }
        if let list = value as? [Any] { return list.flatMap { strings(in: $0, depth: depth + 1) } }
        if let fields = value as? [String: Any] {
            return fields.keys.sorted().flatMap { strings(in: fields[$0] as Any, depth: depth + 1) }
        }
        return []
    }
}

/// A few words around a match, safe to show: what a transcript holds is text from anywhere.
struct SearchSnippet: Equatable, Identifiable {
    let id: Int
    let kind: SearchLineKind
    let text: String
    /// What to light up, as UTF-16 offsets into `text`.
    let highlights: [Range<Int>]

    /// `text` cut at the highlights, in order, for drawing.
    var pieces: [(text: String, lit: Bool)] {
        let whole = text as NSString
        var pieces: [(text: String, lit: Bool)] = []
        var at = 0
        for range in highlights where range.lowerBound >= at && range.upperBound <= whole.length {
            if range.lowerBound > at { pieces.append((whole.substring(with: NSRange(location: at, length: range.lowerBound - at)), false)) }
            pieces.append((whole.substring(with: NSRange(location: range.lowerBound, length: range.count)), true))
            at = range.upperBound
        }
        if at < whole.length { pieces.append((whole.substring(from: at), false)) }
        return pieces
    }
}

enum SearchSnippets {
    /// Bytes of the text kept before the first match, and in all.
    static let lead = 60
    static let length = 240

    private enum Shown { case keep, space, drop }

    /// How one character of untrusted text is shown: line breaks, tabs and other control
    /// characters become a space, and invisible formatting (the kind that reorders or hides
    /// text) is left out.
    private static func shown(_ scalar: Unicode.Scalar) -> Shown {
        if scalar.properties.isWhitespace { return .space }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return .space
        case .format:
            // Joiners hold emoji and some scripts together.
            return scalar.value == 0x200D || scalar.value == 0x200C ? .keep : .drop
        case .surrogate, .privateUse, .unassigned:
            return .drop
        default:
            return .keep
        }
    }

    /// `text` on one line without control characters, cut to `limit` characters.
    static func clean(_ text: String, limit: Int) -> String {
        var cleaned = String.UnicodeScalarView()
        var spaced = true
        var count = 0
        for scalar in text.unicodeScalars {
            // Counting scalars is close enough to characters for a cut-off, and never splits one.
            guard count < limit else {
                cleaned.append("…")
                break
            }
            switch shown(scalar) {
            case .drop:
                continue
            case .space:
                if !spaced {
                    cleaned.append(" ")
                    count += 1
                }
                spaced = true
            case .keep:
                cleaned.append(scalar)
                count += 1
                spaced = false
            }
        }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }

    /// The part of `text` around the first of `terms`, cleaned up, with every term in it
    /// marked. `text` is UTF-8; the cut never lands inside a character.
    static func excerpt(of text: UnsafeBufferPointer<UInt8>, terms: [[UInt8]], fold: Bool,
                        lead: Int = SearchSnippets.lead, length: Int = SearchSnippets.length) -> (text: String, highlights: [Range<Int>]) {
        let count = text.count
        let first = terms.compactMap { SearchBytes.find($0, in: text, from: 0, to: count, fold: fold) }.min() ?? 0
        var start = max(0, first - lead)
        while start < count, text[start] & 0xC0 == 0x80 { start += 1 }
        var end = min(count, start + max(length, 1))
        while end > start, end < count, text[end] & 0xC0 == 0x80 { end -= 1 }

        // The terms inside the cut, as byte ranges that don't overlap.
        var marks: [Range<Int>] = []
        // One the cut runs through is marked as far as it shows.
        for found in terms.flatMap({ SearchBytes.ranges(of: $0, in: text, from: start, to: min(count, end + $0.count), fold: fold) })
            .sorted(by: { $0.lowerBound < $1.lowerBound }) where found.lowerBound < end {
            let range = found.lowerBound..<min(found.upperBound, end)
            if let last = marks.last, range.lowerBound <= last.upperBound {
                marks[marks.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                marks.append(range)
            }
        }

        var cleaned = String.UnicodeScalarView()
        var units = 0
        if start > 0 {
            cleaned.append("…")
            units = 1
        }
        var highlights: [Range<Int>] = []
        var offset = start
        var mark = 0
        var open: Int?
        var spaced = true
        for scalar in String(decoding: UnsafeBufferPointer(rebasing: text[start..<end]), as: UTF8.self).unicodeScalars {
            if open == nil, mark < marks.count, offset >= marks[mark].lowerBound { open = units }
            switch shown(scalar) {
            case .drop:
                break
            case .space:
                if !spaced {
                    cleaned.append(" ")
                    units += 1
                }
                spaced = true
            case .keep:
                cleaned.append(scalar)
                units += UTF16.width(scalar)
                spaced = false
            }
            offset += UTF8.width(scalar)
            if let from = open, offset >= marks[mark].upperBound {
                if units > from { highlights.append(from..<units) }
                open = nil
                mark += 1
            }
        }
        if let from = open, units > from { highlights.append(from..<units) }
        if end < count { cleaned.append("…") }
        return (String(cleaned), highlights)
    }
}
#endif
