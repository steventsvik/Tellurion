#if os(macOS)
import Foundation

/// Finding bytes in bytes: how the search skims a transcript before decoding any of it.
enum SearchBytes {
    /// `text` as the bytes to look for, with ASCII letters lowercased when `fold`.
    static func needle(_ text: String, fold: Bool) -> [UInt8] {
        fold ? text.utf8.map { $0 >= 65 && $0 <= 90 ? $0 | 0x20 : $0 } : Array(text.utf8)
    }

    /// The first place `needle` is in `hay[from..<to]`. With `fold`, ASCII letters match in
    /// either case, and `needle` must already be lowercased (see `needle(_:fold:)`).
    static func find(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, from: Int, to: Int, fold: Bool) -> Int? {
        let count = needle.count
        guard count > 0, from >= 0, to <= hay.count, to - from >= count, let base = hay.baseAddress else { return nil }
        return needle.withUnsafeBufferPointer { wanted -> Int? in
            if !fold {
                guard let found = memmem(base + from, to - from, wanted.baseAddress, count) else { return nil }
                return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
            }
            let first = wanted[0]
            let other = first >= 97 && first <= 122 ? first - 32 : first
            let last = to - count
            var index = from
            while index <= last {
                let byte = hay[index]
                if byte == first || byte == other {
                    var offset = 1
                    while offset < count {
                        var next = hay[index + offset]
                        if next >= 65 && next <= 90 { next |= 0x20 }
                        if next != wanted[offset] { break }
                        offset += 1
                    }
                    if offset == count { return index }
                }
                index += 1
            }
            return nil
        }
    }

    /// Every place `needle` is in `hay[from..<to]`, not overlapping.
    static func ranges(of needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, from: Int, to: Int, fold: Bool) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start = from
        while let at = find(needle, in: hay, from: start, to: to, fold: fold) {
            found.append(at..<(at + needle.count))
            start = at + needle.count
        }
        return found
    }

    static func contains(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, fold: Bool) -> Bool {
        find(needle, in: hay, from: 0, to: hay.count, fold: fold) != nil
    }
}

/// What was typed into the search box, taken apart.
///
/// Words must all be on the same line. `"quoted words"` are one phrase, a leading `-`
/// leaves lines with that word out, and `file:name` keeps to lines about that path. An
/// all-lowercase search ignores case; one capital letter makes it exact.
struct SessionSearchQuery: Equatable {
    /// Words and phrases a line must all have.
    var words: [String] = []
    /// Words and phrases a line must not have.
    var excluded: [String] = []
    /// Parts of a path a line must be about.
    var files: [String] = []
    /// Parts of a path a line must not be about.
    var excludedFiles: [String] = []
    var caseSensitive = false

    /// Nothing to look for: exclusions alone don't make a search.
    var isEmpty: Bool { words.isEmpty && files.isEmpty }

    /// The longest a single word or phrase is read, and how many of them.
    static let termLimit = 200
    static let termCount = 16

    init() {}

    init(_ text: String) {
        let characters = Array(text)
        var index = 0
        var count = 0
        while index < characters.count, count < Self.termCount {
            guard !characters[index].isWhitespace else {
                index += 1
                continue
            }
            var negated = false
            var file = false
            if characters[index] == "-", index + 1 < characters.count, !characters[index + 1].isWhitespace {
                negated = true
                index += 1
            }
            if characters[index...].starts(with: Array("file:")) {
                file = true
                index += 5
            }
            var value = ""
            if index < characters.count, characters[index] == "\"" {
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    value.append(characters[index])
                    index += 1
                }
                index += 1
            } else {
                while index < characters.count, !characters[index].isWhitespace {
                    value.append(characters[index])
                    index += 1
                }
            }
            let term = Self.tidy(value)
            guard !term.isEmpty else { continue }
            count += 1
            switch (file, negated) {
            case (false, false): words.append(term)
            case (false, true): excluded.append(term)
            case (true, false): files.append(term)
            case (true, true): excludedFiles.append(term)
            }
        }
        caseSensitive = (words + excluded + files + excludedFiles).contains { $0.contains(where: \.isUppercase) }
    }

    /// A term without control characters or space around it, cut to `termLimit`.
    private static func tidy(_ value: String) -> String {
        let plain = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }))
        return String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(termLimit))
    }
}

/// A query made ready for scanning: its terms as bytes, and what a line's raw bytes must
/// contain before it's worth decoding.
struct SearchMatcher {
    let fold: Bool
    let words: [[UInt8]]
    let excluded: [[UInt8]]
    let files: [[UInt8]]
    let excludedFiles: [[UInt8]]
    /// Bytes every matching line has as they are on disk, longest first. A transcript line
    /// is JSON, so a term is only looked for by its longest stretch that JSON writes
    /// unchanged (no quotes or backslashes); the decoded text is checked in full afterwards.
    let prefilter: [[UInt8]]

    init(_ query: SessionSearchQuery) {
        let fold = !query.caseSensitive
        self.fold = fold
        words = query.words.map { SearchBytes.needle($0, fold: fold) }
        excluded = query.excluded.map { SearchBytes.needle($0, fold: fold) }
        files = query.files.map { SearchBytes.needle($0, fold: fold) }
        excludedFiles = query.excludedFiles.map { SearchBytes.needle($0, fold: fold) }
        prefilter = (query.words + query.files)
            .compactMap { term in
                term.split(whereSeparator: { $0 == "\"" || $0 == "\\" }).max { $0.utf8.count < $1.utf8.count }
            }
            .map { SearchBytes.needle(String($0), fold: fold) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    /// The words to light up in a snippet.
    var highlighted: [[UInt8]] { words + files }

    /// Whether one line's raw bytes could hold a match. `skipFirst` when the caller found
    /// the first term already.
    func mayMatch(_ line: UnsafeBufferPointer<UInt8>, skipFirst: Bool = false) -> Bool {
        prefilter.dropFirst(skipFirst ? 1 : 0).allSatisfy { SearchBytes.contains($0, in: line, fold: fold) }
    }

    /// Whether a decoded piece of a line matches: every word is in its text and no excluded
    /// one is, and every `file:` part is in one of the paths it's about (or, for a command,
    /// in the command itself).
    func matches(text: UnsafeBufferPointer<UInt8>, paths: [String], pathsInText: Bool) -> Bool {
        for word in words where !SearchBytes.contains(word, in: text, fold: fold) { return false }
        for word in excluded where SearchBytes.contains(word, in: text, fold: fold) { return false }
        guard !files.isEmpty || !excludedFiles.isEmpty else { return true }
        let pathBytes = paths.map { Array($0.utf8) }
        func about(_ part: [UInt8]) -> Bool {
            pathBytes.contains { path in path.withUnsafeBufferPointer { SearchBytes.contains(part, in: $0, fold: fold) } }
        }
        for part in files where !(about(part) || (pathsInText && SearchBytes.contains(part, in: text, fold: fold))) { return false }
        for part in excludedFiles where about(part) || (pathsInText && SearchBytes.contains(part, in: text, fold: fold)) { return false }
        return true
    }
}
#endif
