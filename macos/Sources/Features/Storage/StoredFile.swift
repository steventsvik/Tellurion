#if os(macOS)
import Foundation
import os

/// Writing Tellurion's own files (settings, designs, presets, saved pictures): the folder is
/// made, the write is atomic, and a failure is logged under the feature's category instead of
/// being dropped. Logs say what failed and why, never the file's contents.
enum StoredFile {
    /// One logger per feature, in Console.app under the app's subsystem.
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.steventsvik.ghostty-extreme", category: category)
    }

    /// Writes `data` to `url`, making its folder first. Returns whether it worked; on failure
    /// the error is logged as "Couldn't save <what>".
    @discardableResult
    static func write(_ data: Data, to url: URL, what: String, log: Logger) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("Couldn't save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `write` for a value encoded as JSON (pretty-printed, sorted keys, as the files are read by people too).
    @discardableResult
    static func write<Value: Encodable>(json value: Value, to url: URL, what: String, log: Logger,
                                        encoder: JSONEncoder = StoredFile.encoder) -> Bool {
        do {
            return write(try encoder.encode(value), to: url, what: what, log: log)
        } catch {
            log.error("Couldn't encode \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Removes a file that may not be there; anything other than "not there" is logged.
    static func remove(_ url: URL, what: String, log: Logger) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            log.error("Couldn't remove \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
