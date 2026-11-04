#if os(macOS)
import AppKit
import SwiftUI

/// The Git panel's jj half: the changes around the working copy, bookmarks, and the
/// operation log, where any jj command (an agent's included) can be undone.
final class JJPanelModel: ObservableObject {
    struct Change: Identifiable, Equatable {
        let changeID: String
        let commitID: String
        let isWorkingCopy: Bool
        let bookmarks: [String]
        let conflict: Bool
        let empty: Bool
        let immutable: Bool
        let age: String
        let author: String
        let description: String
        var id: String { commitID }
    }

    struct Bookmark: Identifiable, Equatable {
        let name: String
        let target: String
        /// Remotes it's pushed to (`origin`…), with commits not yet pushed / not yet pulled.
        var remotes: [(name: String, ahead: Int, behind: Int)] = []
        var id: String { name }

        static func == (a: Bookmark, b: Bookmark) -> Bool {
            a.name == b.name && a.target == b.target && a.remotes.map(\.name) == b.remotes.map(\.name)
                && a.remotes.map(\.ahead) == b.remotes.map(\.ahead) && a.remotes.map(\.behind) == b.remotes.map(\.behind)
        }
    }

    struct Operation: Identifiable, Equatable {
        let id: String
        let age: String
        let description: String
    }

    let root: String
    @Published private(set) var changes: [Change] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var operations: [Operation] = []
    /// Files changed in the working-copy change.
    @Published private(set) var changedFiles = 0
    /// Remotes to fetch from and push to; none in a repository that's only local.
    @Published private(set) var hasRemote = true
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.jjpanel", qos: .userInitiated)

    init(root: String) {
        self.root = root
    }

    var workingCopy: Change? { changes.first { $0.isWorkingCopy } }

    /// Whether `bookmark` is on a remote, for offering to open a pull request.
    func isPushed(_ bookmark: String?) -> Bool {
        guard let bookmark else { return false }
        return bookmarks.first { $0.name == bookmark }?.remotes.isEmpty == false
    }

