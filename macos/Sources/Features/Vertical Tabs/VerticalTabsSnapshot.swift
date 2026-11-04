#if os(macOS)
import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// Drives sidebar updates by sampling instead of subscribing.
///
/// The sidebar never observes the terminal. Terminal output — even an agent rewriting
/// its title thousands of times a second — costs the sidebar nothing; instead the sidebar
/// samples a handful of values on a fixed clock and redraws only when something changed.
/// Worst-case cost is therefore bounded by the tick rate, not by terminal activity.
final class VerticalTabsTicker {
    static let shared = VerticalTabsTicker()

    let publisher = PassthroughSubject<Void, Never>()

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// Faster while the app is frontmost, slower when it is merely visible.
    private let activeInterval: TimeInterval = 0.5
    private let inactiveInterval: TimeInterval = 2

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.schedule(interval: self?.activeInterval ?? 0.5)
                self?.tick()
            }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.schedule(interval: self?.inactiveInterval ?? 2) }
            .store(in: &cancellables)
        // Switching tabs should show fresh state immediately, not on the next tick.
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.tick() }
            .store(in: &cancellables)
        schedule(interval: NSApp.isActive ? activeInterval : inactiveInterval)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // Generous tolerance lets macOS coalesce our wakeups with others.
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard UserDefaults.standard.verticalTabsVisible else { return }
        publisher.send()
    }

    /// Refresh right away, for rare events that should show without waiting for a tick.
    func tickNow() {
        tick()
    }
}

/// The status badge shown on a pane's icon, following Warp's conversation statuses.
enum VerticalTabBadge: Int, Comparable {
    case none
    case working
    case done
    case bell
    case input
    case permission
    case error

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Status of a plain terminal pane (no agent), from bell and progress reports.
    init(surface: Ghostty.SurfaceView) {
        switch surface.progressReport?.state {
        case .error:
            self = .error
        case _ where surface.bell:
            self = .bell
        case .set, .indeterminate, .pause:
            self = .working
        default:
            self = .none
        }
    }

    var symbol: String? {
        switch self {
        case .none: return nil
        case .working: return "chart.pie.fill"
        case .done: return "checkmark"
        case .bell: return "bell.fill"
        case .input: return "questionmark"
        case .permission: return "stop.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var helpText: String {
        switch self {
        case .none: return ""
        case .working: return "Working"
        case .done: return "Done"
        case .bell: return "Bell"
        case .input: return "Needs input"
        case .permission: return "Needs permission"
        case .error: return "Error"
        }
    }

    func color(_ palette: VerticalTabsPalette) -> Color {
        switch self {
        case .none: return Tellurion.muted
        case .working: return Tellurion.core
        case .done: return Tellurion.live
        case .bell, .input, .permission: return Tellurion.warn
        case .error: return Tellurion.danger
        }
    }
}

/// Status colors taken from the terminal theme's ANSI palette, as Warp does, so they
/// match whatever theme is in use.
struct VerticalTabsPalette: Equatable {
    let red: Color
    let green: Color
    let yellow: Color
    let magenta: Color
    /// The terminal background, which the sidebar is drawn on.
    let background: Color

    static let fallback = VerticalTabsPalette(
        red: .red, green: .green, yellow: .yellow, magenta: .purple,
        background: Color(nsColor: .windowBackgroundColor))

    init(red: Color, green: Color, yellow: Color, magenta: Color, background: Color) {
        self.red = red
        self.green = green
        self.yellow = yellow
        self.magenta = magenta
        self.background = background
    }

    /// Bright ANSI variants (9–13) read better as small glyphs on a dark sidebar.
    init(config: Ghostty.Config) {
        guard let cfg = config.config else {
            self = .fallback
            return
        }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(cfg, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            self = .fallback
            return
        }
        func color(_ index: Int) -> Color {
            withUnsafeBytes(of: palette.colors) { raw in
                let colors = raw.bindMemory(to: ghostty_config_color_s.self)
                let c = colors[index]
                return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
            }
        }
        self.init(red: color(9), green: color(10), yellow: color(11), magenta: color(13),
                  background: config.backgroundColor)
    }
}

/// What the sidebar shows for one pane, captured at a point in time.
struct VerticalTabPaneSnapshot: Equatable, Identifiable {
    let id: ObjectIdentifier
    let title: String
    let pwd: String?
    let badge: VerticalTabBadge
    let isFocused: Bool
    let agent: VerticalTabAgentInfo?

    /// Held weakly so a snapshot never keeps a closed pane alive.
    private let surfaceRef: Weak<Ghostty.SurfaceView>
    var surface: Ghostty.SurfaceView? { surfaceRef.value }

    init(surface: Ghostty.SurfaceView, isFocused: Bool) {
        self.id = ObjectIdentifier(surface)
        self.title = surface.title
        self.pwd = surface.pwd
        let agents = VerticalTabsAgents.shared
        if VerticalTabsAgents.isBeingViewed(surface) { agents.markSeen(surface) }
        let agent = agents.info(for: surface)
        self.agent = agent
        // An agent's own status wins over terminal signals like its bell.
        self.badge = agent?.activity.badge ?? VerticalTabBadge(surface: surface)
        self.isFocused = isFocused
        self.surfaceRef = Weak(surface)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.pwd == rhs.pwd
            && lhs.badge == rhs.badge && lhs.isFocused == rhs.isFocused && lhs.agent == rhs.agent
    }
}

/// What the sidebar shows for one tab, captured at a point in time.
struct VerticalTabSnapshot: Equatable {
    let title: String
    let panes: [VerticalTabPaneSnapshot]

    static let empty = VerticalTabSnapshot(title: "", panes: [])

    init(title: String, panes: [VerticalTabPaneSnapshot]) {
        self.title = title
        self.panes = panes
    }

    init(controller: TerminalController) {
        let focused = controller.focusedSurface
        self.title = controller.window?.title ?? ""
        self.panes = controller.surfaceTree.map {
            VerticalTabPaneSnapshot(surface: $0, isFocused: $0 === focused)
        }
    }

    /// The pane whose folder represents the tab.
    var representative: VerticalTabPaneSnapshot? {
        panes.first(where: \.isFocused) ?? panes.first
    }

    /// The most urgent badge among the tab's panes.
    var badge: VerticalTabBadge {
        panes.map(\.badge).max() ?? .none
    }

    /// True when some pane has an agent result the user hasn't looked at.
    var hasUnseen: Bool {
        panes.contains { $0.agent?.unseen == true }
    }
}
#endif
