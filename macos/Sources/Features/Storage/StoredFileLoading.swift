#if os(macOS)
import Foundation
import os

/// Reading Tellurion's own files back. A file that's there but can't be read is never the
/// same as no file: the next save would replace it, and everything in it would be gone.
extension StoredFile {
    enum Loaded<Value> {
        /// No file yet.
        case missing
        case loaded(Value)
        /// There was a file, and it couldn't be read or decoded. It was moved aside (see
        /// `setAside`), so saving again is safe.
        case unreadable

        var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    /// How many set-aside copies of one file are kept.
    static let unreadableCopiesKept = 3

    /// Loads a JSON file. One that's there but unreadable is moved aside as
    /// `<name>.unreadable-<timestamp>` and logged; the caller then starts empty.
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL, what: String, log: Logger,
                                       decoder: JSONDecoder = JSONDecoder()) -> Loaded<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if isMissing(error) { return .missing }
            log.error("Couldn't read \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            setAside(url, what: what, log: log)
            return .unreadable
        }
        do {
            return .loaded(try decoder.decode(type, from: data))
        } catch {
            log.error("Couldn't understand \(what, privacy: .public): \(Self.summary(of: error), privacy: .public)")
            setAside(url, what: what, log: log)
            return .unreadable
        }
    }

    /// Loads a JSON list, skipping items that can't be decoded instead of losing the whole
    /// list. When any were skipped, a copy of the file as it was is kept beside it first,
    /// since the next save writes the list without them.
    static func loadList<Element: Decodable>(_ type: Element.Type, from url: URL, what: String, log: Logger,
                                             decoder: JSONDecoder = JSONDecoder()) -> Loaded<[Element]> {
        switch load(LossyArray<Element>.self, from: url, what: what, log: log, decoder: decoder) {
        case .missing: return .missing
        case .unreadable: return .unreadable
        case .loaded(let list):
            if list.skipped > 0 {
                log.error("Skipped \(list.skipped) unreadable item(s) in \(what, privacy: .public)")
                setAside(url, what: what, log: log, keepingOriginal: true)
            }
            return .loaded(list.elements)
        }
    }

    /// Moves (or, with `keepingOriginal`, copies) a file to `<name>.unreadable-<timestamp>`
    /// beside it, then removes all but the newest few such copies. Returns the copy.
    @discardableResult
    static func setAside(_ url: URL, what: String, log: Logger, keepingOriginal: Bool = false,
                         stamp: String = StoredFile.stamp()) -> URL? {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".unreadable-"
        var copy = folder.appendingPathComponent(prefix + stamp)
        var n = 2
        while fm.fileExists(atPath: copy.path) {
            copy = folder.appendingPathComponent("\(prefix)\(stamp)-\(n)")
            n += 1
        }
        do {
            if keepingOriginal {
                try fm.copyItem(at: url, to: copy)
            } else {
                try fm.moveItem(at: url, to: copy)
            }
        } catch {
            log.error("Couldn't set aside \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        log.error("Kept the unreadable \(what, privacy: .public) as \(copy.lastPathComponent, privacy: .public)")
        prune(in: folder, prefix: prefix, keep: unreadableCopiesKept)
        return copy
    }

    /// Removes all but the newest `keep` files in `folder` whose names start with `prefix`.
    /// The rest of each name is a timestamp (and a `-2`, `-3`… for the same second), so the
    /// names say which are newest; a copied file's dates are its original's.
    static func prune(in folder: URL, prefix: String, keep: Int) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
        let newestFirst = names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for old in newestFirst.dropFirst(max(keep, 0)) { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
    }

    /// The time as it goes in a file name: `20250131-235959`.
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    /// Why a decode failed, without the file's contents: the kind of problem and where.
    static func summary(of error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "the top level" : keys.joined(separator: ".")
        }
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, let context): return "no \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context): return "an unexpected kind of value at \(path(context))"
        case .valueNotFound(_, let context): return "a missing value at \(path(context))"
        case .dataCorrupted(let context): return "damaged data at \(path(context))"
        @unknown default: return "it couldn't be decoded"
        }
    }
}

/// A list that decodes what it can: an item that fails is skipped and counted, and the rest
/// are kept.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    /// How many items couldn't be decoded.
    var skipped = 0

    /// Decodes from anything, taking nothing: steps over an item that failed.
    private struct Anything: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let index = container.currentIndex
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                skipped += 1
                // A failed decode leaves the container on the same item.
                if container.currentIndex == index { _ = try? container.decode(Anything.self) }
                if container.currentIndex == index { break }
            }
        }
    }
}
#endif
