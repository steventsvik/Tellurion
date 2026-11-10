#if os(macOS)
import Foundation
import SwiftUI

/// A commit message suggested from the changes in a review. A small job: a model on this Mac
/// writes it when small jobs are on and one can, otherwise your Claude Code or Codex does,
/// headless and read-only.
enum CommitSuggestion {
    /// The most that's sent, in characters: the instructions, the file list and as much of
    /// the diff as fits. Small enough for a model served with a 4096-token context.
    static let limit = 10_000
    static let listedFiles = 40

    static let instructions = """
    Write a git commit message for the changes below. The first line is a summary in the imperative mood, at most \
    72 characters, with no period at the end. If the changes need explaining, leave one empty line and add a short \
    body in plain text. Answer with the commit message only: no introduction, no quotes, no code fences.
    """

    /// Stops a suggestion that's still being written.
    final class Handle {
        private let lock = NSLock()
        private var run: HeadlessAgent.Run?
        private var stopped = false

        var isStopped: Bool { lock.withLock { stopped } }

        func stop() {
            let run = lock.withLock { () -> HeadlessAgent.Run? in
                stopped = true
                return self.run
            }
            run?.stop()
        }

        fileprivate func hold(_ run: HeadlessAgent.Run) {
            let late = lock.withLock { () -> Bool in
                self.run = run
                return stopped
            }
            if late { run.stop() }
        }
    }

    /// What the message is written from: the task the agent was given, the files it changed
    /// and the diff, cut to fit `limit` with every file getting a share.
    static func prompt(for item: ReviewItem, limit: Int = limit) -> String {
        var text = ""
        if let task = item.task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            text += "The task was: \(String(task.prefix(300)))\n\n"
        }
        text += "Files changed:\n"
        for file in item.files.prefix(listedFiles) {
            text += "\(file.status.rawValue) \(file.path) (+\(file.added) -\(file.removed))\n"
        }
        if item.files.count > listedFiles { text += "and \(item.files.count - listedFiles) more\n" }
        text += "\nDiff:\n"
        let budget = limit - instructions.count - text.count
        let share = max(400, budget / max(1, item.files.count) - 8)
        var diff = ""
        for file in item.files where diff.count < budget {
            let whole = self.diff(of: file)
            diff += whole.count > share ? String(whole.prefix(share)) + "\n(cut)\n" : whole
        }
        return text + String(diff.prefix(max(0, budget)))
    }

    private static func diff(of file: ReviewFile) -> String {
        var text = "--- \(file.path)\n"
        if file.isBinary { return text + "(binary file)\n" }
        for hunk in file.hunks {
            text += hunk.header + "\n"
            for line in hunk.lines {
                text += (line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text + "\n"
            }
        }
        return text
    }

    /// Who writes it when no model on this Mac does: the agent whose changes these are, when
    /// that's Claude Code or Codex and it's installed, else whichever of the two is.
    static func engine(for item: ReviewItem, installed: [HeadlessAgent.Engine]) -> HeadlessAgent.Engine? {
        installed.first { $0.kind == item.agent } ?? installed.first
    }

    static func job(for item: ReviewItem, engine: HeadlessAgent.Engine?, handle: Handle) -> SmallJob {
        let prompt = self.prompt(for: item)
        let folder = item.repoRoot
        return SmallJob(kind: .commitMessage, instructions: instructions, prompt: prompt,
                        fallbackName: engine?.title ?? HeadlessAgent.Engine.claude.title, fallback: { done in
            guard let engine else { return done(.failure(HeadlessAgent.StreamError.missing("Claude Code or Codex"))) }
            guard !handle.isStopped else { return done(.failure(HeadlessAgent.StreamError.stopped)) }
            let ask = HeadlessAgent.Ask(instructions: instructions, prompt: prompt, folder: folder,
                                        model: engine == .claude ? "haiku" : nil)
            handle.hold(HeadlessAgent.stream(engine, ask, progress: { _, _ in }, done: done))
        })
    }
}

/// "Suggest" in the Review commit popover: fills the message in from the changes.
struct CommitSuggestButton: View {
    let item: ReviewItem
    @Binding var message: String
    @ObservedObject private var settings = TellurionSettings.shared
    @State private var engines: [HeadlessAgent.Engine] = []
    @State private var handle: CommitSuggestion.Handle?
    @State private var problem: String?

    var body: some View {
        let local = settings.isOn(.smallJobs)
        let engine = CommitSuggestion.engine(for: item, installed: engines)
        HStack(spacing: 6) {
            // Someone has to be there to write it.
            if local || engine != nil {
                Button(handle == nil ? "Suggest" : "Stop") {
                    if let handle { stop(handle) } else { suggest(engine) }
                }
                .help(help(local: local, engine: engine))
                if handle != nil { ProgressView().controlSize(.small) }
                if let problem {
                    Text(problem).font(Tellurion.font(10.5)).foregroundColor(.orange).lineLimit(1).truncationMode(.tail)
                        .help(problem)
                }
            }
        }
        .onAppear { HeadlessAgent.lookUp { found, _ in engines = found } }
        .onDisappear { if let handle { stop(handle) } }
    }

    private func help(local: Bool, engine: HeadlessAgent.Engine?) -> String {
        let name = engine?.title ?? "Claude Code or Codex"
        return local ? "Writes a message from these changes with a model on this Mac when one can, else with \(name)"
            : "Writes a message from these changes with \(name)"
    }

    private func suggest(_ engine: HeadlessAgent.Engine?) {
        let current = CommitSuggestion.Handle()
        handle = current
        problem = nil
        SmallJobs.shared.run(CommitSuggestion.job(for: item, engine: engine, handle: current)) { result, _ in
            guard handle === current else { return }
            handle = nil
            switch result {
            case .success(let text): message = text
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    private func stop(_ current: CommitSuggestion.Handle) {
        current.stop()
        handle = nil
    }
}
#endif
