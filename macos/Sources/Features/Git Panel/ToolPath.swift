#if os(macOS)
import Foundation

/// Finds command line tools the app runs itself (jj, gt, but…). The app doesn't get the
/// login shell's PATH, so this looks where installers put them, then (off the main thread)
/// on the login shell's PATH. A tool found once is remembered.
enum ToolPath {
    private static let lock = NSLock()
    private static var found: [String: String] = [:]

    static func find(_ names: String...) -> String? {
        lock.lock()
        defer { lock.unlock() }
        for name in names { if let path = found[name] { return path } }
        let home = NSHomeDirectory()
        let common = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/.local/bin",
                      home + "/.bun/bin", home + "/.npm-global/bin", home + "/.nix-profile/bin",
                      "/run/current-system/sw/bin", home + "/.local/share/mise/shims"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for name in names {
            if let hit = (path + common).map({ $0 + "/" + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? (Thread.isMainThread ? nil : SetupChecks.locate(name)) {
                found[name] = hit
                return hit
            }
        }
        return nil
    }

    /// Runs `tool` synchronously in `directory`. Call off the main thread.
    static func run(_ tool: String, _ args: [String], in directory: String, environment extra: [String: String] = [:]) -> AgentTools.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.merge(extra) { $1 }
        process.environment = EventToken.scrubbed(environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return AgentTools.Result(status: -1, output: "", error: "\(error)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AgentTools.Result(status: process.terminationStatus,
                                 output: String(bytes: outData, encoding: .utf8) ?? "",
                                 error: String(bytes: errData, encoding: .utf8) ?? "")
    }
}
#endif
