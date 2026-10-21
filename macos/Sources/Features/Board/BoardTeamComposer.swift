#if os(macOS)
import AppKit
import SwiftUI

/// A tile's team commands: on its link button, and in its menu.
enum BoardTeamMenu {
    static func actions(for tile: UUID, in board: BoardController) -> [BoardTileMenu.Action?] {
        var list: [BoardTileMenu.Action?] = []
        if let team = board.team(ledBy: tile) {
            list.append(BoardTileMenu.Action(title: "Message the Team…", enabled: !team.members.isEmpty) { [weak board] in
                board?.promptTeamMessage(team.id)
            })
            let paused = Set([team.lead] + team.members.map(\.tile)).isSubset(of: board.model.paused)
            list.append(BoardTileMenu.Action(title: paused ? "Resume Team" : "Pause Team") { [weak board] in
                board?.setPaused(!paused, [team.lead] + team.members.map(\.tile))
            })
            list.append(BoardTileMenu.Action(title: "Send the Lead Its Brief Again") { [weak board] in board?.sendBrief(team.id) })
            list.append(BoardTileMenu.Action(title: "Rename Team…") { [weak board] in
                board?.promptRename("Rename Team", current: team.name) { board?.renameTeam(team.id, to: $0) }
            })
            list.append(BoardTileMenu.Action(title: "Disband \(team.name)") { [weak board] in board?.disbandTeam(team.id) })
        } else if let role = board.role(of: tile) {
            list.append(BoardTileMenu.Action(title: "Role: \(role)…") { [weak board] in
                board?.promptRename("Role", current: role, button: "Set Role") { board?.setRole($0, for: tile) }
            })
            list.append(BoardTileMenu.Action(title: "Remove from Team") { [weak board] in board?.removeFromTeam(tile: tile) })
        } else {
            list.append(BoardTileMenu.Action(title: "Make Lead of a New Team") { [weak board] in
                board?.createTeam(lead: tile, members: [], goal: nil, brief: true)
            })
            for team in board.model.teams {
                let lead = board.model.surfaces.first { $0.id == team.lead }.map { board.tileLabel($0) } ?? team.name
                list.append(BoardTileMenu.Action(title: "Add to \(team.name) (led by \(lead))…") { [weak board] in
                    board?.connect(tile, to: team.lead)
                })
            }
        }
        list.append(BoardTileMenu.Action(title: "New Team…") { [weak board] in board?.model.showTeamComposer = true })
        return list
    }

    static func menu(for tile: UUID, in board: BoardController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions(for: tile, in: board) {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = ClosureMenuItem(action.title, image: nil) { DispatchQueue.main.async(execute: action.run) }
            item.isEnabled = action.enabled
            menu.addItem(item)
        }
        return menu
    }
}

extension BoardController {
    /// Asks what to tell every member of a team, from you.
    func promptTeamMessage(_ teamID: UUID) {
        guard let window, let team = model.teams.first(where: { $0.id == teamID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Message \(team.name)"
        alert.informativeText = "Sent to every member. Their lead hears what they answer."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        field.placeholderString = "What should everyone know?"
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            for member in team.members {
                guard let surface = self.model.surfaces.first(where: { $0.id == member.tile }) else { continue }
                if VerticalTabsAgents.shared.info(for: surface) != nil {
                    AgentInbox.shared.deliver("From the user, to the whole team:\n\n\(text)", to: surface, label: "From you")
                } else {
                    self.deliver(text, to: surface)
                }
            }
        }
    }
}

/// Starts a team in one go: a lead agent, its members with their roles, a folder and a goal.
/// The lead starts on a brief that explains the `team` command and lists the members.
struct BoardTeamComposer: View {
    let controller: BoardController
    @Binding var isPresented: Bool
    @State private var folder = ""
    @State private var goal = ""
    @State private var installed: [BoardAgent]?
    @State private var lead = "claude"
    @State private var members: [Row] = []

    private struct Row: Identifiable {
        let id = UUID()
        var agent: String
        var role: String
    }

    private static let limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New team").font(Extreme.font(15, weight: .semibold)).foregroundColor(Extreme.text)
            Text("A lead agent runs the team: it splits the work, hands it out with the team command, and hears from each member when it finishes. You talk to the lead.")
                .font(Extreme.font(11.5)).foregroundColor(Extreme.muted).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("Folder")
                HStack {
                    Text(folder.isEmpty ? "Home" : (folder as NSString).abbreviatingWithTildeInPath)
                        .font(Extreme.mono(11.5)).foregroundColor(Extreme.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
            }

            if let installed {
                if installed.isEmpty {
                    Text("No agent CLIs found on your PATH. Install Claude Code or Codex, then try again.")
                        .font(Extreme.font(11.5)).foregroundColor(Extreme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ExtremeSectionLabel("Lead")
                        agentPicker($lead, shell: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ExtremeSectionLabel("Members")
                        ForEach($members) { $row in
                            HStack(spacing: 8) {
                                agentPicker($row.agent, shell: true).frame(width: 150)
                                TextField("Role", text: $row.role).textFieldStyle(.roundedBorder)
                                Button { members.removeAll { $0.id == row.id } } label: {
                                    Image(systemName: "minus.circle").foregroundColor(Extreme.muted)
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                                .accessibilityLabel("Remove member")
                            }
                        }
                        Button {
                            members.append(Row(agent: installed.first { $0.binary == "codex" }?.binary ?? installed[0].binary,
                                               role: BoardTeams.roles.first { role in !members.contains { $0.role == role } } ?? "Member"))
                        } label: {
                            Label("Add Member", systemImage: "plus")
                        }
                        .disabled(members.count >= Self.limit)
                    }
                }
            } else {
                Text("Looking for agents…").font(Extreme.font(11.5)).foregroundColor(Extreme.dim)
            }

            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("Goal (optional)")
                TextEditor(text: $goal)
                    .font(Extreme.font(12))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
                Text("The lead starts on it. Without one, it asks you what to work on.")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            }

            HStack {
                Text("\(members.count) of \(Self.limit) members").font(Extreme.font(11)).foregroundColor(Extreme.muted)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Start Team") { start() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(installed?.isEmpty != false)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Extreme.panel)
        .onAppear {
            folder = controller.workspace.folder ?? controller.focusedSurface?.pwd ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let found = BoardAgent.installed()
                DispatchQueue.main.async {
                    installed = found
                    lead = found.first { $0.kind == .claude }?.binary ?? found.first?.binary ?? "claude"
                    if members.isEmpty, let first = found.first {
                        let coder = found.first { $0.kind == .codex }?.binary ?? first.binary
                        members = [Row(agent: coder, role: "Coder"), Row(agent: first.binary, role: "Reviewer")]
                    }
                }
            }
        }
    }

    private func agentPicker(_ selection: Binding<String>, shell: Bool) -> some View {
        Picker("", selection: selection) {
            ForEach(installed ?? []) { Text($0.kind.displayName).tag($0.binary) }
            if shell { Text("Shell").tag("shell") }
        }
        .labelsHidden()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func start() {
        guard let installed, let leadAgent = installed.first(where: { $0.binary == lead }) ?? installed.first else { return }
        let rows = members.map { row in
            (agent: installed.first { $0.binary == row.agent }, role: row.role.trimmingCharacters(in: .whitespaces).isEmpty ? "Member" : row.role)
        }
        isPresented = false
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.launchTeam(lead: leadAgent, members: rows, folder: folder.isEmpty ? nil : folder, goal: text.isEmpty ? nil : text)
    }
}
#endif
