#if os(macOS)
import AppKit
import Combine
import SwiftUI

private enum BlockColors {
    static let success = Tellurion.live
    static let failure = Tellurion.danger
    static let neutral = Tellurion.muted

    static func color(_ block: CommandBlock) -> Color {
        guard let code = block.exitCode else { return neutral }
        if code == 0 { return success }
        return block.failed ? failure : neutral
    }

    static func agentButton(_ kind: VerticalTabAgentKind) -> Color {
        kind == .codex ? Color(red: 0.06, green: 0.64, blue: 0.5) : kind.brandColor
    }
}

// MARK: - Failure chip

/// Floats over a pane when a command fails: what failed, and one click to have an agent fix it.
struct CommandFailureChip: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject private var store = CommandBlocks.shared

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let block = store.failure(for: surfaceView) {
                    ViewThatFits(in: .horizontal) {
                        chip(block, compact: false)
                        chip(block, compact: true)
                    }
                        .padding(14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.failure(for: surfaceView)?.id)
    }

    private func chip(_ block: CommandBlock, compact: Bool) -> some View {
        HStack(spacing: 10) {
            PixelDot(color: BlockColors.failure, blinking: true, size: 8, interval: 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.command)
                    .font(Tellurion.mono(12))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: compact ? 150 : 260, alignment: .leading)
                Text("failed · exit \(block.exitCode ?? 1) · \(block.durationText)")
                    .font(Tellurion.font(10.5)).foregroundColor(BlockColors.failure)
            }
            // An agent already working on this project gets it first: it has the context.
            if let agent = AgentHandoff.nearestAgent(to: surfaceView) {
                Button {
                    store.sendToAgent(block, from: surfaceView, to: agent.surface)
                } label: {
                    HStack(spacing: 5) {
                        VerticalTabAgentLogo(kind: agent.info.kind, tint: .white).frame(width: 11, height: 11)
                        Text(compact ? "Send" : "Send to \(agent.info.kind.displayName)")
                    }
                    .font(Tellurion.font(11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 5)
                    .background(Rectangle().fill(BlockColors.agentButton(agent.info.kind)))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Send the command, its output and what's changed to \(agent.info.kind.displayName) in \(agent.tab). "
                      + "It goes in when that agent finishes its turn.")
            }
            ForEach(AgentHandoff.targets, id: \.self) { kind in
                Button {
                    store.askAgent(kind, about: block, from: surfaceView)
                } label: {
                    HStack(spacing: 5) {
                        VerticalTabAgentLogo(kind: kind, tint: .white).frame(width: 11, height: 11)
                        Text(compact ? "Fix" : kind == .claude ? "Fix with Claude" : "Fix with Codex")
                    }
                    .font(Tellurion.font(11.5))
                    .foregroundColor(.white)
                    .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 5)
                    .background(Rectangle().fill(BlockColors.agentButton(kind)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Opens \(kind.displayName) in a split with the command and its output")
            }
            Button {
                if let controller = TerminalWindows.controller(of: surfaceView.window) {
                    CommandBlocksPanel.shared.show(controller)
                }
            } label: {
                Image(systemName: "list.bullet.rectangle").font(Tellurion.font(12))
            }
            .buttonStyle(.plain)
            .foregroundColor(Tellurion.muted)
            .help("Show command history (⌃⌘B)")
            .accessibilityLabel("Show command history")
            Button { store.dismissFailure(on: surfaceView) } label: {
                Image(systemName: "xmark").font(Tellurion.font(10))
            }
            .buttonStyle(.plain)
            .foregroundColor(Tellurion.muted)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Tellurion.ink)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(BlockColors.failure.opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
        .fixedSize()
    }
}

// MARK: - History column

/// The column with the focused pane's recent commands as blocks.
struct CommandBlocksColumn: View {
    let controller: BaseTerminalController
    @ObservedObject private var store = CommandBlocks.shared
    @ObservedObject private var layout = WindowLayout.shared
    @State private var failedOnly = false
    @State private var focused: Ghostty.SurfaceView?
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let surface = focused ?? controller.focusedSurface
        let all = surface.map { store.blocks(for: $0) } ?? []
        let shown = Array((failedOnly ? all.filter(\.failed) : all).reversed())
        VStack(spacing: 0) {
            header(count: all.count, failures: all.filter(\.failed).count, surface: surface)
            Divider()
            if shown.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { block in
                            CommandBlockCard(block: block, surface: surface)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 400)
        .background(Tellurion.ink)
        .overlay(alignment: layout.isLeftOfTerminal(.history) ? .trailing : .leading) {
            Rectangle().fill(Tellurion.text.opacity(0.1)).frame(width: 1)
        }
        .onReceive(timer) { _ in
            // Follow the focused pane as it changes.
            if focused !== controller.focusedSurface { focused = controller.focusedSurface }
        }
    }

    private func header(count: Int, failures: Int, surface: Ghostty.SurfaceView?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command History").font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.gold)
                Text("\(count) command\(count == 1 ? "" : "s")\(failures > 0 ? " · \(failures) failed" : "") in this pane")
                    .font(Tellurion.font(10.5)).foregroundColor(Tellurion.muted)
            }
            Spacer()
            Picker("", selection: $failedOnly) {
                Text("All").tag(false)
                Text("Failed").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            Menu {
                Button("Clear history") { if let surface { store.clear(surface) } }
                Button("Close") { CommandBlocksPanel.shared.toggle(controller) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal").font(Tellurion.font(30)).foregroundColor(Tellurion.muted)
            Text(failedOnly ? "No failed commands" : "No commands yet").font(Tellurion.font(13))
            Text("Commands you run in this pane show up here with their output, exit code and time. Failed ones can be sent to an agent to fix.")
                .font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CommandBlockCard: View {
    let block: CommandBlock
    let surface: Ghostty.SurfaceView?
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        let color = BlockColors.color(block)
        let lines = block.output.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text("$").font(Tellurion.font(12)).foregroundColor(color)
                Text(block.command)
                    .font(Tellurion.mono(12))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                statusBadge(color)
                Label(block.durationText, systemImage: "timer")
                Text(RelativeDateTimeFormatter().localizedString(for: block.finished, relativeTo: Date()))
                if let cwd = block.cwd {
                    Text((cwd as NSString).lastPathComponent).lineLimit(1)
                }
                Spacer()
            }
            .font(Tellurion.font(10.5))
            .foregroundColor(Tellurion.muted)
            if !block.output.isEmpty && !block.isInteractive {
                let preview = Text((expanded ? lines[...] : lines.suffix(6)).joined(separator: "\n"))
                    .font(Tellurion.mono(10.5))
                    .foregroundColor(Tellurion.text.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if expanded {
                        ScrollView { preview }.frame(maxHeight: 360)
                    } else {
                        preview
                    }
                }
                .padding(8)
                .background(Rectangle().fill(Color.black.opacity(0.28)))
                if lines.count > 6 {
                    Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(Tellurion.font(10.5))
                        .foregroundColor(.accentColor)
                }
            }
            if hovering, let surface {
                actions(surface)
            }
        }
        .padding(10)
        .background(Rectangle().fill(Tellurion.text.opacity(hovering ? 0.07 : 0.045)))
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3).padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(block.failed ? color.opacity(0.45) : Tellurion.text.opacity(0.07)))
        .onHover { hovering = $0 }
    }

    private func statusBadge(_ color: Color) -> some View {
        let label: String
        if let code = block.exitCode {
            label = code == 0 ? "✓ ok" : "exit \(code)"
        } else {
            label = "done"
        }
        return Text(label)
            .font(Tellurion.font(10))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Rectangle().fill(color.opacity(0.16)))
    }

    private func actions(_ surface: Ghostty.SurfaceView) -> some View {
        HStack(spacing: 6) {
            small("Rerun", "arrow.clockwise") { CommandBlocks.shared.rerun(block, in: surface) }
                .help("Types the command at the prompt; press Return to run it")
            small("Copy", "doc.on.doc") { VerticalTabsActions.copy(block.command) }
            if !block.output.isEmpty {
                small("Copy output", "doc.plaintext") { VerticalTabsActions.copy(block.output) }
            }
            Spacer()
            ForEach(AgentHandoff.targets, id: \.self) { kind in
                Button {
                    CommandBlocks.shared.askAgent(kind, about: block, from: surface)
                } label: {
                    HStack(spacing: 4) {
                        VerticalTabAgentLogo(kind: kind, tint: .white).frame(width: 10, height: 10)
                        Text(block.failed ? "Fix" : "Explain")
                    }
                    .font(Tellurion.font(10.5))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Rectangle().fill(BlockColors.agentButton(kind)))
                }
                .buttonStyle(.plain)
                .help("\(block.failed ? "Fix" : "Explain") with \(kind.displayName)")
            }
        }
    }

    private func small(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Tellurion.font(10.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Rectangle().fill(Tellurion.text.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}
#endif
