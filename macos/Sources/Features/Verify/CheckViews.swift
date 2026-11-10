#if os(macOS)
import AppKit
import SwiftUI

/// Beside an agent's "Done", on its sidebar card and its Mission Control card: whether the
/// project's check passed. A failed one opens its log. Nothing here moves.
struct ProjectCheckMark: View {
    let surface: Ghostty.SurfaceView?
    let activity: VerticalTabAgentActivity?
    /// Shorter words, for the sidebar.
    var compact = false
    @ObservedObject private var checks = ProjectChecks.shared
    @ObservedObject private var settings = TellurionSettings.shared

    var body: some View {
        if settings.isOn(.checks), activity == .done, let surface, let run = checks.run(for: surface) {
            switch run.result.state {
            case .running:
                label("hourglass", "Checking…", Tellurion.muted).help(Self.help(run))
            case .passed:
                label("checkmark.seal.fill", "Verified", Tellurion.live).help(Self.help(run))
            case .failed, .timedOut:
                Button {
                    if let root = checks.project(of: surface) { ProjectCheckLog.show(root: root, surface: surface) }
                } label: {
                    label("xmark.octagon.fill", Self.failedTitle(run.result.state, compact: compact), Tellurion.danger)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.help(run) + "\nClick for the log")
                .accessibilityLabel("\(Self.failedTitle(run.result.state, compact: false)): open the log")
            }
        }
    }

