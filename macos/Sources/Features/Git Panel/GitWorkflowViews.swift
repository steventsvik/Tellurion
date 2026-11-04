#if os(macOS)
import AppKit
import SwiftUI

/// The Git panel while GitButler manages the repository: the branches applied side by side,
/// what's uncommitted, and GitButler's own commit, push and undo.
struct GitButlerSection: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject private var pulls = GitHubPulls.shared
    @State private var message = ""
    @State private var target: String?
    @State private var naming = false
    @State private var newBranch = ""

    private var status: GitButler.Status? { model.butler }
    private var branchNames: [String] { status?.stacks.flatMap { $0.branches.map(\.name) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.loaded && GitButler.binary == nil {
                Text("This repository is in GitButler's workspace. Install GitButler's CLI (but) to see its branches here.")
                    .font(Tellurion.font(10.5)).foregroundColor(Tellurion.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                branchesSection
                uncommittedSection
            }
        }
    }

    private var branchesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TellurionSectionLabel("Applied branches") {
                HStack(spacing: 10) {
                    Button(naming ? "Cancel" : "New…") { naming.toggle(); newBranch = "" }
                        .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                    Button("Undo") { model.butlerUndo() }
                        .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                        .disabled(model.busy).help("but undo: reverse GitButler's last operation")
                    Button("Open") { model.openGitButler() }
                        .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
                        .help("Open this project in GitButler")
                }
                .fixedSize()
            }
            if naming {
                HStack(spacing: 6) {
                    TextField("new-branch-name", text: $newBranch, onCommit: create)
                        .textFieldStyle(.roundedBorder).font(Tellurion.mono(11))
                    Button("Create", action: create).disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("A new branch applied beside the others. Each agent can commit to its own.")
                    .font(Tellurion.font(10)).foregroundColor(Tellurion.dim)
            }
            if let status, status.stacks.isEmpty {
                Text("No branches applied yet").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
            } else if status == nil {
                Text(model.loaded ? "Couldn't read GitButler's status" : "…").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
            }
            ForEach(status?.stacks ?? []) { stack in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(stack.branches.enumerated()), id: \.element.id) { index, branch in
                        branchRow(branch, stacked: index > 0)
                    }
                    if !stack.assigned.isEmpty {
                        Text("\(stack.assigned.count) uncommitted file\(stack.assigned.count == 1 ? "" : "s") assigned")
                            .font(Tellurion.font(9.5)).foregroundColor(Tellurion.dim).padding(.leading, 18)
                    }
                }
                .padding(6)
                .tellurionPanel(fill: Tellurion.raised)
            }
            if let behind = status?.behind, behind > 0 {
                Text("\(behind) new commit\(behind == 1 ? "" : "s") on the target branch · but pull brings them in")
                    .font(Tellurion.font(10)).foregroundColor(Tellurion.warn)
            }
        }
    }

    private func branchRow(_ branch: GitButler.Branch, stacked: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: stacked ? "arrow.turn.down.right" : "arrow.triangle.branch")
                .font(.system(size: 9.5, weight: .semibold)).foregroundColor(Tellurion.dim).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.name).font(Tellurion.mono(11)).foregroundColor(Tellurion.text).lineLimit(1).truncationMode(.middle)
                Text(([branch.commits.count == 1 ? "1 commit" : "\(branch.commits.count) commits", branch.statusText]
                      + (branch.commits.first.map { [$0] } ?? [])).joined(separator: " · "))
                    .font(Tellurion.font(9.5)).foregroundColor(Tellurion.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let pull = pulls.pull(root: model.root, branch: branch.name) { PullRequestBadge(pull: pull) }
            if branch.status != "nothingToPush", branch.status != "integrated", !branch.commits.isEmpty {
                Button("Push") { model.butlerPush(branch.name) }
                    .buttonStyle(.plain).font(Tellurion.font(10, weight: .semibold)).foregroundColor(Tellurion.gold)
                    .disabled(model.busy).help("but push \(branch.name)")
            }
        }
        .onAppear { pulls.fetch(root: model.root, branch: branch.name) }
    }

    private var uncommittedSection: some View {
        let files = (status?.unassigned ?? []) + (status?.stacks.flatMap(\.assigned) ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            TellurionSectionLabel("Uncommitted")
            if files.isEmpty {
                Text(model.loaded ? "Nothing uncommitted" : "…").font(Tellurion.font(10.5)).foregroundColor(Tellurion.dim)
            } else {
                ForEach(files.prefix(5), id: \.self) { path in
                    Text(path).font(Tellurion.mono(10)).foregroundColor(Tellurion.muted).lineLimit(1).truncationMode(.middle)
                }
                if files.count > 5 {
                    Text("… and \(files.count - 5) more").font(Tellurion.font(10)).foregroundColor(Tellurion.dim)
                }
                if !branchNames.isEmpty {
                    HStack(spacing: 6) {
                        TextField("Commit message", text: $message).textFieldStyle(.roundedBorder).font(Tellurion.font(11))
                        Picker("", selection: Binding(get: { target ?? branchNames.first ?? "" }, set: { target = $0 })) {
                            ForEach(branchNames, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 110)
                        Button("Commit") {
                            model.butlerCommit(message, to: target ?? branchNames.first ?? "")
                            message = ""
                        }
                        .buttonStyle(TellurionButtonStyle(prominent: true))
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                        .help("but commit: commit the uncommitted changes to this branch")
                    }
                }
            }
        }
    }

    private func create() {
        model.butlerNewBranch(newBranch)
        naming = false
        newBranch = ""
    }
}

