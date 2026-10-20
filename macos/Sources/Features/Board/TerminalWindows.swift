#if os(macOS)
import AppKit

/// Classic windows and boards together, for the tools that work with either. In a classic
/// window a new terminal is a tab; on a board it's a tile.
enum TerminalWindows {
    /// Whether a window is a classic window or a board (not the quick terminal).
    static func controller(of window: NSWindow?) -> BaseTerminalController? {
        guard let controller = window?.windowController as? BaseTerminalController,
              controller is TerminalController || controller is BoardController else { return nil }
        return controller
    }

    /// Every classic window and board.
    static var all: [BaseTerminalController] {
        NSApp.windows.compactMap { controller(of: $0) }
    }

    /// The window the user is in: the key one, the main one, or the last classic window used.
    static var front: BaseTerminalController? {
        controller(of: NSApp.keyWindow) ?? controller(of: NSApp.mainWindow)
            ?? TerminalController.preferredParent ?? BoardController.all.first
    }

    /// The controller holding a terminal.
    static func controller(for surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        all.first { $0.surfaceTree.contains(surface) }
    }

    /// Every terminal in every classic window and board, with its controller.
    static var surfaces: [(controller: BaseTerminalController, surface: Ghostty.SurfaceView)] {
        all.flatMap { controller in controller.surfaceTree.map { (controller, $0) } }
    }

    /// A new terminal beside `owner`: a tab in a classic window, a tile on a board. With no
    /// owner, in the front window. `title` names the tab or tile.
    @discardableResult
    static func newTerminal(_ ghostty: Ghostty.App, from owner: BaseTerminalController?,
                            config: Ghostty.SurfaceConfiguration? = nil, title: String? = nil,
                            near: Ghostty.SurfaceView? = nil) -> Ghostty.SurfaceView? {
        let owner = owner ?? front
        if let board = owner as? BoardController {
            guard let view = board.addTile(config: config, near: near) else { return nil }
            if let title { board.setTitle(title, for: view) }
            board.window?.makeKeyAndOrderFront(nil)
            return view
        }
        guard let controller = TerminalController.newTab(ghostty, from: owner?.window, withBaseConfig: config) else { return nil }
        if let title { controller.titleOverride = title }
        return controller.surfaceTree.root?.leftmostLeaf()
    }

    /// The name shown for a terminal: its tile's or tab's name when it has one.
    static func title(of surface: Ghostty.SurfaceView, in controller: BaseTerminalController?) -> String? {
        if let board = controller as? BoardController {
            return board.model.titles[surface.id]
        }
        guard let override = controller?.titleOverride, !override.isEmpty else { return nil }
        return override
    }

    /// Names a terminal's tab, or its tile on a board.
    static func setTitle(_ title: String?, of surface: Ghostty.SurfaceView) {
        guard let controller = controller(for: surface) else { return }
        if let board = controller as? BoardController {
            board.setTitle(title, for: surface)
        } else {
            controller.titleOverride = title
        }
    }

    /// Closes a terminal without asking: its tile on a board, its tab in a classic window.
    static func close(_ surface: Ghostty.SurfaceView) {
        guard let controller = controller(for: surface) else { return }
        if let tab = controller as? TerminalController, tab.surfaceTree.count <= 1 {
            tab.closeTabImmediately()
        } else {
            controller.closeSurface(surface, withConfirmation: false)
        }
    }

    /// Shows a terminal: selects its tab, or moves the board to its tile, and gives it the cursor.
    static func show(_ surface: Ghostty.SurfaceView) {
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyPresentTerminal, object: surface)
    }
}
#endif
