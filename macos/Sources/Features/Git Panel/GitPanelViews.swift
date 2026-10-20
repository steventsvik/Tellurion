#if os(macOS)
import AppKit
import SwiftUI

extension PullRequestInfo {
    var color: Color {
        switch state {
        case .merged: return Color(red: 0.64, green: 0.48, blue: 0.98)
        case .closed: return Extreme.dim
        case .open:
            if failed > 0 { return Extreme.danger }
            if pending > 0 { return Extreme.warn }
            return isDraft ? Extreme.muted : Extreme.live
        }
    }

    var symbol: String {
        switch state {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .open:
            if failed > 0 { return "xmark.circle.fill" }
            if pending > 0 { return "clock.fill" }
            return isDraft ? "circle.dashed" : "checkmark.circle.fill"
        }
    }
}

extension PullRequestInfo.Check.Result {
    var color: Color {
        switch self {
        case .passed: return Extreme.live
        case .failed: return Extreme.danger
        case .pending: return Extreme.warn
        case .skipped: return Extreme.dim
        }
    }

    var symbol: String {
        switch self {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .skipped: return "minus.circle"
        }
    }
}

/// "#123 ✓" beside a tab's branch.
struct PullRequestBadge: View {
    let pull: PullRequestInfo

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: pull.symbol).font(.system(size: 8.5, weight: .bold))
            Text("#\(String(pull.number))").font(Extreme.mono(10))
        }
        .foregroundColor(pull.color)
        .help("Pull request #\(pull.number): \(pull.title) · \(pull.summary)")
    }
}

/// Ahead/behind arrows: "↑2 ↓1".
struct AheadBehindLabel: View {
    let info: VerticalTabsGitInfo

