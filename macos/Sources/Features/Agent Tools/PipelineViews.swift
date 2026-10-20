#if os(macOS)
import AppKit
import SwiftUI

/// Shown on an agent's sidebar card and Mission Control card: its pipeline (round, what's
/// happening, Send and Stop) and any message waiting to be typed into it.
struct AgentMessagesLine: View {
    let surface: Ghostty.SurfaceView
    var compact = false
    @ObservedObject private var pipelines = AgentPipelines.shared
    @ObservedObject private var inbox = AgentInbox.shared
    /// Bumped when an agent's status changes, so names and states read fresh.
    @State private var agentsChanged = 0

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)) { _ in
                if pipelines.pipeline(for: surface) != nil { agentsChanged += 1 }
            }
    }

    @ViewBuilder
    private var content: some View {
        // Reading it makes the view depend on it (`_ =` isn't allowed in a view builder).
        // swiftlint:disable:next redundant_discardable_let
        let _ = agentsChanged
        let waiting = inbox.waiting(for: surface)
        let pipeline = pipelines.pipeline(for: surface)
        if pipeline != nil || !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let (pipeline, role) = pipeline { pipelineLine(pipeline, role: role) }
                ForEach(waiting) { delivery in waitingLine(delivery) }
            }
            .padding(.top, 2)
        }
    }

    private func pipelineLine(_ pipeline: AgentPipelines.Pipeline, role: AgentPipelines.Role) -> some View {
        let other = role == .writer ? pipeline.reviewer : pipeline.writer
        // A new reviewer has no status until it starts up.
        let otherName = other.map { VerticalTabsAgents.shared.info(for: $0)?.kind.displayName ?? "a new agent" } ?? "a closed pane"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9, weight: .bold))
                Text(role == .writer ? "Reviewed by \(otherName)" : "Reviewing \(otherName)")
                    .lineLimit(1)
                Text("·")
                Text(status(pipeline, role: role)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                if pipeline.isActive {
                    Button { AgentPipelines.shared.stop(pipeline.id) } label: {
                        Image(systemName: "stop.circle").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Stop the review loop")
                    .accessibilityLabel("Stop the review loop")
                } else {
                    Button { AgentPipelines.shared.remove(pipeline.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss the finished review loop")
                }
            }
            .font(Extreme.font(10))
            .foregroundColor(pipeline.isActive ? Extreme.core : Extreme.muted)
            if let pending = pipeline.pending, let target = pending.to == .writer ? pipeline.writer : pipeline.reviewer {
                HStack(spacing: 6) {
                    Button { AgentPipelines.shared.sendPending(pipeline.id) } label: {
                        Text(pending.to == .reviewer ? "Send for review" : "Send feedback")
                    }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .controlSize(.small)
                    .help("Types it into \(VerticalTabsAgents.shared.info(for: target)?.kind.displayName ?? "the agent") once it's between turns")
                    Button("Auto") { AgentPipelines.shared.setAutoSend(true, for: pipeline.id) }
                        .buttonStyle(.plain)
                        .font(Extreme.font(10))
                        .foregroundColor(Extreme.muted)
                        .help("Send this and every later round without asking")
                }
            }
        }
    }

    private func status(_ pipeline: AgentPipelines.Pipeline, role: AgentPipelines.Role) -> String {
        switch pipeline.stage {
        case .finished(let reason): return reason
        case .writing:
            if pipeline.pending?.to == .writer { return "feedback ready" }
            return pipeline.round == 0 ? "waits for the next turn" : "round \(pipeline.round) of \(pipeline.maxRounds) · fixing"
        case .reviewing:
            if pipeline.pending?.to == .reviewer { return "review ready to send" }
            return "round \(pipeline.round) of \(pipeline.maxRounds) · reviewing"
        }
    }

    private func waitingLine(_ delivery: AgentInbox.Delivery) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 9))
            Text(delivery.state == .blockedByTypedText
                 ? "\(delivery.label) · waiting: clear the input box"
                 : "\(delivery.label) · goes in after this turn")
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Button { AgentInbox.shared.cancel(delivery.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Don't send it")
            .accessibilityLabel("Don't send \(delivery.label)")
        }
        .font(Extreme.font(10))
        .foregroundColor(delivery.state == .blockedByTypedText ? Extreme.warn : Extreme.muted)
    }
}

// MARK: - Pairing window

