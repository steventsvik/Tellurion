#if os(macOS)
import AppKit
import SwiftUI

/// The kinds of session the sidebar's "New" menu can open, like Warp's new-session menu.
enum NewSessionKind: CaseIterable, Identifiable {
    case terminal
    case claude
    case codex
    case hermes
    case cloudClaude

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .hermes: return "Hermes"
        case .cloudClaude: return "Cloud Agent · Claude Code"
        }
    }

    var agent: VerticalTabAgentKind? {
        switch self {
        case .terminal: return nil
        case .claude, .cloudClaude: return .claude
        case .codex: return .codex
        case .hermes: return .hermes
        }
    }

    /// Typed into a normal shell, so the shell's features stay and exiting the agent
    /// returns to the prompt.
    var command: String? {
        switch self {
        case .terminal, .hermes: return nil
        case .claude: return "claude"
        case .codex: return "codex"
        // A Claude Code cloud session (runs on Anthropic's servers, same as claude.ai/code).
        case .cloudClaude: return "claude --cloud"
        }
    }

    /// A new tab beside `owner`, or a new tile when it's a board.
    func open(from owner: BaseTerminalController) {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = owner.focusedSurface?.pwd
        if let command { config.initialInput = command + "\n" }
        guard let surface = TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config) else { return }
        if self == .hermes, let controller = TerminalWindows.controller(for: surface) {
            HermesSessions.shared.adopt(surface, in: controller)
        }
    }
}

/// "+ New" in the sidebar header: a pixel button that opens a menu of session kinds.
/// (SwiftUI menus drop custom label drawing on macOS, so this pops up an NSMenu instead.)
struct NewSessionMenu: View {
    let owner: BaseTerminalController
    let compact: Bool

    var body: some View {
        ExtremeIconButton(icon: .plus, label: compact ? "New" : "New tab", help: "New session", tint: Extreme.gold) {
            NewSessionMenuBuilder.popUp(for: owner)
        }
    }
}

enum NewSessionMenuBuilder {
    static func popUp(for owner: BaseTerminalController) {
        let menu = NSMenu()
        for kind in NewSessionKind.allCases {
            if kind == .hermes || kind == .cloudClaude { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(kind.title, image: icon(for: kind)) { kind.open(from: owner) })
            if kind == .codex { menu.addItem(dockerItem(owner)) }
        }
        if ExtremeSettings.isOn(.localhost) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Localhost Server…", image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)) {
                LocalhostManager.showNewServer(folder: owner.focusedSurface?.pwd, from: owner)
            })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private static func dockerItem(_ owner: BaseTerminalController) -> NSMenuItem {
        let item = NSMenuItem(title: "Isolated Session (Docker)", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
        let submenu = NSMenu()
        for kind in DockerSessionKind.allCases {
            if kind == .claude { submenu.addItem(.separator()) }
            submenu.addItem(ClosureMenuItem("\(kind.title) — \(kind.detail)", image: nil) { DockerSessions.open(kind, from: owner) })
        }
        submenu.addItem(.separator())
        let share = ClosureMenuItem("Share this tab's folder", image: nil) {
            let defaults = UserDefaults.standard
            defaults.set(!(defaults.object(forKey: DockerSessions.shareFolderKey) as? Bool ?? true), forKey: DockerSessions.shareFolderKey)
        }
        share.state = (UserDefaults.standard.object(forKey: DockerSessions.shareFolderKey) as? Bool ?? true) ? .on : .off
        submenu.addItem(share)
        item.submenu = submenu
        return item
    }

    /// Menu item icons are images, so draw each logo into one.
    private static func icon(for kind: NewSessionKind) -> NSImage? {
        if let agent = kind.agent, let asset = agent.logoAsset, let image = NSImage(named: asset),
           let copy = image.copy() as? NSImage {
            copy.size = NSSize(width: 16, height: 16)
            copy.isTemplate = agent.logoIsTemplate
            return copy
        }
        return NSImage(systemSymbolName: kind == .cloudClaude ? "cloud" : "apple.terminal", accessibilityDescription: nil)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage?, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.image = image
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
#endif