    private func label(_ symbol: String, _ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(title).lineLimit(1)
        }
        .font(Tellurion.font(10.5))
        .foregroundColor(color)
        .fixedSize()
    }

    static func failedTitle(_ state: CheckResult.State, compact: Bool) -> String {
        if state == .timedOut { return compact ? "Timed out" : "Check timed out" }
        return compact ? "Failed" : "Check failed"
    }

    /// The command, what it said last and whose turn set it off.
    static func help(_ run: ProjectChecks.Run) -> String {
        [CheckOutput.short(run.result.command, 80), run.result.summary, "After \(run.triggeredBy)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "Verified", "Check failed"…, wherever a result is put into words.
    static func title(_ state: CheckResult.State) -> String {
        switch state {
        case .running: return "Checking…"
        case .passed: return "Verified"
        case .failed, .timedOut: return failedTitle(state, compact: false)
        }
    }

    static func color(_ state: CheckResult.State) -> Color {
        switch state {
        case .running: return Tellurion.muted
        case .passed: return Tellurion.live
        case .failed, .timedOut: return Tellurion.danger
        }
    }
}

// MARK: - Log window

/// A check's log in a small window, with "Send to agent" and "Run again".
enum ProjectCheckLog {
    static let windowID = "check-log"
    /// How much of the log the window shows; the file keeps the rest.
    static let linesShown = 500

    static func show(root: String, surface: Ghostty.SurfaceView?) {
        guard TellurionSettings.isOn(.checks) else { return }
        AgentToolWindows.close(id: windowID)
        let name = (root as NSString).lastPathComponent
        AgentToolWindows.show(id: windowID, title: "Check · \(name)", size: NSSize(width: 760, height: 560)) {
            CheckLogView(root: ProjectCheckStore.key(root), surface: Weak(surface))
        }
    }
}

private struct CheckLogView: View {
    let root: String
    let surface: Weak<Ghostty.SurfaceView>
    @ObservedObject private var checks = ProjectChecks.shared
    @State private var log = ""
    @State private var sent = false

    private var run: ProjectChecks.Run? { checks.runs[root] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TellurionWindowTitle(icon: .bolt, title: run.map { ProjectCheckMark.title($0.result.state) } ?? "No result yet",
                                     subtitle: (root as NSString).abbreviatingWithTildeInPath)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            if let run { details(run).padding(.horizontal, 16).padding(.vertical, 10) }
            ScrollView {
                Text(log.isEmpty ? (run?.result.state == .running ? "Running…" : "It printed nothing.") : log)
                    .font(Tellurion.mono(11))
                    .foregroundColor(Tellurion.text.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Rectangle().fill(Color.black.opacity(0.3)))
            .padding(.horizontal, 16)
            footer.padding(16)
        }
        .frame(minWidth: 520, minHeight: 360)
        .tellurionWindow()
        .onAppear(perform: load)
        .onChange(of: run) { _ in
            sent = false
            load()
        }
    }

    private func details(_ run: ProjectChecks.Run) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CheckOutput.short(run.result.command, 200))
                .font(Tellurion.mono(12)).foregroundColor(Tellurion.text).lineLimit(2).textSelection(.enabled)
            Text(Self.facts(run)).font(Tellurion.font(11)).foregroundColor(Tellurion.muted).lineLimit(2)
        }
    }

    /// "Exit status 1 · took 42 s · after Codex's turn: fix the login form"
    static func facts(_ run: ProjectChecks.Run) -> String {
        var facts: [String] = []
        switch run.result.state {
        case .running: facts.append("Started \(run.result.started.formatted(date: .omitted, time: .shortened))")
        case .timedOut: facts.append("Stopped after \(CheckOutput.duration(run.timeout))")
        case .passed, .failed:
            if let status = run.exitStatus { facts.append("Exit status \(status)") } else { facts.append(run.result.summary) }
        }
        if run.result.state != .timedOut, let finished = run.result.finished {
            facts.append("took \(CheckOutput.duration(finished.timeIntervalSince(run.result.started)))")
        }
        facts.append("after \(run.triggeredBy)")
        return facts.joined(separator: " · ")
    }

    private var footer: some View {
        let failed = run?.result.state == .failed || run?.result.state == .timedOut
        let target = surface.value.flatMap { ProjectChecks.canReceive($0) ? $0 : nil }
        let agent = target.flatMap { VerticalTabsAgents.shared.info(for: $0)?.name }
        return HStack(spacing: 8) {
            Button(sent ? "Queued" : "Send to agent") {
                guard let target else { return }
                checks.sendFailure(of: root, to: target)
                sent = true
            }
            .buttonStyle(TellurionButtonStyle(prominent: true))
            .disabled(!failed || target == nil || sent)
            .help(agent.map { "Types the command, how it ended and its last \(CheckOutput.promptLines) lines to \($0) once it's between turns" }
                  ?? "Open this from a Claude Code or Codex card to send it there")
            Button("Run again") { checks.runNow(root, from: surface.value) }
                .disabled(checks.isRunning(root) || checks.store.check(for: root) == nil)
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([ProjectChecks.logFile(for: root)])
            }
            Button("Checks…") { ProjectChecksWindow.show() }
        }
    }

    /// Reads the end of the log off the main thread, cleaned for showing.
    private func load() {
        let file = ProjectChecks.logFile(for: root)
        let running = run?.result.state == .running
        DispatchQueue.global(qos: .userInitiated).async {
            let printed = running ? "" : String(decoding: CheckOutput.tail(of: file) ?? Data(), as: UTF8.self)
            let shown = CheckOutput.lastLines(CheckOutput.clean(printed), ProjectCheckLog.linesShown)
            DispatchQueue.main.async { log = shown }
        }
    }
}

// MARK: - Checks window

/// The Checks window: each project's command, timeout and whether failures go back to the
/// agent by themselves, with its last result.
enum ProjectChecksWindow {
    /// `folder`: a project to list even when no agent is running in it.
    static func show(folder: String? = nil) {
        guard TellurionSettings.isOn(.checks) else { return }
        AgentToolWindows.close(id: ProjectChecks.windowID)
        AgentToolWindows.show(id: ProjectChecks.windowID, title: "Checks", size: NSSize(width: 720, height: 640)) {
            ChecksWindowView(folder: folder)
        }
    }

    /// The command palette's entry.
    static func paletteOption(folder: String?) -> CommandOption {
        CommandOption(
            title: "Checks",
            description: "The command each project has to pass before an agent's work counts as done",
            leadingIcon: "checkmark.seal"
        ) {
            show(folder: folder)
        }
    }
}

