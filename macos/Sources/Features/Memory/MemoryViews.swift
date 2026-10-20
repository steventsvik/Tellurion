#if os(macOS)
import AppKit
import SwiftUI

/// The Project Memory window: what Claude Code and Codex remember about the tab's project,
/// and the instruction files they load, with editing and deleting.
enum MemoryWindow {
    static func show(folder: String?) {
        guard ExtremeSettings.isOn(.memory) else { return }
        let folder = folder ?? NSHomeDirectory()
        // Fresh for this folder, never one left open for another project.
        AgentToolWindows.close(id: "memory")
        AgentToolWindows.show(id: "memory", title: "Project Memory", size: NSSize(width: 900, height: 620)) {
            MemoryWindowView(folder: folder)
        }
    }

    /// For the focused terminal of the frontmost window (a tab, or a tile on a board).
    static func showForFrontTab() {
        show(folder: TerminalWindows.front?.focusedSurface?.pwd)
    }
}

final class MemoryWindowModel: ObservableObject {
    let folder: String
    @Published private(set) var project: ProjectMemory.Project?
    @Published var selection: String?
    @Published var draft = ""
    @Published var search = ""
    @Published var error: String?

    init(folder: String) {
        self.folder = folder
        reload()
    }

    var selected: ProjectMemory.Note? {
        project?.notes.first { $0.id == selection }
    }

    var hasChanges: Bool {
        guard let selected, selected.editable else { return false }
        return draft != selected.raw
    }

    func notes(from source: ProjectMemory.Note.Source) -> [ProjectMemory.Note] {
        let all = project?.notes(from: source) ?? []
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter { ($0.title + " " + $0.summary + " " + $0.body).lowercased().contains(query) }
    }

    func reload(keeping id: String? = nil) {
        let folder = folder
        DispatchQueue.global(qos: .userInitiated).async {
            let project = ProjectMemory.load(folder: folder)
            DispatchQueue.main.async {
                self.project = project
                let wanted = id ?? self.selection
                let note = project.notes.first { $0.id == wanted } ?? project.notes.first
                self.select(note)
            }
        }
    }

    func select(_ note: ProjectMemory.Note?) {
        selection = note?.id
        draft = note?.editable == true ? note?.raw ?? "" : note?.body ?? ""
        error = nil
    }