enum PipelineSetup {
    static func show(writer: Ghostty.SurfaceView, in controller: BaseTerminalController) {
        // Fresh for this writer, never one left open for another pane.
        AgentToolWindows.close(id: "pipeline")
        AgentToolWindows.show(id: "pipeline", title: "Review Loop", size: NSSize(width: 560, height: 560)) {
            PipelineSetupView(writer: writer, controller: controller)
        }
    }
}

private struct PipelineSetupView: View {
    weak var writer: Ghostty.SurfaceView?
    weak var controller: BaseTerminalController?
    @State private var newReviewer: VerticalTabAgentKind
    @State private var existing: ObjectIdentifier?
    @State private var autoSend = false
    @State private var rounds = 3
    @State private var reviewNow: Bool

    init(writer: Ghostty.SurfaceView, controller: BaseTerminalController) {
        self.writer = writer
        self.controller = controller
        let kind = VerticalTabsAgents.shared.info(for: writer)?.kind
        _newReviewer = State(initialValue: kind == .codex ? .claude : .codex)
        // Review what's there now if the writer has already done some work.
        _reviewNow = State(initialValue: !TurnCheckpoints.shared.list(for: writer).isEmpty)
    }

    private var writerName: String {
        writer.flatMap { VerticalTabsAgents.shared.info(for: $0)?.kind.displayName } ?? "This agent"
    }

    private var running: [(surface: Ghostty.SurfaceView, info: VerticalTabAgentInfo, tab: String)] {
        writer.map { AgentHandoff.runningAgents(excluding: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ExtremeWindowTitle(icon: .restart, title: "Review Loop",
                                   subtitle: "\(writerName) writes, another agent reviews, in rounds")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Extreme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        ExtremeSectionLabel("Reviewer")
                        ForEach(AgentHandoff.targets, id: \.self) { kind in
                            radio("New \(kind.displayName) beside this pane", selected: existing == nil && newReviewer == kind) {
                                existing = nil
                                newReviewer = kind
                            }
                        }
                        ForEach(running, id: \.surface) { agent in
                            radio("\(agent.info.kind.displayName) in \(agent.tab)", selected: existing == ObjectIdentifier(agent.surface)) {
                                existing = ObjectIdentifier(agent.surface)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ExtremeSectionLabel("How it runs")
                        Toggle(isOn: $reviewNow) {
                            labelled("Review the current changes now", "Otherwise the first review follows \(writerName)'s next turn")
                        }
                        .toggleStyle(.checkbox)
                        Toggle(isOn: $autoSend) {
                            labelled("Send automatically", "Off: each review and each round of feedback waits for you to press Send on the agent's card")
                        }
                        .toggleStyle(.checkbox)
                        Stepper(value: $rounds, in: 1...6) {
                            labelled("Up to \(rounds) round\(rounds == 1 ? "" : "s")", "It also stops when the reviewer approves")
                        }
                    }
                    Text("""
                    Each round the reviewer gets \(writerName)'s changes and reply, and is asked to answer APPROVED or \
                    CHANGES NEEDED. Its findings go back to \(writerName). Messages are only typed into an agent between \
                    turns, into an empty input box.
                    """)
                    .font(Extreme.font(11)).foregroundColor(Extreme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            Rectangle().fill(Extreme.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { AgentToolWindows.close(id: "pipeline") }
                Button("Start") { start() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(writer == nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .extremeWindow()
    }

    private func start() {
        guard let writer, let controller else { return }
        if let existing, let agent = running.first(where: { ObjectIdentifier($0.surface) == existing }) {
            AgentPipelines.shared.start(writer: writer, reviewer: agent.surface, autoSend: autoSend, maxRounds: rounds, reviewNow: reviewNow)
        } else {
            // A new agent beside the writer, started without a prompt; the review is typed in
            // once it's up and its input box is ready.
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = writer.pwd
            config.initialInput = (newReviewer == .codex ? "codex" : "claude") + "\n"
            guard let reviewer = controller.newSplit(at: writer, direction: .right, baseConfig: config) else { return }
            AgentPipelines.shared.start(writer: writer, reviewer: reviewer, autoSend: autoSend, maxRounds: rounds, reviewNow: reviewNow)
        }
        AgentToolWindows.close(id: "pipeline")
    }

    private func labelled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(Extreme.font(12, weight: .semibold)).foregroundColor(Extreme.text)
            Text(detail).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Extreme.gold : Extreme.dim)
                Text(title).font(Extreme.font(12)).foregroundColor(Extreme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
