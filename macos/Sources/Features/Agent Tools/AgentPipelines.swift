#if os(macOS)
import AppKit
import Combine

/// A writer agent and a reviewer agent working in rounds: when the writer finishes a turn,
/// the reviewer gets its changes; the reviewer's findings go back to the writer; and so on,
/// until the reviewer approves, the round limit is reached, or the user stops it.
///
/// By default every message waits for the user to press Send (on either agent's sidebar
/// card or in Mission Control). With auto-send on, they go as soon as the receiving agent is
/// between turns (through `AgentInbox`, which only types into an empty input box).
final class AgentPipelines: ObservableObject {
    static let shared = AgentPipelines()

    enum Role { case writer, reviewer }

    struct Pipeline: Identifiable {
        enum Stage: Equatable {
            /// The writer is working (or about to); its next finished turn goes to review.
            case writing
            /// The reviewer has (or is about to get) the changes.
            case reviewing
            case finished(String)
        }

        struct Pending {
            let to: Role
            let text: String
            let label: String
        }

        let id = UUID()
        weak var writer: Ghostty.SurfaceView?
        weak var reviewer: Ghostty.SurfaceView?
        var autoSend: Bool
        var maxRounds: Int
        /// Reviews done or underway.
        var round = 0
        var stage: Stage = .writing
        /// A message waiting for the user's Send (auto-send off).
        var pending: Pending?
        /// The message last handed to `AgentInbox`, so stopping can take it back.
        var delivery: UUID?
        /// The first review also carries the writer's project notes (a running reviewer of
        /// the other kind; see `AgentHandoff.needsMemory`).
        var shareMemory = false

        var isActive: Bool { if case .finished = stage { return false } else { return true } }
    }

    @Published private(set) var pipelines: [UUID: Pipeline] = [:]