    var body: some View {
        let ahead = info.ahead ?? 0, behind = info.behind ?? 0
        if ahead > 0 || behind > 0 {
            HStack(spacing: 2) {
                if ahead > 0 { Text("↑\(ahead)") }
                if behind > 0 { Text("↓\(behind)") }
            }
            .font(Extreme.mono(10))
            .foregroundColor(Extreme.muted)
            .help([ahead > 0 ? "\(ahead) to push" : nil, behind > 0 ? "\(behind) to pull" : nil].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// The Git panel: opened from a tab's branch in the sidebar.
struct GitPanelView: View {
    let controller: BaseTerminalController
    let pwd: String
    let dismiss: () -> Void
    @StateObject private var model: GitPanelModel
    @StateObject private var jj: JJPanelModel
    @ObservedObject private var pulls = GitHubPulls.shared
    @ObservedObject private var git = VerticalTabsGit.shared
    @State private var filter = ""
    @State private var newBranch = ""
    @State private var creating = false
    @State private var confirmSwitch: String?
    @State private var armedDrop: String?
    @State private var escapeMonitor: Any?

    init(controller: BaseTerminalController, pwd: String, root: String, dismiss: @escaping () -> Void) {
        self.controller = controller
        self.pwd = pwd
        self.dismiss = dismiss
        self._model = StateObject(wrappedValue: GitPanelModel(root: root))
        self._jj = StateObject(wrappedValue: JJPanelModel(root: root))
    }

    /// A jj repository: jj's view of it replaces branches, stashes and commits.
    private var isJJ: Bool { info?.jj != nil }

    /// Pushed, so GitHub could have a pull request for it.
    private var isPushed: Bool {
        isJJ ? jj.isPushed(info?.jj?.bookmark) : model.branches.first(where: { $0.isCurrent })?.upstream.isEmpty == false
    }

    private var info: VerticalTabsGitInfo? { git.info(for: pwd) }
    private var dirty: Bool { (info?.added ?? 0) + (info?.removed ?? 0) > 0 }
    private var pull: PullRequestInfo? { pulls.pull(root: model.root, branch: info?.branch) }

    /// An agent working in this tab, which a branch switch would pull the rug from under.
    private var busyAgent: VerticalTabAgentInfo? {
        controller.surfaceTree.compactMap { VerticalTabsAgents.shared.info(for: $0) }
            .first { $0.activity == .working || $0.activity == .needsPermission }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let agent = busyAgent {
                        notice(isJJ ? "\(agent.kind.displayName) is working here. Changing the working copy under it can confuse it."
                                    : "\(agent.kind.displayName) is working here. Switching branches under it can confuse it.",
                               color: Extreme.warn, symbol: "exclamationmark.triangle.fill")
                    }
                    if let error = isJJ ? jj.error : model.error {
                        notice(error, color: Extreme.danger, symbol: "xmark.octagon.fill")
                    } else if let done = isJJ ? jj.notice : model.notice {
                        notice(done, color: Extreme.live, symbol: "checkmark.circle.fill")
                    }
                    pullSection
                    if isJJ {
                        JJPanelSections(model: jj)
                    } else if model.isButler {
                        GitButlerSection(model: model)
                        commitSection
                    } else {
                        if !model.stack.isEmpty { GraphiteStackSection(model: model) }
                        branchSection
                        stashSection
                        commitSection
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 360)
        .extremePanel(active: true, fill: Extreme.ink)
        .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
        .onAppear {
            if isJJ { jj.load() } else { model.load() }
            if let branch = info?.branch { pulls.fetch(root: model.root, branch: branch, force: true) }
            // Escape closes it, wherever focus is (usually still the terminal).
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, event.window === controller.window else { return event }
                dismiss()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
    }

    private var divider: some View { Rectangle().fill(Extreme.line).frame(height: 1) }

    private var header: some View {
        HStack(spacing: 8) {
            PixelIconView(icon: .branch, color: Extreme.gold, pixel: 1.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(info?.branch ?? model.currentBranch ?? "…")
                    .font(Extreme.font(13, weight: .semibold)).foregroundColor(Extreme.text).lineLimit(1)
                Text(headerDetail).font(Extreme.font(10.5)).foregroundColor(Extreme.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.busy || jj.busy { ProgressView().controlSize(.small) }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(Extreme.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .help("Close (Escape)")
        }
        .padding(12)
    }

    private var headerDetail: String {
        var parts: [String] = [(model.root as NSString).lastPathComponent]
        if isJJ {
            parts.append("jj")
            if let status = info?.jj, status.bookmark != nil { parts.append("on \(status.changeID)") }
            if info?.jj?.bookmark != nil { parts.append(isPushed ? "pushed" : "not pushed") }
            if dirty { parts.append("+\(info?.added ?? 0) −\(info?.removed ?? 0) in the working copy") }
            return parts.joined(separator: " · ")
        }
        if model.isButler {
            let applied = model.butler?.stacks.reduce(0) { $0 + $1.branches.count } ?? 0
            parts.append("GitButler workspace")
            if model.butler != nil { parts.append("\(applied) branch\(applied == 1 ? "" : "es") applied") }
            return parts.joined(separator: " · ")
        }
        if let upstream = model.branches.first(where: { $0.isCurrent })?.upstream, !upstream.isEmpty {
            parts.append("tracks \(upstream)")
        } else if model.loaded {
            parts.append("not pushed")
        }
        if let ahead = info?.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = info?.behind, behind > 0 { parts.append("↓\(behind)") }
        if dirty { parts.append("+\(info?.added ?? 0) −\(info?.removed ?? 0) uncommitted") }
        return parts.joined(separator: " · ")
    }

    // MARK: Pull request

    @ViewBuilder
    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtremeSectionLabel("Pull request")
            if pulls.available == false {
                Text("Install the GitHub CLI (gh) and run gh auth login to see pull requests and checks here.")
                    .font(Extreme.font(11)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)
            } else if let pull {
                Button { if let url = pull.url { NSWorkspace.shared.open(url) } } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: pull.symbol).foregroundColor(pull.color).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pull.title).font(Extreme.font(11.5, weight: .semibold)).foregroundColor(Extreme.text)
                                .multilineTextAlignment(.leading).lineLimit(2)
                            Text(pullDetail(pull)).font(Extreme.font(10.5)).foregroundColor(Extreme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square").font(.system(size: 10)).foregroundColor(Extreme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open on GitHub")
                let shown = pull.checks.sorted { order($0.result) < order($1.result) }
                ForEach(shown.prefix(8)) { check in
                    Button { if let url = check.url { NSWorkspace.shared.open(url) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: check.result.symbol).font(.system(size: 10)).foregroundColor(check.result.color)
                            Text(check.name).font(Extreme.font(10.5)).foregroundColor(Extreme.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(check.url == nil)
                    .help(check.url == nil ? check.name : "Open \(check.name)'s log")
                }
                if shown.count > 8 {
                    Text("+\(shown.count - 8) more checks").font(Extreme.font(10)).foregroundColor(Extreme.dim)
                }
            } else if pulls.available == true, let branch = info?.branch {
                HStack {
                    Text("No pull request for \(branch)").font(Extreme.font(11)).foregroundColor(Extreme.muted)
                    Spacer()
                    // Only once it's pushed: for an unpushed branch, gh would want to push first.
                    if isPushed {
                        Button("Create…") { pulls.createPullRequest(root: model.root, branch: isJJ ? info?.jj?.bookmark : nil) }
                            .help("Opens GitHub's new pull request page (gh pr create --web)")
                    } else if model.loaded || jj.loaded {
                        Text(isJJ && info?.jj?.bookmark == nil ? "Set a bookmark first" : "Push it first").font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
                    }
                }
            } else {
                Text("Looking…").font(Extreme.font(11)).foregroundColor(Extreme.dim)
            }
        }
    }

    private func order(_ result: PullRequestInfo.Check.Result) -> Int {
        switch result {
        case .failed: return 0
        case .pending: return 1
        case .passed: return 2
        case .skipped: return 3
        }
    }

    private func pullDetail(_ pull: PullRequestInfo) -> String {
        var parts = ["#\(pull.number)", pull.summary]
        if !pull.checks.isEmpty { parts.append("\(pull.passed)/\(pull.checks.count) checks passed") }
        switch pull.reviewDecision {
        case "APPROVED": parts.append("approved")
        case "CHANGES_REQUESTED": parts.append("changes requested")
        case "REVIEW_REQUIRED": parts.append("review required")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Branches

    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtremeSectionLabel("Branches") {
                Button(creating ? "Cancel" : "New…") { creating.toggle(); newBranch = "" }
                    .buttonStyle(.plain).font(Extreme.font(10.5)).foregroundColor(Extreme.gold)
            }
            if creating {
                HStack(spacing: 6) {
                    TextField("new-branch-name", text: $newBranch, onCommit: create)
                        .textFieldStyle(.roundedBorder).font(Extreme.mono(11))
                    Button("Create", action: create).disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("From the current commit; uncommitted changes come along.")
                    .font(Extreme.font(10)).foregroundColor(Extreme.dim)
            }
            if model.branches.count > 6 {
                TextField("Filter branches", text: $filter).textFieldStyle(.roundedBorder).font(Extreme.font(11))
            }
            let matches = model.branches.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            ForEach(matches.prefix(filter.isEmpty ? 8 : 30)) { branch in branchRow(branch) }
            if filter.isEmpty && model.branches.count > 8 {
                Text("\(model.branches.count - 8) older branches · type to filter").font(Extreme.font(10)).foregroundColor(Extreme.dim)
            }
            if let target = confirmSwitch {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You have uncommitted changes. Git brings them along to \(target) if they don't clash, and refuses if they do.")
                        .font(Extreme.font(10.5)).foregroundColor(Extreme.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Switch") { model.switchTo(target); confirmSwitch = nil }
                            .buttonStyle(ExtremeButtonStyle(prominent: true))
                        Button("Stash, then switch") {
                            // Both run in order on the model's queue.
                            model.stashChanges()
                            model.switchTo(target)
                            confirmSwitch = nil
                        }
                        Button("Cancel") { confirmSwitch = nil }
                    }
                }
                .padding(8)
                .extremePanel(fill: Extreme.raised)
            }
        }
    }

    private func branchRow(_ branch: GitPanelModel.Branch) -> some View {
        Button {
            guard !branch.isCurrent, !model.busy else { return }
            if dirty { confirmSwitch = branch.name } else { model.switchTo(branch.name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(branch.isCurrent ? Extreme.gold : Extreme.dim)
                    .frame(width: 12)
                Text(branch.name).font(Extreme.mono(11))
                    .foregroundColor(branch.isCurrent ? Extreme.gold : Extreme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(branch.age).font(Extreme.font(9.5)).foregroundColor(Extreme.dim).lineLimit(1)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(branch.isCurrent ? "Current branch" : "Switch to \(branch.name)")
    }

    private func create() {
        model.createBranch(newBranch)
        creating = false
        newBranch = ""
    }

    // MARK: Stashes

    private var stashSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExtremeSectionLabel("Stashes") {
                if dirty {
                    Button("Stash changes") { model.stashChanges() }
                        .buttonStyle(.plain).font(Extreme.font(10.5)).foregroundColor(Extreme.gold)
                        .help("git stash push --include-untracked")
                }
            }
            if model.stashes.isEmpty {
                Text(model.loaded ? "No stashes" : "…").font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            }
            ForEach(model.stashes.prefix(6)) { stash in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stash.message).font(Extreme.font(10.5)).foregroundColor(Extreme.text).lineLimit(1)
                        Text("\(stash.ref) · \(stash.age)").font(Extreme.font(9.5)).foregroundColor(Extreme.dim)
                    }
                    Spacer(minLength: 4)
                    small("Apply") { model.apply(stash) }
                    small("Pop") { model.pop(stash) }
                    if armedDrop == stash.id {
                        small("Drop?", color: Extreme.danger) { model.drop(stash); armedDrop = nil }
                    } else {
                        small("Drop", color: Extreme.muted) {
                            armedDrop = stash.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if armedDrop == stash.id { armedDrop = nil } }
                        }
                    }
                }
            }
        }
    }

    private func small(_ title: String, color: Color = Extreme.gold, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Extreme.font(10, weight: .semibold))
            .foregroundColor(color)
            .disabled(model.busy)
    }

    // MARK: Commits

    private var commitSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ExtremeSectionLabel("Recent commits")
            ForEach(model.commits) { commit in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.hash, forType: .string)
                    model.notice = "Copied \(commit.hash)"
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(commit.hash).font(Extreme.mono(10)).foregroundColor(Extreme.bronze)
                        Text(commit.subject).font(Extreme.font(10.5)).foregroundColor(Extreme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(commit.age).font(Extreme.font(9.5)).foregroundColor(Extreme.dim).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(commit.author) · click to copy the hash")
            }
        }
    }

    private func notice(_ text: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundColor(color)
            Text(text).font(Extreme.font(10.5)).foregroundColor(Extreme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.1)))
    }
}
#endif
