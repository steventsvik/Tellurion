#if os(macOS)
import Foundation

/// Cleans up what a model answered and checks it has the shape a job needs. An answer is only
/// ever text: control characters are taken out, and it's never run or typed as a command.
enum SmallJobText {
    static let subjectLimit = 72
    static let commitLimit = 1500
    static let titleLimit = 60
    static let summaryLimit = 800

    // MARK: Cleaning

    /// Everything below, in the order answers need it.
    static func clean(_ raw: String) -> String {
        var text = plain(withoutReasoning(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
        text = withoutClosing(withoutPreamble(text))
        text = withoutPreamble(withoutFence(text))
        return unquoted(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Without control characters, terminal escape sequences or text-direction overrides. Keeps
    /// newlines and tabs.
    static func plain(_ text: String) -> String {
        let unescaped = text
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in unescaped.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x09:
                scalars.append(scalar)
            case 0x0D, 0x2028, 0x2029:
                scalars.append("\n")
            case 0x202A...0x202E, 0x2066...0x2069:
                continue
            default:
                if scalar.properties.generalCategory != .control { scalars.append(scalar) }
            }
        }
        return String(scalars)
    }

    /// Without the thinking a reasoning model writes before its answer: `<think>…</think>` and
    /// the like, also when only one of the two tags made it into the answer.
    static func withoutReasoning(_ text: String) -> String {
        let tags = "think|thinking|thought|reasoning"
        var text = text.replacingOccurrences(of: "(?is)<(\(tags))>.*?</\\1>", with: "", options: .regularExpression)
        // Only the closing tag: what's before it was the thinking.
        if let close = text.range(of: "(?i)</(\(tags))>", options: [.regularExpression, .backwards]) {
            text = String(text[close.upperBound...])
        }
        // Only the opening tag: it never got to the answer.
        if let open = text.range(of: "(?i)<(\(tags))>", options: .regularExpression) {
            text = String(text[..<open.lowerBound])
        }
        return text
    }

    /// Without a code fence around the whole answer. A fence anywhere else stays, and fails
    /// the checks.
    static func withoutFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.components(separatedBy: "```").count == 3 else { return text }
        var lines = trimmed.components(separatedBy: "\n")
        guard lines.count >= 3 else { return text }
        // The opening line may name a language.
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let interjection = "(?:sure|certainly|of course|okay|ok|absolutely)"
    private static let leadIn = "(?:here is|here's|here\u{2019}s|here are|below is|i suggest|i'd suggest|i would suggest)"
    private static let labels = "(?:commit message|suggested commit message|subject|title|summary|answer|category|label)"

    /// Without an introduction such as "Sure! Here is the commit message:" or a "Title:" label.
    static func withoutPreamble(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let whole = [
            "^\(interjection)[,!. ]*$",
            "^(?:\(interjection)[,!.]?\\s+)?\(leadIn)\\b.*:$",
            "^\\**\(labels)\\**\\s*:\\**$",
        ]
        // A line that's only an introduction, when the answer follows it.
        while lines.count > 1, let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.isEmpty || whole.contains(where: { matches(first, $0) }) {
            lines.removeFirst()
        }
        guard var first = lines.first else { return "" }
        // The introduction and the answer on one line.
        for pattern in ["^(?:\(interjection)[,!.]?\\s+)?\(leadIn)\\b[^:]{0,60}:\\s*(?=\\S)", "^\\**\(labels)\\**\\s*:\\**\\s*(?=\\S)"] {
            first = first.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        lines[0] = first
        return lines.joined(separator: "\n")
    }

    /// Without a last paragraph that talks about the answer instead of being part of it.
    static func withoutClosing(_ text: String) -> String {
        var paragraphs = text.components(separatedBy: "\n\n")
        guard paragraphs.count > 1, let last = paragraphs.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              matches(last, "^(?:let me know|i hope|feel free|hope this|this commit message|this message|this title|this summary)\\b.*")
        else { return text }
        paragraphs.removeLast()
        return paragraphs.joined(separator: "\n\n")
    }

    /// A one-line answer without the quotes, backticks or bold marks around it.
    static func unquoted(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        for (open, close) in [("\"", "\""), ("'", "'"), ("`", "`"), ("\u{201C}", "\u{201D}"), ("**", "**")]
        where text.count > open.count + close.count && text.hasPrefix(open) && text.hasSuffix(close) {
            let inner = String(text.dropFirst(open.count).dropLast(close.count))
            if !inner.contains(open) { return inner.trimmingCharacters(in: .whitespaces) }
        }
        return text
    }

    // MARK: Checks

    /// "I can't help with that" and the like, where the answer should be.
    static func isRefusal(_ text: String) -> Bool {
        let start = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").prefix(120)
        let openers = ["i can't", "i cannot", "i can not", "i won't", "i will not", "i'm sorry", "i am sorry", "sorry,",
                       "i'm unable", "i am unable", "i'm not able", "i am not able", "i apologize", "unfortunately, i",
                       "as a language model", "i don't have enough", "i do not have enough", "i need more"]
        return openers.contains { start.hasPrefix($0) }
    }

    /// The answer is the prompt handed back: it starts the way a part of the prompt starts, or
    /// is a long stretch of one.
    static func repeats(_ text: String, of parts: [String]) -> Bool {
        let answer = squeezed(text)
        guard answer.count >= 40 else { return false }
        for part in parts.map(squeezed) where part.count >= 40 {
            if answer.contains(part.prefix(80)) { return true }
            if answer.count >= 120, part.contains(answer) { return true }
        }
        return false
    }

    /// The usual checks for a kind of job, on the cleaned-up answer. `parts` is the prompt it
    /// was given; `choices` what a classification may answer.
    static func check(_ kind: SmallJob.Kind, _ raw: String, parts: [String] = [], choices: [String] = []) -> SmallJobCheck {
        let text = clean(raw)
        guard !text.isEmpty else { return .rejected("an empty answer") }
        if isRefusal(text) { return .rejected("it wouldn't answer") }
        if repeats(text, of: parts) { return .rejected("it repeated the prompt") }
        switch kind {
        case .commitMessage: return commitMessage(text)
        case .title: return title(text)
        case .summary: return summary(text)
        case .classify: return choice(text, among: choices)
        }
    }

    private static func commitMessage(_ text: String) -> SmallJobCheck {
        if text.contains("```") { return .rejected("a code fence in the answer") }
        var lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        let subject = lines[0]
        if ["#", "**", "- ", "* ", ">"].contains(where: subject.hasPrefix) { return .rejected("markdown where the subject line goes") }
        if subject.count > subjectLimit { return .rejected("a subject line over \(subjectLimit) characters") }
        if text.count > commitLimit { return .rejected("an answer that's too long") }
        // Git wants an empty line between the subject and the body.
        if lines.count > 1, !lines[1].isEmpty { lines.insert("", at: 1) }
        return .ok(lines.joined(separator: "\n"))
    }

    private static func title(_ text: String) -> SmallJobCheck {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1, var line = lines.first else { return .rejected("more than one line") }
        if line.contains("```") { return .rejected("a code fence in the answer") }
        if line.hasSuffix("."), !line.hasSuffix("..") { line.removeLast() }
        if line.count > titleLimit { return .rejected("a title over \(titleLimit) characters") }
        return .ok(line)
    }

    private static func summary(_ text: String) -> SmallJobCheck {
        if text.contains("```") { return .rejected("a code fence in the answer") }
        if text.count > summaryLimit { return .rejected("an answer that's too long") }
        return .ok(text)
    }

    /// The one choice the answer names: the answer itself, or the only one a short answer mentions.
    private static func choice(_ text: String, among choices: [String]) -> SmallJobCheck {
        let answer = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if let exact = choices.first(where: { $0.lowercased() == answer }) { return .ok(exact) }
        guard text.count <= 80 else { return .rejected("an answer that isn't one of the choices") }
        let named = choices.filter { matches(answer, ".*\\b\(NSRegularExpression.escapedPattern(for: $0.lowercased()))\\b.*") }
        return named.count == 1 ? .ok(named[0]) : .rejected("an answer that isn't one of the choices")
    }

    // MARK: Helpers

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Lowercased, with every run of whitespace as one space.
    private static func squeezed(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
#endif