/// The Graphite stack the current branch is in, with each branch's pull request, and
/// Graphite's restack, submit and sync.
struct GraphiteStackSection: View {
    @ObservedObject var model: GitPanelModel
    @ObservedObject private var pulls = GitHubPulls.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TellurionSectionLabel("Stack") {
                HStack(spacing: 10) {
                    if model.stack.contains(where: \.needsRestack) {
                        tabButton("Restack", "restack", help: "gt restack: rebase each branch onto its parent")
                    }
                    tabButton("Submit", "submit --stack", help: "gt submit --stack: push the stack and open or update its pull requests")
                    tabButton("Sync", "sync", help: "gt sync: pull trunk, restack, and clean up merged branches")
                }
            }
            ForEach(model.stack) { branch in
                Button {
                    guard branch.name != model.currentBranch, !model.busy else { return }
                    model.switchTo(branch.name)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: branch.isTrunk ? "circle" : branch.name == model.currentBranch ? "largecircle.fill.circle" : "circle.fill")
                            .font(.system(size: 7.5)).foregroundColor(branch.name == model.currentBranch ? Tellurion.gold : Tellurion.dim)
                            .frame(width: 12)
                        Text(branch.name).font(Tellurion.mono(11))
                            .foregroundColor(branch.name == model.currentBranch ? Tellurion.gold : branch.isTrunk ? Tellurion.muted : Tellurion.text)
                            .lineLimit(1).truncationMode(.middle)
                        if branch.needsRestack {
                            Text("needs restack").font(Tellurion.font(9.5)).foregroundColor(Tellurion.warn)
                        }
                        Spacer(minLength: 4)
                        if !branch.isTrunk, let pull = pulls.pull(root: model.root, branch: branch.name) {
                            PullRequestBadge(pull: pull)
                        }
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(branch.name == model.currentBranch ? "Current branch" : "Switch to \(branch.name)")
            }
        }
    }

    private func tabButton(_ title: String, _ args: String, help: String) -> some View {
        Button(title) { model.graphiteInTab(args) }
            .buttonStyle(.plain).font(Tellurion.font(10.5)).foregroundColor(Tellurion.gold)
            .disabled(Graphite.binary == nil)
            .help(Graphite.binary == nil ? "Install Graphite's CLI (gt) to run this" : help + " (runs in a new tab)")
    }
}
#endif