    private var lastActivity = BoundedCache<ObjectIdentifier, VerticalTabAgentActivity>(limit: 1024)
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                if let surface = note.object as? Ghostty.SurfaceView { self?.agentChanged(surface) }
            }
            .store(in: &cancellables)
    }

    func pipeline(for surface: Ghostty.SurfaceView) -> (Pipeline, Role)? {
        for pipeline in pipelines.values {
            if pipeline.writer === surface { return (pipeline, .writer) }
            if pipeline.reviewer === surface { return (pipeline, .reviewer) }
        }
        return nil
    }

    // MARK: Starting and stopping

    /// Pairs `writer` with `reviewer`. With `reviewNow`, the writer's current changes go to
    /// review right away; otherwise the first review follows the writer's next turn.
    func start(writer: Ghostty.SurfaceView, reviewer: Ghostty.SurfaceView, autoSend: Bool, maxRounds: Int, reviewNow: Bool) {
        // A pane is in one pipeline at a time.
        for existing in pipelines.values where existing.writer === writer || existing.reviewer === writer
            || existing.writer === reviewer || existing.reviewer === reviewer {
            stop(existing.id)
            pipelines.removeValue(forKey: existing.id)
        }
        var pipeline = Pipeline(writer: writer, reviewer: reviewer, autoSend: autoSend, maxRounds: max(1, maxRounds))
        pipeline.shareMemory = AgentHandoff.needsMemory(from: writer, to: .existing(reviewer))
        lastActivity[ObjectIdentifier(writer)] = VerticalTabsAgents.shared.info(for: writer)?.activity
        lastActivity[ObjectIdentifier(reviewer)] = VerticalTabsAgents.shared.info(for: reviewer)?.activity
        pipelines[pipeline.id] = pipeline
        if reviewNow {
            pipeline.stage = .reviewing
            pipelines[pipeline.id] = pipeline
            requestReview(pipeline.id)
        }
    }

    func stop(_ id: UUID) {
        guard var pipeline = pipelines[id] else { return }
        if let delivery = pipeline.delivery { AgentInbox.shared.cancel(delivery) }
        pipeline.pending = nil
        pipeline.delivery = nil
        pipeline.stage = .finished("Stopped")
        pipelines[id] = pipeline
    }

    func remove(_ id: UUID) {
        stop(id)
        pipelines.removeValue(forKey: id)
    }

    func setAutoSend(_ on: Bool, for id: UUID) {
        guard var pipeline = pipelines[id] else { return }
        pipeline.autoSend = on
        pipelines[id] = pipeline
        if on, pipeline.pending != nil { sendPending(id) }
    }

    /// Sends the waiting message (the user pressed Send).
    func sendPending(_ id: UUID) {
        guard var pipeline = pipelines[id], let pending = pipeline.pending,
              let target = pending.to == .writer ? pipeline.writer : pipeline.reviewer else { return }
        pipeline.delivery = AgentInbox.shared.deliver(pending.text, to: target, label: pending.label)
        pipeline.pending = nil
        pipelines[id] = pipeline
    }

    // MARK: Rounds

    private func agentChanged(_ surface: Ghostty.SurfaceView) {
        let key = ObjectIdentifier(surface)
        let activity = VerticalTabsAgents.shared.info(for: surface)?.activity
        let previous = lastActivity.peek(key)
        lastActivity[key] = activity
        // Closed panes end their pipelines.
        for pipeline in pipelines.values where pipeline.isActive && (pipeline.writer == nil || pipeline.reviewer == nil) {
            var ended = pipeline
            ended.stage = .finished("A pane was closed")
            pipelines[pipeline.id] = ended
        }
        // A turn ended: it was working and now isn't.
        guard previous == .working || previous == .needsPermission,
              activity == .done || activity == .ready || activity == .needsInput,
              let (pipeline, role) = pipeline(for: surface), pipeline.isActive else { return }
        switch (role, pipeline.stage) {
        case (.writer, .writing):
            var next = pipeline
            next.stage = .reviewing
            pipelines[pipeline.id] = next
            requestReview(pipeline.id)
        case (.reviewer, .reviewing):
            reviewFinished(pipeline.id)
        default:
            break
        }
    }

    private func requestReview(_ id: UUID) {
        guard let pipeline = pipelines[id], let writer = pipeline.writer, pipeline.reviewer != nil else { return }
        let round = pipeline.round + 1
        let writerName = VerticalTabsAgents.shared.info(for: writer)?.kind.displayName ?? "the writer"
        let parts: Set<AgentContext.Part> = pipeline.shareMemory && round == 1 ? [.conversation, .changes, .memory] : [.conversation, .changes]
        AgentContext.gather(from: writer, parts: parts) { [weak self] context in
            guard let self, var pipeline = self.pipelines[id], pipeline.isActive else { return }
            pipeline.round = round
            let text = """
            Review round \(round) of \(pipeline.maxRounds). \(writerName) is working on this in \(context.folder) and \
            just finished a turn.

            \(context.render())

            Review the changes for bugs, security problems, missed edge cases and anything that doesn't match the \
            task. Don't edit files. Start your reply with exactly one line: APPROVED if nothing needs to change, or \
            CHANGES NEEDED. After CHANGES NEEDED, list what to fix, most important first, each with a file:line \
            reference. Your reply is passed to \(writerName) as it is.
            """
            pipeline.pending = .init(to: .reviewer, text: text, label: "Review round \(round)")
            self.pipelines[id] = pipeline
            if pipeline.autoSend { self.sendPending(id) }
        }
    }

    private func reviewFinished(_ id: UUID) {
        guard var pipeline = pipelines[id], let reviewer = pipeline.reviewer else { return }
        let info = VerticalTabsAgents.shared.info(for: reviewer)
        let transcript = info?.transcriptPath
            ?? info.flatMap { AgentTranscripts.find(kind: $0.kind, folder: reviewer.pwd ?? "", recent: 24 * 3600) }
        let reply = (AgentTools.lastAssistantMessage(transcript: transcript) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = Self.verdict(reply)
        if verdict == .approved {
            pipeline.stage = .finished("Approved in round \(pipeline.round)")
            pipelines[id] = pipeline
            return
        }
        if pipeline.round >= pipeline.maxRounds {
            pipeline.stage = .finished("Round limit reached (\(pipeline.maxRounds))")
            pipelines[id] = pipeline
            return
        }
        let reviewerName = VerticalTabsAgents.shared.info(for: reviewer)?.kind.displayName ?? "The reviewer"
        let text = """
        \(reviewerName) reviewed your changes (round \(pipeline.round) of \(pipeline.maxRounds)):

        \(reply.isEmpty ? "(The review couldn't be read from the reviewer's transcript; check its pane.)" : AgentTools.clip(reply, 12_000))

        Address these findings. If you disagree with one, say why instead of changing it. When you're done, \
        summarize what you changed.
        """
        pipeline.stage = .writing
        pipeline.pending = .init(to: .writer, text: text, label: "Review feedback, round \(pipeline.round)")
        pipelines[id] = pipeline
        if pipeline.autoSend { sendPending(id) }
    }

    enum Verdict { case approved, changesNeeded, unclear }

    /// Reads the first line of the reviewer's reply.
    static func verdict(_ reply: String) -> Verdict {
        let first = reply.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.uppercased().replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces) } ?? ""
        if first.hasPrefix("APPROVED") { return .approved }
        if first.hasPrefix("CHANGES NEEDED") { return .changesNeeded }
        return .unclear
    }
}
#endif
