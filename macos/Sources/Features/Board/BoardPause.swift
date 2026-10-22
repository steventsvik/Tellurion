#if os(macOS)
import Darwin
import Foundation

/// Pauses and resumes everything running in a tile: its shell, the agent and whatever the
/// agent started. Each terminal's processes carry its surface id in `surfaceKey`, so they're
/// found even after an agent starts its own children.
///
/// The shell is stopped before what it runs and continued after it, so it never sees its job
/// stop: otherwise it would print "suspended" and take the terminal back from the agent.
enum BoardPause {
    static let surfaceKey = "GHOSTTY_EXTREME_SURFACE"
    /// In order, so a quick pause and resume can't swap.
    static let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.board-pause", qos: .userInitiated)

    /// Stops (or continues) the processes of these terminals. Call off the main thread.
    static func set(_ paused: Bool, surfaces: Set<UUID>) {
        guard !surfaces.isEmpty else { return }
        let wanted = Set(surfaces.map(\.uuidString))
        var parents: [Int32: Int32] = [:]
        var found: [Int32] = []
        for pid in ProcessProbe.userPIDs() where pid != getpid() {
            guard let info = ProcessProbe.bsdInfo(pid) else { continue }
            parents[pid] = info.ppid
            if let surface = ProcessProbe.environment(pid, surfaceKey), wanted.contains(surface) { found.append(pid) }
        }
        let mine = Set(found)
        // How many of a process's ancestors are in the tile: 0 for the shell.
        func depth(_ pid: Int32) -> Int {
            var depth = 0, current = pid
            while let parent = parents[current], mine.contains(parent), depth < 64 {
                depth += 1
                current = parent
            }
            return depth
        }
        let outermostFirst = found.sorted { depth($0) < depth($1) }
        for pid in paused ? outermostFirst : outermostFirst.reversed() {
            kill(pid, paused ? SIGSTOP : SIGCONT)
        }
    }
}

extension BoardPause {
    /// The agent CLI running in each of these terminals (BoardAgent binaries), found by their
    /// processes: for agents started by hand that haven't reported anything yet. Call off the
    /// main thread.
    static func agents(in surfaces: Set<UUID>) -> [UUID: String] {
        guard !surfaces.isEmpty else { return [:] }
        let wanted = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.uuidString, $0) })
        let binaries = Set(BoardAgent.catalog.map(\.binary))
        var found: [UUID: String] = [:]
        for pid in ProcessProbe.userPIDs() where pid != getpid() {
            guard let process = ProcessProbe.procArgs(pid),
                  let tag = process.environment.first(where: { $0.hasPrefix(surfaceKey + "=") }),
                  let surface = wanted[String(tag.dropFirst(surfaceKey.count + 1))], found[surface] == nil else { continue }
            // The program, or the script node runs ("node …/bin/codex.js").
            for argument in process.arguments.prefix(2) {
                let name = ((argument as NSString).lastPathComponent as NSString).deletingPathExtension
                if binaries.contains(name) {
                    found[surface] = name
                    break
                }
            }
        }
        return found
    }
}

extension BoardController {
    /// Pauses or resumes tiles (all of them when `ids` is nil). Paused tiles show it in their
    /// title bar; closing one continues it first so it can quit.
    func setPaused(_ paused: Bool, _ ids: [UUID]? = nil) {
        let targets = Set(ids ?? model.surfaces.map(\.id)).intersection(model.surfaces.map(\.id))
        let changing = paused ? targets.subtracting(model.paused) : targets.intersection(model.paused)
        guard !changing.isEmpty else { return }
        if paused { model.paused.formUnion(changing) } else { model.paused.subtract(changing) }
        BoardPause.queue.async { BoardPause.set(paused, surfaces: changing) }
    }
}
#endif
