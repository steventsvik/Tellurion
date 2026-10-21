#if os(macOS)
import AppKit

/// Tellurion in the menu bar: a symbol that fills while agents work, with a count when some
/// need you. Its menu lists the agents (those waiting first; choose one to go to it), your
/// boards, and new boards, sketches and agents. Off with the Menu bar feature.
final class MenuBarStatus: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatus()

    private var item: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var refreshQueued = false

    /// Shows or hides the item to match the setting; called at launch and when it changes.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [VerticalTabsAgents.didChange, AgentAlerts.waitingCountDidChange, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.queueRefresh() })
        }
        observers.append(center.addObserver(forName: ExtremeSettings.featuresDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        })
        apply()
    }

    private func apply() {
        if ExtremeSettings.isOn(.menuBar) {
            if item == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.behavior = .removalAllowed
                item.autosaveName = "com.steventsvik.ghostty-extreme.menu-bar"
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
                self.item = item
            }
            refresh()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Agent events come in bursts; the icon updates once per turn of the run loop.
    private func queueRefresh() {
        guard item != nil, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    private struct Agent {
        let surface: Ghostty.SurfaceView
        let controller: BaseTerminalController
        let info: VerticalTabAgentInfo
    }

    private var agents: [Agent] {
        TerminalWindows.surfaces.compactMap { pair in
            VerticalTabsAgents.shared.info(for: pair.surface).map { Agent(surface: pair.surface, controller: pair.controller, info: $0) }
        }
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let all = agents
        let waiting = all.filter { AgentAlerts.isWaiting($0.info.activity) }.count
        let working = all.contains { $0.info.activity == .working }
        let symbol = waiting > 0 ? "exclamationmark.bubble.fill" : working ? "rectangle.3.group.fill" : "rectangle.3.group"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tellurion")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = waiting > 0 ? " \(waiting)" : ""
        let summary = waiting > 0 ? "\(waiting) \(waiting == 1 ? "agent needs" : "agents need") you"
            : working ? "Agents are working" : "Tellurion"
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let all = agents
        let order: [(String, (VerticalTabAgentActivity) -> Bool)] = [
            ("Needs You", AgentAlerts.isWaiting),
            ("Working", { $0 == .working }),
            ("Finished", { $0 == .done || $0 == .failed }),
            ("Ready", { $0 == .ready }),
        ]
        for (heading, matches) in order {
            let group = all.filter { matches($0.info.activity) }
            guard !group.isEmpty else { continue }
            menu.addItem(Self.header(heading))
            for agent in group.prefix(12) { menu.addItem(item(for: agent)) }
        }
        if all.isEmpty {
            let none = NSMenuItem(title: "No agents running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        menu.addItem(.separator())
        let boards = BoardStore.all()
        if !boards.isEmpty {
            menu.addItem(Self.header("Boards"))
            let open = Set(BoardController.all.map(\.workspace.id))
            for board in boards.prefix(8) {
                let item = ClosureMenuItem(board.name, image: NSImage(systemSymbolName: "square.grid.3x3.square", accessibilityDescription: nil)) {
                    Self.withApp { Board.reopen($0, board) }
                }
                item.state = open.contains(board.id) ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("New Sketch", image: NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: nil)) {
            Self.withBoard { $0.addSketch() }
        })
        menu.addItem(ClosureMenuItem("Launch Agents…", image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)) {
            Self.withBoard { $0.model.showComposer = true }
        })
        menu.addItem(ClosureMenuItem("New Board", image: NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)) {
            Self.withApp { Board.newBoard($0) }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…", image: nil) {
            NSApp.activate(ignoringOtherApps: true)
            ExtremeSettingsWindow.show()
        })
    }

    private func item(for agent: Agent) -> NSMenuItem {
        let name = TerminalWindows.title(of: agent.surface, in: agent.controller) ?? agent.info.name
        let place = (agent.controller as? BoardController)?.model.name ?? agent.surface.pwd.map { ($0 as NSString).lastPathComponent }
        let item = ClosureMenuItem(name, image: Self.dot(NSColor(AgentStatusPill.color(agent.info.activity)))) { [weak surface = agent.surface] in
            guard let surface else { return }
            NSApp.activate(ignoringOtherApps: true)
            TerminalWindows.show(surface)
        }
        // The task or question on a second line, like a notification.
        let detail = [agent.info.activity.label, place, agent.info.detail ?? agent.info.task]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        if #available(macOS 14.4, *) { item.subtitle = String(detail.prefix(80)) } else { item.toolTip = detail }
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private static func withApp(_ body: (Ghostty.App) -> Void) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        NSApp.activate(ignoringOtherApps: true)
        body(delegate.ghostty)
    }

    /// The front board, opening one when there's none.
    private static func withBoard(_ body: @escaping (BoardController) -> Void) {
        withApp { ghostty in
            let board = BoardController.front ?? Board.newBoard(ghostty)
            board.show()
            DispatchQueue.main.async { body(board) }
        }
    }
}
#endif
