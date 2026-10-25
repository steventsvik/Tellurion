#if os(macOS)
import AppKit

/// How Tellurion shows terminals: classic windows with tabs and splits, or boards, where every
/// terminal is a tile on a canvas you pan and zoom. Chosen in the welcome window or Settings;
/// it decides what a new window is. Either way the other kind can still be opened.
enum ExtremeEdition: String, CaseIterable, Identifiable {
    case classic
    case board

    var id: String { rawValue }

    static let key = "ExtremeEdition"

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .board: return "Board"
        }
    }

    var detail: String {
        switch self {
        case .classic: return "Windows with tabs and splits, and the agent sidebar"
        case .board: return "Every terminal is a tile on a board you pan and zoom, with a list of your agents beside it"
        }
    }

    static var current: ExtremeEdition {
        ExtremeEdition(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .classic
    }

    /// Whether the edition has been picked (a fresh install hasn't).
    static var chosen: Bool { UserDefaults.standard.string(forKey: key) != nil }

    /// Switches editions. Picking Board brings a board to the front (opening one if none is),
    /// and offers to move the terminals of open classic windows onto it. Picking Classic offers
    /// to move the boards' tiles into windows, and closes the boards.
    static func set(_ edition: ExtremeEdition) {
        let changed = edition != current || !chosen
        UserDefaults.standard.set(edition.rawValue, forKey: key)
        if changed { ExtremeSettings.shared.objectWillChange.send() }
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }
        switch edition {
        case .board: Board.activate(ghostty)
        case .classic: Board.deactivate(ghostty)
        }
    }
}

/// Opening boards.
enum Board {
    /// At launch (and from the Dock with no windows): the boards that were open last time,
    /// or a new one. Returns the one in front.
    @discardableResult
    static func openAtLaunch(_ ghostty: Ghostty.App) -> BoardController {
        let open = BoardStore.all().filter(\.open)
        guard !open.isEmpty else { return newBoard(ghostty) }
        // Oldest first, so the most recent ends up in front.
        var front: BoardController?
        for workspace in open.reversed() {
            front = BoardController.open(ghostty, workspace: workspace, restoring: true)
        }
        return front ?? newBoard(ghostty)
    }

    /// Brings a board to the front: the one you were on, else the saved ones, else a new one.
    @discardableResult
    static func show(_ ghostty: Ghostty.App) -> BoardController {
        if let board = BoardController.front {
            board.show()
            return board
        }
        return openAtLaunch(ghostty)
    }

    /// Switching to Board from Settings or the welcome window. With classic windows open, asks
    /// whether their terminals should come along as tiles; the windows close when they do.
    static func activate(_ ghostty: Ghostty.App) {
        let terminals = TerminalController.all.filter { !$0.surfaceTree.isEmpty }
        let views = terminals.flatMap { Array($0.surfaceTree) }
        guard !views.isEmpty else {
            show(ghostty)
            return
        }
        let alert = NSAlert()
        let count = views.count
        alert.messageText = count == 1 ? "Move your terminal to the board?" : "Move your \(count) terminals to the board?"
        alert.informativeText = "Each tab and split becomes a tile, laid out by project, and the windows close. "
            + "Agents keep running. Keep Windows opens the board beside them instead."
        alert.addButton(withTitle: "Move to Board")
        alert.addButton(withTitle: "Keep Windows")
        let decide: (NSApplication.ModalResponse) -> Void = { response in
            let board = show(ghostty)
            guard response == .alertFirstButtonReturn else { return }
            // A terminal that left a board with the switch to Classic goes back to it (reopened
            // by `show`) when it's open; the rest go onto the front board.
            var homes: [(board: BoardController, views: [Ghostty.SurfaceView])] = []
            for view in views {
                let home = BoardController.all.first { $0.model.released.contains { $0.id == view.id } } ?? board
                if let index = homes.firstIndex(where: { $0.board === home }) {
                    homes[index].views.append(view)
                } else {
                    homes.append((home, [view]))
                }
            }
            // The first adoption empties every window; the others get terminals already out of theirs.
            for (index, home) in homes.enumerated() { home.board.adopt(home.views, from: index == 0 ? terminals : []) }
        }
        ask(alert, then: decide)
    }

    /// Switching to Classic from Settings or the welcome window. With tiles on the open boards,
    /// asks whether they should become tabs in windows; the boards close either way when
    /// they're empty, and when their tiles move. A board keeps the ink, groups and wires of the
    /// terminals that left it, and stays open in its file for the switch back (see
    /// `BoardController.releaseForClassic`).
    static func deactivate(_ ghostty: Ghostty.App) {
        let boards = BoardController.all
        let views = boards.flatMap { Array($0.surfaceTree) }
        guard !views.isEmpty else {
            _ = leave(boards)
            if let window = TerminalController.preferredParent?.window ?? TerminalController.all.first?.window {
                // The welcome window is still choosing; a window coming forward would cover it.
                if !AgentToolWindows.isOpen(WelcomeWindow.windowID) { window.makeKeyAndOrderFront(nil) }
            } else {
                _ = TerminalController.newWindow(ghostty)
            }
            return
        }
        let alert = NSAlert()
        let count = views.count
        alert.messageText = count == 1 ? "Move your terminal to a window?" : "Move your \(count) terminals to windows?"
        alert.informativeText = "Each tile becomes a tab, with a window per project, and the board closes. "
            + "Agents keep running. Keep Board opens a window beside it instead."
        alert.addButton(withTitle: "Move to Windows")
        alert.addButton(withTitle: "Keep Board")
        ask(alert) { response in
            guard response == .alertFirstButtonReturn else {
                _ = TerminalController.newWindow(ghostty)
                return
            }
            release(boards, ghostty)
        }
    }

