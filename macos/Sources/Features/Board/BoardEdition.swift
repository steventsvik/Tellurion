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

    /// Switches editions. Turning boards on opens one, unless one is open already.
    static func set(_ edition: ExtremeEdition) {
        let changed = edition != current || !chosen
        UserDefaults.standard.set(edition.rawValue, forKey: key)
        guard changed else { return }
        ExtremeSettings.shared.objectWillChange.send()
        if edition == .board, BoardController.all.isEmpty, let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty {
            Board.openAtLaunch(ghostty)
        }
    }
}

/// Opening boards.
enum Board {
    /// At launch (and from the Dock with no windows): the boards that were open last time,
    /// or a new one.
    static func openAtLaunch(_ ghostty: Ghostty.App) {
        let open = BoardStore.all().filter(\.open)
        if open.isEmpty {
            newBoard(ghostty)
            return
        }
        // Oldest first, so the most recent ends up in front.
        for workspace in open.reversed() {
            BoardController.open(ghostty, workspace: workspace, restoring: true)
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