    func save() {
        guard let selected else { return }
        do {
            try ProjectMemory.save(selected, text: draft)
            reload(keeping: selected.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete() {
        guard let selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(selected.title)”?"
        alert.informativeText = "Claude Code won't remember this anymore. The file and its line in MEMORY.md are removed; this can't be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try ProjectMemory.delete(selected)
            selection = nil
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MemoryWindowView: View {
    @StateObject private var model: MemoryWindowModel
    @ObservedObject private var settings = ExtremeSettings.shared

    init(folder: String) {
        _model = StateObject(wrappedValue: MemoryWindowModel(folder: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                ExtremeWindowTitle(icon: .memory, title: "Project Memory", subtitle: subtitle)
                Spacer()
                Button("Reload") { model.reload() }
                    .help("Read the files again")
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Extreme.line).frame(height: 1)
            HStack(spacing: 0) {
                list.frame(width: 300)
                Rectangle().fill(Extreme.line).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Extreme.line).frame(height: 1)
            footer.padding(.horizontal, 16).padding(.vertical, 9)
        }
        // A fixed preferred size: otherwise the window grows to fit long notes.
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity, minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        // Files change while the window is open (agents write notes mid-session).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.title == "Project Memory", !model.hasChanges { model.reload() }
        }
    }

    private var subtitle: String {
        guard let project = model.project else { return "Reading…" }
        let count = project.notes.filter { $0.source != .instructions }.count
        return "\(project.name) · \(count) remembered \(count == 1 ? "fact" : "facts")"
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .font(Extreme.font(12))
                .padding(10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ProjectMemory.Note.Source.allCases, id: \.self) { source in
                        section(source)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
        .background(Extreme.panel)
    }

    @ViewBuilder
    private func section(_ source: ProjectMemory.Note.Source) -> some View {
        let notes = model.notes(from: source)
        VStack(alignment: .leading, spacing: 4) {
            ExtremeSectionLabel(source.title) {
                Text("\(notes.count)").font(Extreme.font(10)).foregroundColor(Extreme.dim)
            }
            if notes.isEmpty {
                Text(emptyText(source))
                    .font(Extreme.font(11)).foregroundColor(Extreme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6).padding(.vertical, 2)
            }
            ForEach(notes) { note in row(note) }
        }
    }

    private func emptyText(_ source: ProjectMemory.Note.Source) -> String {
        if !model.search.isEmpty { return "No matches" }
        switch source {
        case .claude: return "Nothing yet. Claude Code saves notes here when you tell it to remember something, or when it learns something worth keeping."
        case .codex: return "Nothing for this project. Codex writes memories after its sessions when memories are on in Codex."
        case .instructions: return "No CLAUDE.md or AGENTS.md."
        }
    }

    private func row(_ note: ProjectMemory.Note) -> some View {
        let selected = model.selection == note.id
        return Button {
            guard !model.hasChanges || confirmDiscard() else { return }
            model.select(note)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.title).font(Extreme.font(12, weight: .semibold))
                        .foregroundColor(selected ? Extreme.gold : Extreme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if note.source == .claude {
                        Text(note.kind).font(Extreme.font(9.5)).foregroundColor(Extreme.muted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Extreme.raised))
                    }
                }
                Text(note.summary).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(2)
                if let modified = note.modified, note.source != .codex {
                    Text(Self.age(modified)).font(Extreme.font(9.5)).foregroundColor(Extreme.dim)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Extreme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(note.title), \(note.summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard your changes?"
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let note = model.selected {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title).font(Extreme.font(15, weight: .semibold)).foregroundColor(Extreme.text)
                        .lineLimit(2)
                    Text(location(note)).font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if note.source == .codex {
                    Text("Codex keeps this in its own memory file and rewrites it after sessions, so it's read-only here. To change it, tell Codex.")
                        .font(Extreme.font(11)).foregroundColor(Extreme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Group {
                    if note.editable {
                        TextEditor(text: $model.draft)
                            .scrollContentBackground(.hidden)
                    } else {
                        ScrollView {
                            Text(model.draft)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 5)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Extreme.text)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Extreme.panel))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Extreme.line, lineWidth: 1))
                if let error = model.error {
                    Text(error).font(Extreme.font(11)).foregroundColor(Extreme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.path)])
                    }
                    if note.source == .claude {
                        Button("Delete…") { model.delete() }
                            .help("Claude Code forgets this")
                    }
                    Spacer()
                    if note.editable {
                        Button("Revert") { model.select(note) }
                            .disabled(!model.hasChanges)
                        Button("Save") { model.save() }
                            .buttonStyle(ExtremeButtonStyle(prominent: true))
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!model.hasChanges)
                    }
                }
            }
            .padding(16)
        } else {
            VStack(spacing: 8) {
                Text(model.project == nil ? "Reading…" : "Nothing remembered for this project yet.")
                    .font(Extreme.font(12)).foregroundColor(Extreme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func location(_ note: ProjectMemory.Note) -> String {
        let path = (note.path as NSString).abbreviatingWithTildeInPath
        return note.source == .instructions ? "\(note.summary) · \(path)" : path
    }

    private static func age(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Updated " + formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: settings.isOn(.sharedMemory) ? "arrow.left.arrow.right" : "arrow.left.arrow.right.slash")
                .font(.system(size: 10))
            Text(settings.isOn(.sharedMemory)
                 ? "Shared: Codex sessions here start with what Claude Code remembers, and Claude Code sessions with what Codex remembers."
                 : "Not shared: each agent only sees its own memory. Turn on Shared memory in Settings.")
                .lineLimit(2)
            Spacer()
            Button(settings.isOn(.sharedMemory) ? "Stop Sharing" : "Share") {
                settings.set(.sharedMemory, on: !settings.isOn(.sharedMemory))
            }
        }
        .font(Extreme.font(10.5))
        .foregroundColor(Extreme.muted)
    }
}
#endif
