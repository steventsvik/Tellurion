#if os(macOS)
import AppKit
import SwiftUI

/// The pieces an orchestrator's panel is made of, shared by a board's orchestrator card and a
/// project's orchestrator window: a log entry, the whole log, a wired agent's row and the
/// command row's round buttons.

/// One log entry: yours, what the orchestrator says, what it did, what happened, or an error.
/// Always plain text, whatever an agent or the brain wrote.
struct OrchestratorEntryRow: View {
    let entry: OrchestratorBrain.Entry
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: Self.symbol(entry.kind)).font(.system(size: 9, weight: .semibold))
                .foregroundColor(entry.kind == .error ? .red : entry.kind == .say ? accent : Tellurion.dim)
                .frame(width: 12).padding(.top, 2)
            Text(verbatim: entry.text).font(Tellurion.font(11)).foregroundColor(entry.kind == .say ? Tellurion.text : Tellurion.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if entry.images > 0 {
                Label("\(entry.images)", systemImage: "photo").font(Tellurion.font(10)).foregroundColor(Tellurion.dim)
                    .padding(.top, 1)
                    .help("\(entry.images) image\(entry.images == 1 ? "" : "s") went with it")
            }
        }
    }

    static func symbol(_ kind: OrchestratorBrain.Entry.Kind) -> String {
        switch kind {
        case .user: return "person.fill"
        case .say: return "sparkle"
        case .action: return "arrow.turn.down.right"
        case .event: return "circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

/// Every entry since the orchestrator was last reset, newest at the bottom.
struct OrchestratorLogView: View {
    let log: [OrchestratorBrain.Entry]
    let accent: Color

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(log) { entry in OrchestratorEntryRow(entry: entry, accent: accent).id(entry.id) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if let last = log.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: log.count) { _ in
                if let last = log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

/// A round button in the command row: send, stop, the microphone.
struct OrchestratorRoundButton: View {
    let symbol: String
    let help: String
    var filled = false
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                .foregroundColor(filled ? Tellurion.ink : Tellurion.muted)
                .frame(width: 26, height: 26)
                .background(Circle().fill(filled ? accent : Tellurion.panel))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One wired agent: its logo, name, agent and role, and status; on hover, what you can do
/// with it. Click it to go to its terminal.
struct OrchestratorWiredRow: View {
    /// A small button shown while the pointer is over the row.
    struct Action {
        let symbol: String
        let help: String
        let run: () -> Void
    }

    let row: OrchestratorRow
    let actions: [Action]
    let focus: () -> Void
    let editRole: () -> Void
    let unwire: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let kind = row.kind {
                    VerticalTabAgentLogo(kind: kind, tint: Tellurion.text)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundColor(Tellurion.muted)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(Tellurion.font(12, weight: .semibold)).foregroundColor(Tellurion.text).lineLimit(1)
                Text(row.detail).font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                ForEach(actions.indices, id: \.self) { index in
                    icon(actions[index].symbol, actions[index].help, action: actions[index].run)
                }
            } else if row.paused {
                BoardPausedPill()
            } else if row.kind != nil {
                AgentStatusPill(activity: row.activity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Tellurion.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: focus)
        .contextMenu {
            Button("Go to It", action: focus)
            Button("Role…", action: editRole)
            Button("Unwire", action: unwire)
        }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(Tellurion.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif
