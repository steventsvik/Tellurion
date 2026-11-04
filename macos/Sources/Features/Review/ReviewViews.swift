#if os(macOS)
import AppKit
import SwiftUI

extension ReviewInbox {
    static func toggle() {
        if AgentToolWindows.isOpen(windowID) {
            AgentToolWindows.close(id: windowID)
        } else {
            show()
        }
    }

    static func show(selecting item: ReviewItem? = nil) {
        guard TellurionSettings.isOn(.review) else { return }
        if let item { ReviewSelection.shared.itemID = item.id }
        AgentToolWindows.show(id: windowID, title: "Review Changes", size: NSSize(width: 1240, height: 780)) {
            ReviewInboxView()
        }
    }
}

/// Which item and file the review window shows. Shared so "Review" buttons elsewhere can
/// open the window on a specific item.
final class ReviewSelection: ObservableObject {
    static let shared = ReviewSelection()
    @Published var itemID: UUID?
    @Published var filePath: String?
}

private enum ReviewColors {
    static let added = Tellurion.live
    static let removed = Tellurion.danger
    static let accent = Tellurion.gold

    static func status(_ status: ReviewFile.Status) -> Color {
        switch status {
        case .added: return added
        case .modified: return Color(red: 0.4, green: 0.65, blue: 1.0)
        case .deleted: return removed
        case .renamed: return accent
        }
    }
}

private struct ReviewInboxView: View {
    @ObservedObject private var inbox = ReviewInbox.shared
    @ObservedObject private var selection = ReviewSelection.shared

    private var item: ReviewItem? {
        inbox.items.first { $0.id == selection.itemID } ?? inbox.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if inbox.items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    itemList.frame(width: 270)
                    Divider()
                    if let item {
                        ReviewItemView(item: item)
                    }
                }
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .onAppear { if let item { inbox.markSeen(item) } }
        .onChange(of: selection.itemID) { _ in if let item { inbox.markSeen(item) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TellurionWindowTitle(icon: .inbox, title: "Review Changes",
                               subtitle: inbox.items.isEmpty ? "Nothing waiting" :
                                   "\(inbox.items.count) agent\(inbox.items.count == 1 ? "" : "s") with changes · \(inbox.unseenCount) new")
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            TellurionSigil(size: 56)
            Text("All caught up").font(Tellurion.font(16))
            Text("When Claude Code or Codex finishes working, its changes show up here to review: comment on lines and send them back, or undo files. In a git repository you can also commit or open a pull request.")
                .font(Tellurion.font(12)).foregroundColor(Tellurion.muted).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(inbox.items) { entry in
                    ReviewItemRow(item: entry, selected: entry.id == item?.id)
                        .onTapGesture {
                            selection.itemID = entry.id
                            selection.filePath = nil
                        }
                }
            }
            .padding(10)
        }
        .background(Tellurion.text.opacity(0.025))
    }
}

private struct ReviewItemRow: View {
    let item: ReviewItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AgentBadge(kind: item.agent, size: 22)
                Text(item.repoName).font(Tellurion.font(13)).lineLimit(1)
                Spacer(minLength: 4)
                if item.unseen && item.stage == .ready {
                    PixelDot(color: ReviewColors.accent, blinking: true, size: 6)
                }
            }
            if let task = item.task {
                Text(task).font(Tellurion.font(11.5)).foregroundColor(Tellurion.text.opacity(0.8)).lineLimit(2)
            }
            HStack(spacing: 6) {
                stageChip
                Text("\(item.files.count) file\(item.files.count == 1 ? "" : "s")").foregroundColor(Tellurion.muted)
                Text("+\(item.added)").foregroundColor(ReviewColors.added)
                Text("−\(item.removed)").foregroundColor(ReviewColors.removed)
                Spacer(minLength: 0)
                Text(RelativeDateTimeFormatter().localizedString(for: item.updated, relativeTo: Date()))
                    .foregroundColor(Tellurion.muted)
            }
            .font(Tellurion.font(10.5).monospacedDigit())
        }
        .padding(10)
        .background(Rectangle().fill(selected ? ReviewColors.accent.opacity(0.16) : Tellurion.text.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? ReviewColors.accent.opacity(0.7) : Tellurion.text.opacity(0.08)))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stageChip: some View {
        let (label, color): (String, Color) = {
            switch item.stage {
            case .ready: return ("Ready", ReviewColors.added)
            case .feedbackSent: return ("Feedback sent", .orange)
            case .working: return ("Working", Color(red: 0.36, green: 0.62, blue: 1.0))
            }
        }()
        Text(label)
            .font(Tellurion.font(9.5))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Rectangle().fill(color.opacity(0.16)))
    }
}