    func load() {
        let root = self.root
        queue.async { [weak self] in
            // Opening the panel records the working copy, as any jj command would.
            let files = JJ.run(["diff", "--summary", "-r", "@"], in: root).output
                .split(separator: "\n").count
            let template = #"change_id.shortest(8) ++ "\t" ++ commit_id.short(8) ++ "\t" ++ if(current_working_copy, "@", "") ++ "\t" ++ local_bookmarks.map(|b| b.name()).join(" ") ++ "\t" ++ if(conflict, "c", "") ++ if(empty, "e", "") ++ if(immutable, "i", "") ++ "\t" ++ committer.timestamp().ago() ++ "\t" ++ author.name() ++ "\t" ++ description.first_line() ++ "\n""#
            // The working copy's line, other unfinished lines of work, and what they sit on.
            let changes = JJ.run(["log", "--no-graph", "-n", "14", "-r", "ancestors(@, 8) | heads(mutable())", "-T", template],
                                 in: root, snapshot: false).output
                .split(separator: "\n").compactMap { line -> Change? in
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 8 else { return nil }
                    return Change(changeID: f[0], commitID: f[1], isWorkingCopy: f[2] == "@",
                                  bookmarks: f[3].split(separator: " ").map(String.init),
                                  conflict: f[4].contains("c"), empty: f[4].contains("e"), immutable: f[4].contains("i"),
                                  age: f[5], author: f[6], description: f[7...].joined(separator: "\t"))
                }
                // The root commit says nothing.
                .filter { $0.changeID != "zzzzzzzz" }
            let bookmarkTemplate = #"name ++ "\t" ++ if(remote, remote, "") ++ "\t" ++ if(tracked, "t", "") ++ "\t" ++ if(remote, tracking_ahead_count.lower() ++ "\t" ++ tracking_behind_count.lower(), "\t") ++ "\t" ++ if(normal_target, normal_target.change_id().shortest(8), "?") ++ "\n""#
            var bookmarks: [Bookmark] = []
            for line in JJ.run(["bookmark", "list", "--all-remotes", "-T", bookmarkTemplate], in: root, snapshot: false).output
                .split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 6 else { continue }
                if f[1].isEmpty {
                    bookmarks.append(Bookmark(name: f[0], target: f[5]))
                } else if f[1] != "git", f[2] == "t", let index = bookmarks.firstIndex(where: { $0.name == f[0] }) {
                    // "ahead" here counts what the remote has that we don't, so it's what to pull.
                    bookmarks[index].remotes.append((f[1], Int(f[4]) ?? 0, Int(f[3]) ?? 0))
                }
            }
            let operations = JJ.run(["op", "log", "--no-graph", "-n", "8",
                                     "-T", #"id.short(12) ++ "\t" ++ time.end().ago() ++ "\t" ++ description.first_line() ++ "\n""#],
                                    in: root, snapshot: false).output
                .split(separator: "\n").compactMap { line -> Operation? in
                    let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 3 else { return nil }
                    return Operation(id: f[0], age: f[1], description: JJ.shortenHashes(f[2]))
                }
            let remotes = JJ.run(["git", "remote", "list"], in: root, snapshot: false)
            let hasRemote = !remotes.ok || !remotes.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasRemote = hasRemote
                self.changedFiles = files
                self.changes = changes
                self.bookmarks = bookmarks
                self.operations = operations
                self.loaded = true
                if let bookmark = VerticalTabsGit.shared.info[root]?.jj?.bookmark {
                    GitHubPulls.shared.fetch(root: root, branch: bookmark)
                }
            }
        }
    }

    // MARK: Actions

    func newChange(on change: Change? = nil) {
        run(["new"] + (change.map { [$0.changeID] } ?? []), done: change.map { "New change on \($0.changeID)" } ?? "Started a new change")
    }

    func describe(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        run(["describe", "-m", message], done: "Described the working copy")
    }

    /// Describes the working copy and starts a new change on top: jj's "commit".
    func commit(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        run(["commit", "-m", message], done: "Committed")
    }

    func edit(_ change: Change) { run(["edit", change.changeID], done: "Editing \(change.changeID)") }
    func squash() { run(["squash"], done: "Squashed into the parent") }
    func abandon(_ change: Change) { run(["abandon", change.changeID], done: "Abandoned \(change.changeID)") }
    func undo() { run(["undo"], done: "Undid the last operation") }
    func restore(_ operation: Operation) { run(["op", "restore", operation.id], done: "Restored to operation \(operation.id)") }
    func fetch() { run(["git", "fetch"], done: "Fetched") }
    func push(_ bookmark: Bookmark) { run(["git", "push", "-b", bookmark.name], done: "Pushed \(bookmark.name)") }

    /// Points a bookmark at the working-copy change, or at its parent while the working copy
    /// is empty (right after a commit, where the work is).
    func setBookmark(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let target = workingCopy?.empty == true ? "@-" : "@"
        run(["bookmark", "set", name, "-r", target, "--allow-backwards"], done: "\(name) is on \(target == "@" ? "the working copy" : "its parent")")
    }

    private func run(_ args: [String], done: String) {
        busy = true
        error = nil
        notice = nil
        let root = self.root
        queue.async { [weak self] in
            let result = JJ.run(args, in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if result.ok {
                    self.notice = done
                } else {
                    let message = (result.error.isEmpty ? result.output : result.error)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.error = message.isEmpty ? "jj \(args.first ?? "") failed" : String(message.prefix(400))
                }
                VerticalTabsGit.shared.refreshNow(root: root)
                self.load()
            }
        }
    }
}

