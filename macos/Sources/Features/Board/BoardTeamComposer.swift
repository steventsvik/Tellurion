#if os(macOS)
import AppKit
import SwiftUI

/// A tile's orchestrator commands, in its menu.
enum BoardTeamMenu {
    static func actions(for tile: UUID, in board: BoardController) -> [BoardTileMenu.Action?] {
        var list: [BoardTileMenu.Action?] = []
        for team in board.model.teams {
            let name = board.orchestratorName(team.id)
            if board.isWired(tile, to: team.id) {
                let role = board.role(of: tile, in: team.id)
                list.append(BoardTileMenu.Action(title: "Role in \(name)…") { [weak board] in
                    board?.promptRename("Role", info: "What this agent does for \(name).", current: role ?? "", button: "Set Role") {
                        board?.setRole($0, for: tile, in: team.id)
                    }
                })
                list.append(BoardTileMenu.Action(title: "Unwire from \(name)") { [weak board] in board?.unwire(tile, from: team.id) })
            } else {
                list.append(BoardTileMenu.Action(title: "Wire to \(name)") { [weak board] in board?.wire([tile], to: team.id) })
            }
        }
        list.append(BoardTileMenu.Action(title: "New Orchestrator Here") { [weak board] in
            guard let board, let frame = board.model.frames[tile] else { return }
            let size = BoardCard.Kind.orchestrator.size
            board.newOrchestrator(at: CGPoint(x: frame.minX - size.width / 2 - 80, y: frame.midY), wiring: [tile])
        })
        list.append(nil)
        return list
    }
}

/// Starts an orchestrator in one go: its agents with their roles, a folder, and a first command.
struct BoardOrchestratorComposer: View {
    let controller: BoardController
    @Binding var isPresented: Bool
    @State private var folder = ""
    @State private var goal = ""
    @State private var installed: [BoardAgent]?
    @State private var members: [Row] = []

    private struct Row: Identifiable {
        let id = UUID()
        var agent: String
        var role: String
    }

    private static let limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New orchestrator").font(Extreme.font(15, weight: .semibold)).foregroundColor(Extreme.text)
            Text("An orchestrator card runs the agents wired to it: give it a command and it splits the work, hands it out, reads what each agent answers, and follows up until it's done.")
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
                        ExtremeSectionLabel("Agents")
                        ForEach($members) { $row in
                            HStack(spacing: 8) {
                                agentPicker($row.agent, shell: true).frame(width: 150)
                                TextField("Role", text: $row.role).textFieldStyle(.roundedBorder)
                                Button { members.removeAll { $0.id == row.id } } label: {
                                    Image(systemName: "minus.circle").foregroundColor(Extreme.muted)
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                                .accessibilityLabel("Remove agent")
                            }
                        }
                        Button {
                            members.append(Row(agent: installed.first { $0.binary == "codex" }?.binary ?? installed[0].binary,
                                               role: BoardTeams.roles.first { role in !members.contains { $0.role == role } } ?? "Member"))
                        } label: {
                            Label("Add Agent", systemImage: "plus")
                        }
                        .disabled(members.count >= Self.limit)
                    }
                }
            } else {
                Text("Looking for agents…").font(Extreme.font(11.5)).foregroundColor(Extreme.dim)
            }

            VStack(alignment: .leading, spacing: 6) {
                ExtremeSectionLabel("First command (optional)")
                TextEditor(text: $goal)
                    .font(Extreme.font(12))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Extreme.raised))
                Text("It starts on this once the agents are up. Or give it commands on its card later.")
                    .font(Extreme.font(10.5)).foregroundColor(Extreme.dim)
            }

            HStack {
                Text("\(members.count) of \(Self.limit) agents").font(Extreme.font(11)).foregroundColor(Extreme.muted)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .buttonStyle(ExtremeButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(installed == nil)
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
        guard let installed else { return }
        let rows = members.map { row in
            (agent: installed.first { $0.binary == row.agent }, role: row.role.trimmingCharacters(in: .whitespaces).isEmpty ? "Member" : row.role)
        }
        isPresented = false
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.launchOrchestrator(members: rows, folder: folder.isEmpty ? nil : folder, goal: text.isEmpty ? nil : text)
    }
}
#endif
