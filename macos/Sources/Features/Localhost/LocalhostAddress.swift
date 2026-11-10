#if os(macOS)
import Foundation

/// The address a dev server says it's serving at, from what it printed when it started
/// (`Local:   http://localhost:5173/app/`), so its card opens the page and not just the port.
/// The log is whatever the server wrote, so nothing is taken from it but a checked scheme,
/// host, port, path and query.
enum LocalhostAddress {
    /// The longest line, and so the longest address, that's looked at.
    static let lineLimit = 2000
    /// How much of a log is read from each end of its current run.
    static let readLimit = 64 * 1024

    /// Terminal colors and other escape sequences.
    private static let escapes = #"\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[()][A-Z0-9]"#
    /// The rule the runner writes to the log each time it starts the server.
    private static let runRule = #"^──── [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ────$"#
    private static let link = #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]+"#
    /// What a path or query may hold. Narrower than a URL allows: the address is also told to
    /// agents, so nothing a shell would act on (`$`, `&`, `;`, brackets, quotes) gets through.
    private static let encoded = #"^(?:[A-Za-z0-9\-._~:@/?=+,]|%[0-9A-Fa-f]{2})+$"#

    /// The local address announced in `log` for one of the `ports` the server listens on.
    /// A line labelled "Local" wins over a plain one, and that over "Network"; otherwise
    /// the first one in the current run.
    static func announced(in log: String, listening ports: [Int]) -> URL? {
        guard !ports.isEmpty else { return nil }
        let text = log.replacingOccurrences(of: escapes, with: "", options: .regularExpression)
        var best: URL?
        var bestRank = Int.max
        for line in text.split(whereSeparator: \.isNewline) where line.utf8.count <= lineLimit {
            if line.range(of: runRule, options: .regularExpression) != nil {
                // Anything above is from an earlier run.
                best = nil
                bestRank = Int.max
                continue
            }
            var from = line.startIndex
            while from < line.endIndex,
                  let found = line.range(of: link, options: [.regularExpression, .caseInsensitive], range: from..<line.endIndex) {
                from = found.upperBound
                // An address cut short by a stray control character isn't the address.
                if found.upperBound < line.endIndex, line[found.upperBound].unicodeScalars.contains(where: isControl) { continue }
                guard let url = address(trimmed(String(line[found])), listening: ports) else { continue }
                let order = rank(label: line[..<found.lowerBound])
                if order < bestRank {
                    best = url
                    bestRank = order
                }
            }
        }
        return best
    }

    /// `text` as a local address, when it is one on a listening port.
    static func address(_ text: String, listening ports: [Int]) -> URL? {
        guard text.utf8.count <= lineLimit, !text.unicodeScalars.contains(where: isControl),
              let parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil,
              var host = parts.host?.lowercased() else { return nil }
        let secure = scheme == "https"
        let port = parts.port ?? (secure ? 443 : 80)
        guard ports.contains(port) else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch host {
        case "localhost":
            break
        case "0.0.0.0", "::", "::1":
            host = "localhost"
        case "127.0.0.1":
            // A certificate may be for the number, so https keeps it.
            if !secure { host = "localhost" }
        default:
            guard host.hasSuffix(".localhost"),
                  host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        }
        let path = parts.percentEncodedPath
        let query = parts.percentEncodedQuery.flatMap { $0.isEmpty ? nil : $0 }
        guard isEncoded(path), isEncoded(query ?? "") else { return nil }
        var result = URLComponents()
        result.scheme = scheme
        result.host = host
        result.port = port
        result.percentEncodedPath = path == "/" && query == nil ? "" : path
        result.percentEncodedQuery = query
        return result.url
    }

    /// `localhost:5173/app/`: the address without its scheme and query, for cards and titles.
    static func display(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return (url.host ?? "localhost") + (url.port.map { ":\($0)" } ?? "") + (path == "/" ? "" : path)
    }

    /// The start and the end of the log's current run, at most `readLimit` bytes of each.
    /// Reads the file, so not for the main thread.
    static func read(logAt path: String) -> String {
        guard let file = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? file.close() }
        let limit = UInt64(readLimit)
        guard let size = try? file.seekToEnd() else { return "" }
        func bytes(_ from: UInt64, _ to: UInt64) -> Data {
            guard to > from, (try? file.seek(toOffset: from)) != nil else { return Data() }
            return (try? file.read(upToCount: Int(to - from))) ?? Data()
        }
        if size <= 2 * limit { return String(decoding: bytes(0, 2 * limit), as: UTF8.self) }

        // A long log: find where this run starts, looking back from the end.
        let rule = Data("\n──── ".utf8)
        var start: UInt64?
        var end = size
        for _ in 0..<32 where start == nil && end > 0 {
            let begin = end > limit ? end - limit : 0
            let block = bytes(begin, min(size, end + UInt64(rule.count)))
            if let hit = block.range(of: rule, options: .backwards) {
                start = begin + UInt64(hit.lowerBound - block.startIndex)
            }
            end = begin
        }
        var head = start.map { bytes($0, $0 + limit) } ?? Data()
        var tail = bytes(max((start ?? 0) + limit, size - limit), size)
        // Each piece may end or begin mid-line; half an address is worse than none.
        if let cut = head.lastIndex(of: 0x0A) { head = head[..<cut] }
        if let cut = tail.firstIndex(of: 0x0A) { tail = tail[cut...] }
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isEncoded(_ part: String) -> Bool {
        part.isEmpty || part.range(of: encoded, options: .regularExpression) != nil
    }

    /// Drops the punctuation of the sentence an address was printed in.
    private static func trimmed(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last {
            if ".,;:!?*".contains(last)
                || (last == ")" && text.filter { $0 == "(" }.count < text.filter { $0 == ")" }.count)
                || (last == "]" && text.filter { $0 == "[" }.count < text.filter { $0 == "]" }.count) {
                text.removeLast()
            } else {
                break
            }
        }
        return String(text)
    }

    /// 0 for an address labelled as the local one, 2 for one labelled for the network.
    private static func rank(label: Substring) -> Int {
        let label = label.lowercased()
        if label.range(of: #"\blocal\b"#, options: .regularExpression) != nil { return 0 }
        if label.range(of: #"\b(network|external)\b"#, options: .regularExpression) != nil { return 2 }
        return 1
    }
}
#endif