/// The jj sections of the Git panel, below the pull request.
struct JJPanelSections: View {
    @ObservedObject var model: JJPanelModel
    @State private var message = ""
    @State private var newBookmark = ""
    @State private var naming = false
    @State private var armed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            workingCopySection
            changesSection
            bookmarksSection
            operationsSection
        }
    }

    // MARK: Working copy

    private var workingCopySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TellurionSectionLabel("Working copy") {
                Button("New change") { model.newChange() }
                    .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                    .disabled(model.busy)
                    .help("jj new: start a fresh change on top of this one")
            }
            if let change = model.workingCopy {
                HStack(spacing: 6) {
                    Text(change.changeID).font(Tellurion.mono(10.5)).foregroundColor(Tellurion.gold)
                    Text(change.description.isEmpty ? "No description yet" : change.description)
                        .font(Tellurion.font(10.5)).foregroundColor(change.description.isEmpty ? Tellurion.dim : Tellurion.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(change.empty ? "empty" : "\(model.changedFiles) file\(model.changedFiles == 1 ? "" : "s")")
                        .font(Tellurion.font(9.5)).foregroundColor(Tellurion.dim)
                }
                if change.conflict {
                    Text("This change has conflicts. Resolve them in the files, or with jj resolve.")
                        .font(Tellurion.font(10)).foregroundColor(Tellurion.danger).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    TextField(change.description.isEmpty ? "Describe this change" : change.description, text: $message)
                        .textFieldStyle(.roundedBorder).font(Tellurion.font(11))
                    Button("Describe") { model.describe(message); message = "" }
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                        .help("jj describe: set the working copy's description")
                    Button("Commit") { model.commit(message); message = "" }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || model.busy || change.empty)
                        .help("jj commit: describe it and start a new change on top")
                }
                if !change.empty, let parent = model.changes.first(where: { !$0.isWorkingCopy }), !parent.immutable {
                    small("Squash into \(parent.changeID)", color: Tellurion.muted) { model.squash() }
                        .help("jj squash: move the working copy's edits into its parent")
                }
            } else {
                Text(model.loaded ? "No working copy here" : "…").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
            }
        }
    }

    // MARK: Changes

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            TellurionSectionLabel("Changes")
            ForEach(model.changes) { change in changeRow(change) }
        }
    }

    private func changeRow(_ change: JJPanelModel.Change) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(change.isWorkingCopy ? "@" : "○").font(Tellurion.mono(10))
                .foregroundColor(change.isWorkingCopy ? Tellurion.gold : Tellurion.dim).frame(width: 10)
            Text(change.changeID).font(Tellurion.mono(10)).foregroundColor(change.immutable ? Tellurion.dim : Tellurion.bronze)
            ForEach(change.bookmarks, id: \.self) { name in
                Text(name).font(Tellurion.mono(9.5)).foregroundColor(Tellurion.gold)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Tellurion.gold.opacity(0.12)))
            }
            Text(change.description.isEmpty ? (change.empty ? "(empty)" : "(no description)") : change.description)
                .font(Tellurion.font(10.5))
                .foregroundColor(change.description.isEmpty ? Tellurion.dim : Tellurion.text).lineLimit(1)
            if change.conflict {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(Tellurion.danger)
            }
            Spacer(minLength: 4)
            Text(change.age).font(Tellurion.font(9.5)).foregroundColor(Tellurion.dim).lineLimit(1)
            // A menu's label only draws one line of text, so the actions sit in their own menu.
            Menu {
                changeActions(change)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 9, weight: .bold)).foregroundColor(Tellurion.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .disabled(model.busy)
            .help("Edit, start a new change on top, copy, or abandon")
        }
        .contentShape(Rectangle())
        .contextMenu { changeActions(change) }
        .help("\(change.author) · commit \(change.commitID)")
    }

    @ViewBuilder
    private func changeActions(_ change: JJPanelModel.Change) -> some View {
        if !change.isWorkingCopy && !change.immutable {
            Button("Edit This Change") { model.edit(change) }
        }
        Button("New Change on Top") { model.newChange(on: change) }
        Button("Copy Change ID") { copy(change.changeID) }
        Button("Copy Commit ID") { copy(change.commitID) }
        if !change.immutable {
            Divider()
            Button("Abandon…") { confirmAbandon(change) }
        }
    }

    private func confirmAbandon(_ change: JJPanelModel.Change) {
        let alert = NSAlert()
        alert.messageText = "Abandon \(change.changeID)?"
        alert.informativeText = "Its edits are dropped and changes on top of it move to its parent. "
            + "Undo in Operations brings it back."
        alert.alertStyle = .warning
        let abandon = alert.addButton(withTitle: "Abandon")
        abandon.keyEquivalent = ""
        abandon.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { model.abandon(change) }
    }

    // MARK: Bookmarks

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TellurionSectionLabel("Bookmarks") {
                HStack(spacing: 10) {
                    if model.hasRemote {
                        Button("Fetch") { model.fetch() }
                            .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                            .disabled(model.busy).help("jj git fetch")
                    } else {
                        Text("no remote").font(Tellurion.font(10)).foregroundColor(Tellurion.dim)
                    }
                    Button(naming ? "Cancel" : "New…") { naming.toggle(); newBookmark = "" }
                        .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                }
            }
            if naming {
                HStack(spacing: 6) {
                    TextField("bookmark-name", text: $newBookmark, onCommit: createBookmark)
                        .textFieldStyle(.roundedBorder).font(Tellurion.mono(11))
                    Button("Set", action: createBookmark).disabled(newBookmark.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("On the working copy, or on its parent while the working copy is empty. An existing bookmark moves here.")
                    .font(Tellurion.font(10)).foregroundColor(Tellurion.dim).fixedSize(horizontal: false, vertical: true)
            }
            if model.bookmarks.isEmpty {
                Text(model.loaded ? "No bookmarks" : "…").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
            }
            ForEach(model.bookmarks.prefix(10)) { bookmark in
                HStack(spacing: 6) {
                    Text(bookmark.name).font(Tellurion.mono(11)).foregroundColor(Tellurion.text).lineLimit(1).truncationMode(.middle)
                    Text(bookmark.target).font(Tellurion.mono(9.5)).foregroundColor(Tellurion.dim)
                    Spacer(minLength: 4)
                    Text(syncText(bookmark)).font(Tellurion.font(9.5)).foregroundColor(Tellurion.dim).lineLimit(1)
                    if model.hasRemote {
                        small("Push") { model.push(bookmark) }
                            .help("jj git push -b \(bookmark.name)")
                    }
                }
            }
        }
    }

    private func syncText(_ bookmark: JJPanelModel.Bookmark) -> String {
        guard let remote = bookmark.remotes.first else { return "not pushed" }
        var parts: [String] = []
        if remote.ahead > 0 { parts.append("↑\(remote.ahead)") }
        if remote.behind > 0 { parts.append("↓\(remote.behind)") }
        return parts.isEmpty ? "on \(remote.name)" : parts.joined(separator: " ")
    }

    private func createBookmark() {
        model.setBookmark(newBookmark)
        naming = false
        newBookmark = ""
    }

    // MARK: Operations

    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            TellurionSectionLabel("Operations") {
                Button("Undo last") { model.undo() }
                    .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                    .disabled(model.busy || model.operations.count < 2)
                    .help("jj undo: reverse the most recent operation")
            }
            ForEach(Array(model.operations.enumerated()), id: \.element.id) { index, operation in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(operation.description).font(Tellurion.font(10.5))
                        .foregroundColor(index == 0 ? Tellurion.text : Tellurion.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(operation.age).font(Tellurion.font(9.5)).foregroundColor(Tellurion.dim).lineLimit(1)
                    if index > 0 {
                        if armed == operation.id {
                            small("Restore?", color: Tellurion.danger) { model.restore(operation); armed = nil }
                        } else {
                            small("Restore", color: Tellurion.muted) {
                                armed = operation.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if armed == operation.id { armed = nil } }
                            }
                            .help("jj op restore: put the whole repository back to just after this")
                        }
                    }
                }
            }
            Text("Every jj command is recorded here, including an agent's, so any of them can be undone.")
                .font(Tellurion.font(10)).foregroundColor(Tellurion.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func small(_ title: String, color: Color = Tellurion.gold, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Tellurion.font(10, weight: .semibold))
            .foregroundColor(color)
            .disabled(model.busy)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.notice = "Copied \(text)"
    }
}
#endif