// MARK: - One agent's changes

private struct ReviewItemView: View {
    let item: ReviewItem
    @ObservedObject private var selection = ReviewSelection.shared
    @State private var commitMessage = ""
    @State private var showCommit = false
    @State private var message: String?

    private var file: ReviewFile? {
        item.files.first { $0.path == selection.filePath } ?? item.files.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fileList.frame(width: 250)
                Divider()
                if let file {
                    ReviewDiffView(item: item, file: file)
                } else {
                    Spacer()
                }
            }
            Divider()
            actionBar
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if let task = item.task {
                    Text(task).font(Tellurion.font(12)).lineLimit(3)
                }
                Text((item.repoRoot as NSString).abbreviatingWithTildeInPath)
                    .font(Tellurion.font(10.5)).foregroundColor(Tellurion.muted).lineLimit(1).truncationMode(.head)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(item.files) { entry in
                        ReviewFileRow(item: item, file: entry, selected: entry.path == file?.path)
                            .onTapGesture { selection.filePath = entry.path }
                    }
                }
                .padding(6)
            }
        }
        .background(Tellurion.text.opacity(0.02))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let message {
                Text(message).font(Tellurion.font(11.5)).foregroundColor(.orange).lineLimit(2).textSelection(.enabled)
            } else {
                let reviewed = item.files.filter { item.decision($0) == .accepted }.count
                Text("\(reviewed)/\(item.files.count) files approved · \(item.comments.count) comment\(item.comments.count == 1 ? "" : "s")")
                    .font(Tellurion.font(11.5)).foregroundColor(Tellurion.muted)
            }
            Spacer()
            if ReviewInbox.shared.surface(for: item) != nil {
                Button { ReviewInbox.shared.focusAgent(item) } label: { Label("Go to agent", systemImage: "arrow.right.circle") }
            }
            if item.isRepository {
                Button { ReviewInbox.shared.openPullRequest(item) } label: { Label("Pull request", systemImage: "arrow.triangle.pull") }
                    .help("Push this branch and open GitHub's pull request page (in a new tab)")
                Button { showCommit = true } label: { Label("Commit…", systemImage: "checkmark.circle") }
                    .popover(isPresented: $showCommit, arrowEdge: .top) { commitPopover }
            }
            Button { ReviewInbox.shared.acceptAll(item) } label: { Label("Looks good", systemImage: "hand.thumbsup.fill") }
                .help("Accept everything; the next review starts from here")
            sendButton
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Tellurion.text.opacity(0.03))
    }

    private var sendButton: some View {
        let count = item.comments.count
        let canSend = count > 0 && ReviewInbox.shared.surface(for: item) != nil
        return Button {
            if !ReviewInbox.shared.sendFeedback(item) {
                message = "The agent's tab is closed, so the feedback can't be sent. Copy it from a comment instead."
            } else {
                message = nil
                ReviewInbox.shared.focusAgent(item)
            }
        } label: {
            HStack(spacing: 7) {
                AgentSprite(kind: item.agent, pixel: 1.2)
                Text(count == 0 ? "Send feedback" : "Send \(count) comment\(count == 1 ? "" : "s") to \(item.agent.displayName)")
                    .font(Tellurion.font(11.5, weight: .semibold))
            }
            .foregroundColor(canSend ? Tellurion.ink : Tellurion.dim)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(canSend ? Tellurion.gold : Tellurion.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(canSend ? Tellurion.gold : Tellurion.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(count == 0 ? "Add comments on lines first (hover a line and click +)" : "Types your comments into the agent's prompt and sends them")
    }

    private var commitPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit \(item.files.count) file\(item.files.count == 1 ? "" : "s")").font(Tellurion.font(13))
            TextEditor(text: $commitMessage)
                .font(Tellurion.font(12))
                .frame(width: 340, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Tellurion.text.opacity(0.15)))
            HStack {
                Spacer()
                Button("Cancel") { showCommit = false }
                Button("Commit") {
                    ReviewInbox.shared.commit(item, message: commitMessage) { error in
                        message = error.map { "Commit failed: \($0)" }
                        showCommit = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onAppear { if commitMessage.isEmpty { commitMessage = item.task ?? "" } }
    }
}

private struct ReviewFileRow: View {
    let item: ReviewItem
    let file: ReviewFile
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(file.status.rawValue)
                .font(Tellurion.font(9.5))
                .foregroundColor(.black.opacity(0.75))
                .frame(width: 15, height: 15)
                .background(Rectangle().fill(ReviewColors.status(file.status)))
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).font(Tellurion.font(12)).lineLimit(1)
                if !file.folder.isEmpty {
                    Text(file.folder).font(Tellurion.font(10)).foregroundColor(Tellurion.muted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            let comments = item.comments(on: file).count
            if comments > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble.fill")
                    Text("\(comments)")
                }
                .font(Tellurion.font(9.5))
                .foregroundColor(ReviewColors.accent)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text("+\(file.added)").foregroundColor(ReviewColors.added)
                Text("−\(file.removed)").foregroundColor(ReviewColors.removed)
            }
            .font(Tellurion.font(9.5).monospacedDigit())
            Image(systemName: item.decision(file) == .accepted ? "checkmark.circle.fill" : "circle")
                .font(Tellurion.font(12))
                .foregroundColor(item.decision(file) == .accepted ? ReviewColors.added : Tellurion.muted.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Rectangle().fill(selected ? ReviewColors.accent.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Diff with comments

private struct ReviewDiffView: View {
    let item: ReviewItem
    let file: ReviewFile
    @State private var composing: ReviewComment.Anchor?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.status.rawValue)
                    .font(Tellurion.font(10))
                    .foregroundColor(.black.opacity(0.75))
                    .frame(width: 17, height: 17)
                    .background(Rectangle().fill(ReviewColors.status(file.status)))
                Text(file.path).font(Tellurion.font(12.5)).lineLimit(1).truncationMode(.middle)
                if let old = file.oldPath {
                    Text("← \(old)").font(Tellurion.font(11)).foregroundColor(Tellurion.muted).lineLimit(1)
                }
                Spacer()
                Button {
                    confirmUndo()
                } label: { Label("Undo file", systemImage: "arrow.uturn.backward") }
                    .help("Put this file back the way it was before the agent changed it")
                let accepted = item.decision(file) == .accepted
                Button {
                    ReviewInbox.shared.setDecision(accepted ? .pending : .accepted, for: file, in: item)
                    if !accepted { selectNextFile() }
                } label: {
                    Label(accepted ? "Approved" : "Approve", systemImage: accepted ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .tint(ReviewColors.added)
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .opacity(accepted ? 1 : 0.9)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if file.isBinary {
                Text("Binary file changed.").foregroundColor(Tellurion.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            Text(hunk.header)
                                .font(Tellurion.mono(10.5))
                                .foregroundColor(ReviewColors.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(ReviewColors.accent.opacity(0.08))
                            ForEach(hunk.lines) { line in
                                ReviewLineRow(line: line) {
                                    composing = line.anchor
                                    draft = ""
                                }
                                ForEach(item.comments(on: file).filter { $0.anchor == line.anchor }) { comment in
                                    commentBubble(comment)
                                }
                                if composing == line.anchor {
                                    composer(for: line)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func commentBubble(_ comment: ReviewComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Rectangle().fill(Tellurion.raised)
                Text("YOU").font(Tellurion.font(7)).foregroundColor(Tellurion.gold)
            }
            .frame(width: 20, height: 20)
            Text(comment.text).font(Tellurion.font(12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            Button { ReviewInbox.shared.removeComment(comment, in: item) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundColor(Tellurion.muted)
        }
        .padding(10)
        .background(Rectangle().fill(ReviewColors.accent.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ReviewColors.accent.opacity(0.5)))
        .padding(.leading, 96).padding(.trailing, 14).padding(.vertical, 4)
    }

    private func composer(for line: ReviewLine) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $draft)
                .font(Tellurion.font(12))
                .frame(height: 64)
                .padding(4)
                .background(Rectangle().fill(Tellurion.ink))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(ReviewColors.accent.opacity(0.7), lineWidth: 1.2))
            HStack {
                Text("Line \(line.anchor.line) · sent to \(item.agent.displayName) with your other comments")
                    .font(Tellurion.font(10.5)).foregroundColor(Tellurion.muted)
                Spacer()
                Button("Cancel") { composing = nil }
                Button("Add comment") {
                    ReviewInbox.shared.addComment(draft, on: line, file: file, in: item)
                    composing = nil
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .tint(ReviewColors.accent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Rectangle().fill(Tellurion.text.opacity(0.05)))
        .padding(.leading, 96).padding(.trailing, 14).padding(.vertical, 4)
    }

    private func selectNextFile() {
        guard let index = item.files.firstIndex(of: file) else { return }
        let rest = item.files[(index + 1)...] + item.files[..<index]
        if let next = rest.first(where: { item.decision($0) != .accepted && $0.path != file.path }) {
            ReviewSelection.shared.filePath = next.path
        }
    }

    private func confirmUndo() {
        let alert = NSAlert()
        alert.messageText = "Undo the agent's changes to \(file.name)?"
        alert.informativeText = file.status == .added
            ? "The file was created by the agent and will be deleted."
            : "The file goes back to how it was before the agent started. Other files aren't touched."
        alert.addButton(withTitle: "Undo file")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ReviewInbox.shared.undo(file, in: item)
    }
}

private struct ReviewLineRow: View {
    let line: ReviewLine
    let onComment: () -> Void
    @State private var hovering = false

    var body: some View {
        let color: Color? = line.kind == .added ? ReviewColors.added : line.kind == .removed ? ReviewColors.removed : nil
        HStack(spacing: 0) {
            ZStack {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 38, alignment: .trailing)
                    .opacity(hovering ? 0 : 1)
                if hovering {
                    Button(action: onComment) {
                        Image(systemName: "plus")
                            .font(Tellurion.font(9))
                            .foregroundColor(.white)
                            .frame(width: 17, height: 17)
                            .background(Rectangle().fill(ReviewColors.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Comment on this line")
                }
            }
            .frame(width: 42)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundColor(color ?? .secondary)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundColor(Tellurion.text.opacity(line.kind == .context ? 0.72 : 0.95))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Tellurion.mono(11.5))
        .foregroundColor(Tellurion.muted)
        .padding(.vertical, 1)
        .background((color ?? .clear).opacity(hovering ? 0.2 : 0.11))
        .overlay(alignment: .leading) {
            if let color { Rectangle().fill(color).frame(width: 2.5) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Sidebar

/// Sidebar header button: opens the review window, with the number of new reviews.
struct ReviewHeaderButton: View {
    @ObservedObject private var inbox = ReviewInbox.shared

    var body: some View {
        TellurionIconButton(icon: .inbox, help: "Review changes (⌃⌘I)", tint: Tellurion.gold,
                          badge: inbox.unseenCount, badgeColor: Tellurion.gold, action: ReviewInbox.toggle)
    }
}

/// "Review 3 files" on a pane's row when its agent has changes waiting.
struct ReviewPaneChip: View {
    let surface: Ghostty.SurfaceView?
    @ObservedObject private var inbox = ReviewInbox.shared

    var body: some View {
        if let surface, let item = inbox.item(for: surface), item.stage == .ready {
            Button {
                ReviewInbox.show(selecting: item)
            } label: {
                HStack(spacing: 4) {
                    PixelIconView(icon: .inbox, color: Tellurion.ink, pixel: 0.8)
                    Text("Review \(item.files.count)")
                }
                .font(Tellurion.font(9.5))
                .foregroundColor(Tellurion.ink)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Tellurion.gold)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Review this agent's changes")
        }
    }
}
#endif