/// The projects the Checks window lists: those with an agent running, the one it was opened
/// from, and every one with a saved check.
final class ChecksWindowModel: ObservableObject {
    struct Project: Identifiable, Equatable {
        let root: String
        /// The agents working in it now: "Claude Code", "Codex".
        var agents: [String] = []
        var suggestions: [String] = []
        var id: String { root }
        var name: String { (root as NSString).lastPathComponent }
    }

    @Published private(set) var projects: [Project] = []
    @Published private(set) var loaded = false
    private let folder: String?

    init(folder: String?) {
        self.folder = folder
    }

    /// Looks up each folder's repository and what it could be checked with, off the main thread.
    func reload() {
        var folders: [(folder: String, agent: String?)] = TerminalWindows.surfaces.compactMap { item in
            guard let pwd = item.surface.pwd, let info = VerticalTabsAgents.shared.info(for: item.surface),
                  info.kind != .hermes else { return nil }
            return (folder: pwd, agent: Optional(info.name))
        }
        if let folder { folders.append((folder, nil)) }
        let saved = ProjectChecks.shared.store.checks.keys.sorted()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String: Project] = [:]
            var known: [(folder: String, root: String)] = []
            var looked: [String: String?] = [:]
            for item in folders {
                if looked[item.folder] == nil { looked[item.folder] = AgentTools.repoRoot(of: item.folder).map(ProjectCheckStore.key) }
                guard let root = looked[item.folder] ?? nil else { continue }
                known.append((item.folder, root))
                var project = found[root] ?? Project(root: root)
                if let agent = item.agent, !project.agents.contains(agent) { project.agents.append(agent) }
                found[root] = project
            }
            for root in saved where found[root] == nil { found[root] = Project(root: root) }
            for root in found.keys { found[root]?.suggestions = CheckSuggestions.detect(in: root) }
            // Projects with agents first, then by name.
            let list = found.values.sorted {
                $0.agents.isEmpty != $1.agents.isEmpty ? !$0.agents.isEmpty
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                for item in known { ProjectChecks.shared.remember(root: item.root, forFolder: item.folder) }
                guard let self else { return }
                if list != self.projects { self.projects = list }
                self.loaded = true
            }
        }
    }
}

private struct ChecksWindowView: View {
    @StateObject private var model: ChecksWindowModel
    @ObservedObject private var checks = ProjectChecks.shared