    /// Tiles become tabs: a window per project, in the order they were on the board. The
    /// terminals themselves aren't touched, so their agents keep running.
    private static func release(_ boards: [BoardController], _ ghostty: Ghostty.App) {
        // Out of the boards first, which keep their places, ink, groups and wires for them.
        let views = leave(boards)
        let folders = Dictionary(uniqueKeysWithValues: views.map { ($0.id, $0.pwd) })
        var groups: [(project: String, views: [Ghostty.SurfaceView])] = []
        for view in views {
            let project = BoardProjects.project(of: folders[view.id] ?? nil) ?? ""
            if let index = groups.firstIndex(where: { $0.project == project }) {
                groups[index].views.append(view)
            } else {
                groups.append((project, [view]))
            }
        }
        var controllers: [[TerminalController]] = []
        for group in groups {
            var windows: [TerminalController] = []
            for view in group.views {
                let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: view))
                guard let window = controller.window else { continue }
                if let previous = windows.last?.window, window.tabbingMode != .disallowed {
                    _ = previous.addTabbedWindowSafely(window, ordered: .above)
                }
                windows.append(controller)
            }
            controllers.append(windows)
        }
        // Shown a tick later, as new windows are, so each window's frame is set before it cascades.
        DispatchQueue.main.async {
            for windows in controllers {
                for controller in windows { controller.showWindow(nil) }
                if let window = windows.first?.window { TerminalController.applyCascade(to: window, hasFixedPos: false) }
            }
            controllers.first?.first?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The boards close for Classic: their tiles come out first (returned) and stay with them
    /// as released tiles, and each board stays open in its file for the switch back. Hidden
    /// boards close first, so none comes forward in a closing one's place.
    private static func leave(_ boards: [BoardController]) -> [Ghostty.SurfaceView] {
        let views = boards.flatMap { $0.releaseForClassic() }
        let hidden = boards.filter { $0.window?.isVisible != true }
        for board in hidden + boards.filter({ $0.window?.isVisible == true }) {
            board.window?.close()
        }
        return views
    }

    /// Over the key window when it can take a sheet, else app-modal. A sheet that's up (another
    /// question) is key itself; its window already has a sheet, so rather than going onto the
    /// sheet, this question runs app-modal.
    private static func ask(_ alert: NSAlert, then decide: @escaping (NSApplication.ModalResponse) -> Void) {
        var window = NSApp.keyWindow
        while let parent = window?.sheetParent { window = parent }
        if let window, window.sheets.isEmpty, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: decide)
        } else {
            decide(alert.runModal())
        }
    }

    /// A new, empty board, in place of the front board.
    @discardableResult
    static func newBoard(_ ghostty: Ghostty.App, folder: String? = nil) -> BoardController {
        let front = BoardController.front
        let start = folder ?? front?.workspace.folder ?? front?.focusedSurface?.pwd
        let workspace = BoardWorkspace(name: BoardStore.newName(), folder: start)
        return BoardController.open(ghostty, workspace: workspace, restoring: false)
    }

    /// Switches to a saved board: brings it forward when it's open, else opens it, either way
    /// in place of the front board. `newWindow` shows it in a window of its own instead.
    static func reopen(_ ghostty: Ghostty.App, _ workspace: BoardWorkspace, newWindow: Bool = false) {
        if let open = BoardController.all.first(where: { $0.workspace.id == workspace.id }) {
            if newWindow, open.window?.isVisible == false, let window = open.window, let front = BoardController.front?.window {
                window.setFrame(front.frame.offsetBy(dx: 30, dy: -30), display: false)
                window.makeKeyAndOrderFront(nil)
            } else {
                open.show()
            }
            return
        }
        var workspace = workspace
        workspace.open = true
        BoardController.open(ghostty, workspace: workspace, restoring: true, newWindow: newWindow)
    }

    /// Deletes a board after asking: an open one is closed first.
    static func delete(_ workspace: BoardWorkspace, from board: BoardController) {
        if let open = BoardController.all.first(where: { $0.workspace.id == workspace.id }) {
            open.confirmDelete()
            return
        }
        guard let window = board.window else { return }
        confirmDelete(workspace.name, closingTerminals: false, in: window) {
            BoardStore.delete(workspace.id)
            NotificationCenter.default.post(name: BoardController.boardsDidChange, object: nil)
        }
    }

    static func confirmDelete(_ name: String, closingTerminals: Bool, in window: NSWindow, then delete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = closingTerminals
            ? "Its terminals are closed, and its sketches, notes and maps are deleted. You can't undo this."
            : "Its sketches, notes and maps are deleted. You can't undo this."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { delete() }
        }
    }
}
#endif

#if os(macOS)
import SwiftUI

/// Classic or Board, as two cards. Used by the welcome window and Settings.
struct EditionPicker: View {
    @ObservedObject private var settings = ExtremeSettings.shared

    var body: some View {
        let current = ExtremeEdition.current
        HStack(spacing: 10) {
            ForEach(ExtremeEdition.allCases) { edition in
                Button { ExtremeEdition.set(edition) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Image(systemName: edition == .board ? "square.grid.3x3.square" : "sidebar.left")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(edition == current ? Extreme.gold : Extreme.muted)
                            Text(edition.title).font(Extreme.font(12.5, weight: .semibold)).foregroundColor(Extreme.text)
                            Spacer(minLength: 0)
                            if edition == current {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(Extreme.gold)
                            }
                        }
                        Text(edition.detail).font(Extreme.font(11)).foregroundColor(Extreme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(edition == current ? Extreme.raised : Extreme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(edition == current ? Extreme.gold.opacity(0.7) : Extreme.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(edition.title): \(edition.detail)")
                .accessibilityAddTraits(edition == current ? .isSelected : [])
            }
        }
    }
}
#endif
