#if os(macOS)
import AppKit
import SwiftUI

/// The amber line on an agent's sidebar card and Mission Control card when another agent
/// has changed the same files: "2 files also edited by Otto". Clicking it lists the files.
/// Nothing is shown (and nothing takes up room) when there are none.
struct AgentConflictLine: View {
    let surface: Ghostty.SurfaceView
    var compact = false
    @ObservedObject private var radar = AgentConflicts.shared
    @ObservedObject private var settings = TellurionSettings.shared
    @State private var showing = false

    var body: some View {
        let conflicts = settings.isOn(.conflicts) ? radar.conflicts(for: surface) : []
        if !conflicts.isEmpty {
            Button { showing = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
                    Text(ConflictText.summary(files: conflicts.count, others: conflicts.flatMap(\.others)))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Tellurion.font(compact ? 10 : 11))
                .foregroundColor(Tellurion.warn)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .help(AgentConflictList.tooltip(conflicts))
            .accessibilityLabel(ConflictText.summary(files: conflicts.count, others: conflicts.flatMap(\.others)))
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                AgentConflictList(surface: surface)
            }
        }
    }
}

/// The same warning, small enough for a board tile's title bar: a triangle and how many
/// files. The files are in its tooltip, and on the agent's row in the list beside the board.
struct AgentConflictMark: View {
    let surface: Ghostty.SurfaceView
    @ObservedObject private var radar = AgentConflicts.shared
    @ObservedObject private var settings = TellurionSettings.shared

    var body: some View {
        let conflicts = settings.isOn(.conflicts) ? radar.conflicts(for: surface) : []
        if !conflicts.isEmpty {
            Label("\(conflicts.count)", systemImage: "exclamationmark.triangle.fill")
                .font(Tellurion.font(9.5, weight: .bold))
                .foregroundColor(Tellurion.warn)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Tellurion.warn.opacity(0.14)))
                .fixedSize()
                .help(AgentConflictList.tooltip(conflicts))
                .accessibilityLabel(ConflictText.summary(files: conflicts.count, others: conflicts.flatMap(\.others)))
        }
    }
}

/// The files an agent shares with others, each opening on a click, and a way to tell the
/// agents themselves.
struct AgentConflictList: View {
    let surface: Ghostty.SurfaceView
    @ObservedObject private var radar = AgentConflicts.shared
    @State private var told = false

    private static let shown = 12

    /// The files, for a tooltip: "src/cart.py · Otto".
    static func tooltip(_ conflicts: [AgentConflicts.Conflict]) -> String {
        var lines = conflicts.prefix(8).map { "\($0.path) · \(ConflictText.names($0.others))" }
        if conflicts.count > 8 { lines.append("and \(conflicts.count - 8) more") }
        return (["Also edited by another agent in the same folder:"] + lines).joined(separator: "\n")
    }

    var body: some View {
        let conflicts = radar.conflicts(for: surface)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edited by more than one agent").font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.text)
                Text(subtitle(conflicts)).font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if conflicts.isEmpty {
                Text("Nothing shared any more.").font(Tellurion.font(11.5)).foregroundColor(Tellurion.dim)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(conflicts.prefix(Self.shown)) { conflict in row(conflict) }
                }
                .tellurionPanel()
                if conflicts.count > Self.shown {
                    Text("and \(conflicts.count - Self.shown) more").font(Tellurion.font(11)).foregroundColor(Tellurion.dim)
                }
                footer(conflicts)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Tellurion.panel)
    }

    private func subtitle(_ conflicts: [AgentConflicts.Conflict]) -> String {
        guard let root = conflicts.first?.root else { return "Changes in the last half hour, not yet committed." }
        return "In \((root as NSString).abbreviatingWithTildeInPath). Nothing is blocked; changed and not yet committed."
    }

    private func row(_ conflict: AgentConflicts.Conflict) -> some View {
        Button { AgentConflicts.open(conflict, from: surface) } label: {
            HStack(spacing: 8) {
                Text(conflict.path).font(Tellurion.mono(11)).foregroundColor(Tellurion.text)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text(ConflictText.names(conflict.others)).font(Tellurion.font(11)).foregroundColor(Tellurion.warn)
                    .lineLimit(1).layoutPriority(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(conflict.path)")
    }

    @ViewBuilder
    private func footer(_ conflicts: [AgentConflicts.Conflict]) -> some View {
        let others = radar.others(for: surface)
        let reachable = ([surface] + others).filter(AgentConflicts.takesMessages)
        HStack(spacing: 8) {
            if reachable.count > 1 {
                Button(told ? "Queued" : reachable.count == 2 ? "Tell Both Agents" : "Tell All \(reachable.count) Agents") {
                    radar.tellAgents(about: surface)
                    told = true
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .controlSize(.small)
                .disabled(told)
                .help("Sends each agent one line naming the files and the other agent, once it's between turns")
            }
            Spacer()
            ForEach(Array(others.prefix(2).enumerated()), id: \.offset) { _, other in
                Button("Go to \(AgentConflicts.name(of: other) ?? "Agent")") { TerminalWindows.show(other) }
                    .buttonStyle(.plain)
                    .font(Tellurion.font(11))
                    .foregroundColor(Tellurion.muted)
            }
        }
    }
}
#endif