    init(folder: String?) {
        _model = StateObject(wrappedValue: ChecksWindowModel(folder: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TellurionWindowTitle(icon: .bolt, title: "Checks",
                                     subtitle: "Done means the project's own check passed")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 12)
            Rectangle().fill(Tellurion.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("""
                    When an agent finishes a turn that changed files, Tellurion runs the project's command in its root, \
                    through your login shell, and the agent's card says whether it passed. Only a command you save here \
                    ever runs; nothing in a repository can set one.
                    """)
                    .font(Tellurion.font(11.5, weight: .regular)).foregroundColor(Tellurion.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    if checks.store.wasUnreadable {
                        Text("The saved checks couldn't be read and were set aside; the list starts empty.")
                            .font(Tellurion.font(11.5)).foregroundColor(Tellurion.warn)
                    }
                    if model.projects.isEmpty {
                        Text(model.loaded ? "No projects yet. Start an agent in a git repository, or open this from a tab that's in one."
                                          : "Looking…")
                            .font(Tellurion.font(12)).foregroundColor(Tellurion.dim).padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.projects) { project in
                        CheckProjectRow(project: project)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .tellurionWindow()
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.title == "Checks" { model.reload() }
        }
    }
}

private struct CheckProjectRow: View {
    let project: ChecksWindowModel.Project
    @ObservedObject private var checks = ProjectChecks.shared
    @State private var command = ""
    @State private var minutes = Int(ProjectCheck.defaultTimeout / 60)
    @State private var autoSend = false
    @State private var saveFailed = false

    private static let usualMinutes = [1, 2, 5, 10, 20, 30, 60]

    private var saved: ProjectCheck? { checks.store.check(for: project.root) }
    private var draft: ProjectCheck {
        ProjectCheck(command: command.trimmingCharacters(in: .whitespacesAndNewlines), timeout: TimeInterval(minutes * 60), autoSend: autoSend)
    }
    private var changed: Bool { saved.map { $0 != draft } ?? !draft.command.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(project.name).font(Tellurion.font(13, weight: .semibold)).foregroundColor(Tellurion.text)
                Text((project.root as NSString).abbreviatingWithTildeInPath)
                    .font(Tellurion.font(11, weight: .regular)).foregroundColor(Tellurion.dim).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text(project.agents.isEmpty ? "No agents running" : project.agents.joined(separator: ", "))
                    .font(Tellurion.font(11)).foregroundColor(Tellurion.muted).lineLimit(1)
            }
            TextField("Command, such as npm test", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(Tellurion.mono(12))
                .disableAutocorrection(true)
                .accessibilityLabel("Check command for \(project.name)")
            if !project.suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Found here").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
                    ForEach(project.suggestions.prefix(6), id: \.self) { suggestion in
                        Button { command = suggestion } label: {
                            Text(suggestion).font(Tellurion.mono(10.5))
                                .foregroundColor(command == suggestion ? Tellurion.gold : Tellurion.text.opacity(0.85))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Tellurion.ink))
                                .overlay(Capsule().strokeBorder(Tellurion.line, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Fill in \(suggestion). Nothing runs until you save.")
                    }
                }
            }
            HStack(spacing: 14) {
                Picker("Stop after", selection: $minutes) {
                    ForEach(minuteChoices, id: \.self) { Text(CheckOutput.duration(TimeInterval($0 * 60))).tag($0) }
                }
                .frame(width: 190)
                Toggle("Send failures back automatically", isOn: $autoSend)
                    .help("A failed check goes to the agent whose turn set it off, up to \(ProjectChecks.autoSendLimit) times in a row. "
                          + "Your next prompt starts the count again.")
            }
            .font(Tellurion.font(11.5))
            HStack(spacing: 8) {
                Button(saved == nil ? "Save" : "Save changes") {
                    saveFailed = !checks.save(draft, for: project.root)
                }
                .buttonStyle(TellurionButtonStyle(prominent: true))
                .disabled(!changed)
                Button("Run now") { checks.runNow(project.root) }
                    .disabled(saved == nil || changed || checks.isRunning(project.root))
                    .help(changed ? "Save first: only a saved command runs" : "Run the saved command now")
                if saved != nil {
                    Button("Remove") {
                        checks.save(nil, for: project.root)
                        command = ""
                    }
                }
                Spacer(minLength: 8)
                result
            }
            if saveFailed {
                Text("Couldn't save. See Console for why.").font(Tellurion.font(11)).foregroundColor(Tellurion.danger)
            }
        }
        .padding(12)
        .tellurionPanel()
        .onAppear(perform: fill)
    }

    private var minuteChoices: [Int] {
        Self.usualMinutes.contains(minutes) ? Self.usualMinutes : (Self.usualMinutes + [minutes]).sorted()
    }

    /// The last result, and the way to its log.
    @ViewBuilder
    private var result: some View {
        if let run = checks.runs[project.root] {
            Button { ProjectCheckLog.show(root: project.root, surface: nil) } label: {
                HStack(spacing: 5) {
                    Text(ProjectCheckMark.title(run.result.state)).foregroundColor(ProjectCheckMark.color(run.result.state))
                    if let finished = run.result.finished {
                        Text("· \(finished.formatted(date: .omitted, time: .shortened))").foregroundColor(Tellurion.dim)
                    }
                    Text("· Log").foregroundColor(Tellurion.muted)
                }
                .font(Tellurion.font(11))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ProjectCheckMark.help(run))
        }
    }

    private func fill() {
        guard let saved else { return }
        command = saved.command
        minutes = max(1, Int((saved.timeout / 60).rounded()))
        autoSend = saved.autoSend
    }
}
#endif
