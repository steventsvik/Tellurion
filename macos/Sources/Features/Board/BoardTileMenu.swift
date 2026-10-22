#if os(macOS)
import AppKit
import SwiftUI

/// What a tile offers from its title bar's menu and its row in the board's list: the same
/// tools a classic tab's ⋮ menu has, for that one terminal.
enum BoardTileMenu {
    /// One command; nil in a list is a separator.
    struct Action {
        let title: String
        var enabled = true
        let run: () -> Void
    }

    static func actions(for surface: Ghostty.SurfaceView, in board: BoardController) -> [Action?] {
        let settings = ExtremeSettings.shared
        let pwd = surface.pwd
        let agent = VerticalTabsAgents.shared.info(for: surface)
        let hermes = HermesSessions.shared.isHermes(surface: surface)
        // Tools that work on "the tab's focused pane" act on this tile.
        func here(_ action: @escaping () -> Void) -> () -> Void {
            { [weak board, weak surface] in
                guard let board, let surface else { return }
                board.focusTile(surface)
                action()
            }
        }

        var list: [Action?] = [
            Action(title: "Show at Full Size") { [weak board] in board?.focusTile(surface) },
            Action(title: "Rename Tile…") { [weak board] in board?.promptTitle(for: surface) },
            nil,
        ]
        if !hermes {
            for mode in AgentHandoff.Mode.quick {
                for target in AgentHandoff.targets {
                    list.append(Action(title: AgentHandoff.title(mode, target), enabled: pwd != nil) { [weak board] in
                        guard let board else { return }
                        AgentHandoff.handOff(from: surface, in: board, to: target, mode: mode)
                    })
                }
            }
            list.append(Action(title: "Hand Off…") { [weak board] in
                guard let board else { return }
                AgentHandoff.showWindow(from: surface, in: board)
            })
            list.append(Action(title: "Start a Review Loop…", enabled: agent != nil) { [weak board] in
                guard let board else { return }
                PipelineSetup.show(writer: surface, in: board)
            })
            if settings.isOn(.races) {
                list.append(Action(title: "Race Agents on This Project…", enabled: pwd != nil, run: here { [weak board] in
                    guard let board else { return }
                    AgentRaces.showSetup(from: board)
                }))
            }
            list.append(nil)
            list.append(Action(title: "Show on Agent Map", enabled: pwd != nil) { [weak board] in
                board?.showAgentMap(for: surface)
            })
            if settings.isOn(.visualFix) {
                list.append(Action(title: VisualFixPanel.shared.isVisible(board) ? "Close Visual Fix" : "Visual Fix…",
                                   run: here { [weak board] in VisualFixPanel.shared.toggle(board) }))
            }
            if settings.isOn(.commandHistory) {
                list.append(Action(title: CommandBlocksPanel.shared.isVisible(board) ? "Close Command History" : "Command History",
                                   run: here { [weak board] in
                    guard let board else { return }
                    CommandBlocksPanel.shared.toggle(board)
                }))
            }
            if settings.isOn(.memory) {
                list.append(Action(title: "Project Memory…", enabled: pwd != nil) { MemoryWindow.show(folder: pwd) })
            }
        }
        list.append(nil)
        list.append(contentsOf: groupActions(for: surface.id, in: board))
        list.append(contentsOf: accountActions(for: surface, in: board))
        list.append(contentsOf: BoardTeamMenu.actions(for: surface.id, in: board))
        list.append(contentsOf: undoActions(for: surface))
        list.append(nil)
        list.append(Action(title: "Copy Working Directory", enabled: pwd != nil) { VerticalTabsActions.copy(pwd ?? "") })
        list.append(nil)
        list.append(Action(title: "Close Tile") { [weak board] in board?.close(surface) })
        return list
    }

    /// Starting the tile's agent on another account.
    private static func accountActions(for surface: Ghostty.SurfaceView, in board: BoardController) -> [Action?] {
        guard ExtremeSettings.isOn(.accounts), let kind = VerticalTabsAgents.shared.info(for: surface)?.kind,
              let provider = BoardAccount.Provider.allCases.first(where: { $0.kind == kind }) else { return [] }
        let profiles = BoardAccounts.shared.accounts.filter { $0.provider == provider }
        guard !profiles.isEmpty else { return [] }
        let current = board.model.tileAccounts[surface.id]?[provider]
        var list: [Action?] = []
        if current != nil {
            list.append(Action(title: "Use Your Usual Sign-in") { [weak board] in board?.switchAccount(surface, to: nil, provider: provider) })
        }
        for profile in profiles where profile.id != current {
            list.append(Action(title: "Use \(profile.name)") { [weak board] in board?.switchAccount(surface, to: profile, provider: provider) })
        }
        return list
    }

    /// Making groups and moving the tile between them.
    private static func groupActions(for tile: UUID, in board: BoardController) -> [Action?] {
        var list: [Action?] = []
        let own = board.namedGroup(containing: tile)
        if let own {
            list.append(Action(title: "Remove from \(own.name)") { [weak board] in board?.removeFromGroup(tile) })
        } else {
            list.append(Action(title: "New Group with This Tile") { [weak board] in
                guard let board else { return }
                let id = board.createGroup([tile])
                board.promptRenameGroup(id)
            })
        }
        for group in board.model.groups where group.id != own?.id {
            list.append(Action(title: "Add to \(group.name)") { [weak board] in board?.addToGroup([tile], group: group.id) })
        }
        return list
    }

    /// Undo the agent's last turn, an earlier one, or a restore (see TurnCheckpoints).
    private static func undoActions(for surface: Ghostty.SurfaceView) -> [Action?] {
        guard ExtremeSettings.isOn(.undo) else { return [] }
        let list = TurnCheckpoints.shared.list(for: surface)
        guard !list.isEmpty else { return [] }
        let lastTurn = list.last { !$0.isRestorePoint }?.id
        return [nil] + list.suffix(4).reversed().map { checkpoint in
            let prompt = TurnCheckpoints.short(checkpoint.title, 34)
            let title = checkpoint.isRestorePoint ? "Undo Restore"
                : checkpoint.id == lastTurn ? "Undo Last Turn: “\(prompt)”"
                : "Restore to Before “\(prompt)”"
            return Action(title: title) { TurnCheckpoints.shared.confirmAndRestore(checkpoint, on: surface) }
        }
    }

    /// The menu for a right-click on a tile's title bar.
    static func menu(for surface: Ghostty.SurfaceView, in board: BoardController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions(for: surface, in: board) {
            guard let action else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            // After the menu closes, so prompts and windows it opens come to the front.
            let item = ClosureMenuItem(action.title, image: nil) { DispatchQueue.main.async(execute: action.run) }
            item.isEnabled = action.enabled
            menu.addItem(item)
        }
        return menu
    }
}

/// The same commands as a SwiftUI context menu, for the list beside the board.
struct BoardTileContextMenu: View {
    let surface: Ghostty.SurfaceView
    let board: BoardController

    var body: some View {
        let actions = BoardTileMenu.actions(for: surface, in: board)
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            if let action {
                Button(action.title) { DispatchQueue.main.async(execute: action.run) }.disabled(!action.enabled)
            } else {
                Divider()
            }
        }
    }
}
#endif
