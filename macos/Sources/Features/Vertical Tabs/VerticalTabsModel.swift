#if os(macOS)
import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted whenever the set, order, or decoration of tabs may have changed.
    static let verticalTabsNeedRefresh = Notification.Name("com.steventsvik.ghostty-extreme.verticalTabsNeedRefresh")
}

enum VerticalTabs {
    /// UserDefaults key backing the sidebar's visibility (shared by all windows).
    static let visibleKey = "VerticalTabsVisible"

    /// UserDefaults key backing the sidebar's width.
    static let widthKey = "VerticalTabsWidth"

    /// UserDefaults key for the one-line-per-pane "condensed" layout.
    static let condensedKey = "VerticalTabsCondensed"

    static let defaultWidth: Double = 290
    static let widthRange: ClosedRange<Double> = 180...420

    static func setNeedsRefresh() {
        NotificationCenter.default.post(name: .verticalTabsNeedRefresh, object: nil)
    }

    /// Horizontal space the sidebar occupies, including its divider.
    static var occupiedWidth: CGFloat {
        let stored = UserDefaults.standard.object(forKey: widthKey) as? Double ?? defaultWidth
        return CGFloat(min(max(stored, widthRange.lowerBound), widthRange.upperBound)) + 1
    }

    /// The window content size needed to give the terminal `size` with the sidebar beside it.
    static func contentSize(forTerminal size: NSSize) -> NSSize {
        guard UserDefaults.standard.verticalTabsVisible else { return size }
        return NSSize(width: size.width + occupiedWidth, height: size.height)
    }

    /// Width the sidebar currently takes from the window, or 0 when hidden. Ghostty
    /// stores this alongside the "last window frame" it uses to size new windows.
    static var currentSidebarWidth: Double {
        UserDefaults.standard.verticalTabsVisible ? Double(occupiedWidth) : 0
    }

    /// Converts a saved window width to one that gives the terminal the same size it had
    /// when saved, accounting for the sidebar being shown, hidden, or resized since.
    static func restoredWindowWidth(_ savedWidth: Double, savedSidebarWidth: Double) -> Double {
        savedWidth - savedSidebarWidth + currentSidebarWidth
    }

    /// Widens a newly created window so the sidebar is added beside the terminal
    /// rather than taking columns away from it.
    static func widenNewWindow(_ window: NSWindow) {
        guard UserDefaults.standard.verticalTabsVisible else { return }
        resize(window, by: occupiedWidth)
    }

    /// Grows (or shrinks) the window on the sidebar's side so the terminal keeps its size
    /// and position on screen when the sidebar appears or disappears.
    static func resize(_ window: NSWindow, by delta: CGFloat) {
        window.grow(by: delta, onLeft: WindowLayout.isLeftOfTerminal(.tabs), animate: false)
    }
}

/// One entry in the sidebar. Holds the controller weakly so the sidebar never
/// keeps a closed tab alive.
struct VerticalTabEntry: Identifiable, Equatable {
    let id: ObjectIdentifier
    weak var controller: TerminalController?
    let tabColor: TerminalTabColor

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.tabColor == rhs.tabColor
    }
}

/// The ordered list of tabs in the tab group of the window that owns this sidebar.
/// Each window has its own model, but they all derive from the same tab group so
/// every sidebar in a group shows the same list.
final class VerticalTabsModel: ObservableObject {
    @Published private(set) var tabs: [VerticalTabEntry] = []
    /// Whether the owning window is the visible tab of its group.
    @Published private(set) var isSelectedTab = true

    private weak var owner: TerminalController?
    private var cancellables: Set<AnyCancellable> = []

    /// Watches the native tab bar so it can be re-hidden the moment macOS shows it
    /// (it does so on its own whenever a tab is added).
    private var tabBarObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?

    init(owner: TerminalController) {
        self.owner = owner

        let center = NotificationCenter.default
        Publishers.Merge3(
            center.publisher(for: .verticalTabsNeedRefresh),
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: NSWindow.willCloseNotification))
            // Tab group membership settles a runloop tick after these events, and
            // bursts (e.g. closing several tabs) collapse into one refresh.
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        UserDefaults.standard.publisher(for: \.VerticalTabsVisible)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard let owner, let window = owner.window else { return }

        let windows = window.tabGroup?.windows ?? [window]
        let newTabs = windows.compactMap { window -> VerticalTabEntry? in
            guard let controller = window.windowController as? TerminalController else { return nil }
            return VerticalTabEntry(
                id: ObjectIdentifier(controller),
                controller: controller,
                tabColor: (window as? TerminalWindow)?.tabColor ?? .none)
        }
        // Only publish real changes; refresh is triggered by many window events.
        if newTabs != tabs {
            tabs = newTabs
        }
        let selected = window.tabGroup.map { $0.selectedWindow === window } ?? true
        if selected != isSelectedTab { isSelectedTab = selected }

        syncNativeTabBar(window: window)
    }

    /// Keeps the native tab bar hidden (see `TerminalWindow.hideNativeTabBar`). macOS may
    /// re-show it when the tab group's tab bar visibility changes.
    private func syncNativeTabBar(window: NSWindow) {
        guard let tabGroup = window.tabGroup else { return }

        if observedTabGroup !== tabGroup {
            observedTabGroup = tabGroup
            tabBarObservation = tabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { (self?.owner?.window as? TerminalWindow)?.hideNativeTabBar() }
            }
        }
        (window as? TerminalWindow)?.hideNativeTabBar()
    }
}

extension UserDefaults {
    /// KVO-observable accessor; the key path name must match `VerticalTabs.visibleKey`.
    // swiftlint:disable:next identifier_name
    @objc dynamic var VerticalTabsVisible: Bool {
        object(forKey: VerticalTabs.visibleKey) as? Bool ?? true
    }

    var verticalTabsVisible: Bool { VerticalTabsVisible }
}

// MARK: - Menu

/// Installs "Toggle Vertical Tabs" (⌃⌘S), "Toggle Code Editor" (⌃⌘E), a ⌘P command
/// palette shortcut, "Mission Control" (⌃⌘M), "Race Agents…" (⌃⌘R), "Localhost Manager"
/// (⌃⌘L), "Review Changes" (⌃⌘I), "Command History" (⌃⌘B), "Agent Activity" (⌃⌘A),
/// "Project Memory" (⌃⌘Y) and "Keyboard Shortcuts" (⌃⌘/) in the View menu, and
/// Tellurion's Settings (⌘,), Check Setup and Welcome in the app menu. Items of features turned off in Settings are hidden, which
/// also turns off their shortcuts.
final class VerticalTabsMenu: NSObject {
    static let shared = VerticalTabsMenu()
    private var installed = false
    /// Menu items that belong to an optional feature.
    private var featureItems: [(NSMenuItem, ExtremeFeature)] = []

    func installIfNeeded() {
        guard !installed, let mainMenu = NSApp.mainMenu else { return }
        guard let viewMenu = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu else { return }
        installed = true

        let item = NSMenuItem(
            title: "Toggle Vertical Tabs",
            action: #selector(toggle(_:)),
            keyEquivalent: "s")
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = self
        viewMenu.insertItem(item, at: 0)
        EditorPanel.installMenuItem(in: viewMenu, at: 1)
        // ⌘P opens the command palette too (Ghostty's own shortcut is ⌘⇧P).
        let palette = NSMenuItem(
            title: "Go to Tab or Command…",
            action: #selector(BaseTerminalController.toggleCommandPalette(_:)),
            keyEquivalent: "p")
        palette.keyEquivalentModifierMask = [.command]
        viewMenu.insertItem(palette, at: 2)
        let mission = NSMenuItem(title: "Mission Control", action: #selector(showMissionControl(_:)), keyEquivalent: "m")
        mission.keyEquivalentModifierMask = [.control, .command]
        mission.target = self
        viewMenu.insertItem(mission, at: 3)
        featureItems.append((mission, .missionControl))
        let race = NSMenuItem(title: "Race Agents…", action: #selector(raceAgents(_:)), keyEquivalent: "r")
        race.keyEquivalentModifierMask = [.control, .command]
        race.target = self
        viewMenu.insertItem(race, at: 4)
        featureItems.append((race, .races))
        struct Extra { let title: String; let action: Selector; let key: String; let feature: ExtremeFeature? }
        let extras: [Extra] = [
            Extra(title: "Localhost Manager", action: #selector(showLocalhost(_:)), key: "l", feature: .localhost),
            Extra(title: "Review Changes", action: #selector(showReview(_:)), key: "i", feature: .review),
            Extra(title: "Command History", action: #selector(toggleCommandBlocks(_:)), key: "b", feature: .commandHistory),
            Extra(title: "Agent Activity", action: #selector(showActivity(_:)), key: "a", feature: .activity),
            Extra(title: "Visual Fix", action: #selector(toggleVisualFix(_:)), key: "v", feature: .visualFix),
            Extra(title: "Background Processes", action: #selector(showHousekeeping(_:)), key: "k", feature: .background),
            Extra(title: "Project Memory", action: #selector(showMemory(_:)), key: "y", feature: .memory),
            Extra(title: "Skills", action: #selector(showSkills(_:)), key: "u", feature: .skills),
            Extra(title: "Environment", action: #selector(showEnvironment(_:)), key: "n", feature: .environment),
            Extra(title: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), key: "/", feature: nil),
        ]
        for (offset, extra) in extras.enumerated() {
            let item = NSMenuItem(title: extra.title, action: extra.action, keyEquivalent: extra.key)
            item.keyEquivalentModifierMask = [.control, .command]
            item.target = self
            viewMenu.insertItem(item, at: 5 + offset)
            if let feature = extra.feature { featureItems.append((item, feature)) }
        }
        viewMenu.insertItem(.separator(), at: 5 + extras.count)
        if let editor = viewMenu.items.first(where: { $0.keyEquivalent == "e" && $0.keyEquivalentModifierMask == [.control, .command] }) {
            featureItems.append((editor, .editor))
        }
        installAppMenuItems(in: mainMenu)
        updateFeatureItems()
        NotificationCenter.default.addObserver(self, selector: #selector(featuresChanged(_:)),
                                               name: ExtremeSettings.featuresDidChange, object: nil)
        ShortcutSheet.shared.install()
    }

    /// "Settings…" (⌘,), "Check Setup…" and "Welcome…" where Ghostty's Preferences item was;
    /// that one (it opens Ghostty's config file) follows as "Edit Config File…".
    private func installAppMenuItems(in mainMenu: NSMenu) {
        guard let appMenu = mainMenu.items.first?.submenu else { return }
        let configIndex = appMenu.items.firstIndex { $0.action == #selector(AppDelegate.openConfig(_:)) }
        let anchor = configIndex ?? 1
        if let configIndex { appMenu.items[configIndex].title = "Edit Config File…" }
        let items = [
            ClosureMenuItem("Settings…", image: nil) { ExtremeSettingsWindow.show() },
            ClosureMenuItem("Check Setup…", image: nil) { SetupCheckWindow.show() },
            ClosureMenuItem("Welcome to Tellurion…", image: nil) { WelcomeWindow.show() },
        ]
        items[0].image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        // The old shortcut keeps working.
        let legacy = ClosureMenuItem("Settings…", image: nil) { ExtremeSettingsWindow.show() }
        legacy.keyEquivalent = ","
        legacy.keyEquivalentModifierMask = [.control, .command]
        legacy.isHidden = true
        legacy.allowsKeyEquivalentWhenHidden = true
        for (offset, item) in (items + [legacy]).enumerated() { appMenu.insertItem(item, at: anchor + offset) }
        // Takes Ghostty's `open_config` shortcut (⌘, unless the config changes it).
        (NSApp.delegate as? AppDelegate)?.adoptSettingsMenuItem(items[0])
    }

    @objc private func featuresChanged(_ notification: Notification) {
        updateFeatureItems()
    }

    /// Hidden items don't answer their key equivalents, so this turns the shortcuts off too.
    private func updateFeatureItems() {
        for (item, feature) in featureItems { item.isHidden = !ExtremeSettings.isOn(feature) }
    }

    @objc func showShortcuts(_ sender: Any?) {
        ShortcutSheet.shared.toggleSticky()
    }

    @objc func showMemory(_ sender: Any?) {
        MemoryWindow.showForFrontTab()
    }

    @objc func showSkills(_ sender: Any?) {
        SkillsWindow.showForFrontTab()
    }

    @objc func showEnvironment(_ sender: Any?) {
        EnvironmentWindow.showForFrontTab()
    }

    @objc func showLocalhost(_ sender: Any?) {
        LocalhostManager.toggle()
    }

    @objc func showReview(_ sender: Any?) {
        ReviewInbox.toggle()
    }

    @objc func toggleCommandBlocks(_ sender: Any?) {
        guard let owner = EditorPanel.frontController else { return }
        CommandBlocksPanel.shared.toggle(owner)
    }

    @objc func toggleVisualFix(_ sender: Any?) {
        VisualFixPanel.shared.toggle(nil)
    }

    @objc func showActivity(_ sender: Any?) {
        ActivityDashboard.toggle()
    }

    @objc func showHousekeeping(_ sender: Any?) {
        HousekeepingWindow.toggle()
    }

    @objc func showMissionControl(_ sender: Any?) {
        MissionControl.toggle()
    }

    @objc func raceAgents(_ sender: Any?) {
        guard let owner = EditorPanel.frontController ?? TerminalWindows.all.first else { return }
        AgentRaces.showSetup(from: owner)
    }

    @objc func toggle(_ sender: Any?) {
        // On a board, ⌃⌘S shows or hides the board's list.
        if let board = NSApp.keyWindow?.windowController as? BoardController {
            board.model.showSidebar.toggle()
            return
        }
        let defaults = UserDefaults.standard
        let show = !defaults.verticalTabsVisible
        let delta = show ? VerticalTabs.occupiedWidth : -VerticalTabs.occupiedWidth

        // One resize per window or tab group (tabs in a group share a frame).
        var seenGroups: Set<ObjectIdentifier> = []
        for window in NSApp.windows where window.windowController is TerminalController && window.isVisible {
            if let group = window.tabGroup {
                guard seenGroups.insert(ObjectIdentifier(group)).inserted else { continue }
            }
            VerticalTabs.resize(window, by: delta)
        }

        defaults.set(show, forKey: VerticalTabs.visibleKey)
    }
}

extension VerticalTabsMenu: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showMissionControl(_:)) {
            menuItem.state = AgentToolWindows.isOpen(MissionControl.windowID) ? .on : .off
            return true
        }
        if menuItem.action == #selector(showShortcuts(_:)) {
            menuItem.state = ShortcutSheet.shared.isVisible ? .on : .off
            return true
        }
        if menuItem.action == #selector(raceAgents(_:)) { return !TerminalWindows.all.isEmpty }
        if menuItem.action == #selector(showLocalhost(_:)) || menuItem.action == #selector(showReview(_:))
            || menuItem.action == #selector(showActivity(_:)) { return true }
        if menuItem.action == #selector(toggleVisualFix(_:)) {
            menuItem.state = EditorPanel.frontController.map { VisualFixPanel.shared.isVisible($0) } == true ? .on : .off
            return VisualFixPanel.frontController != nil
        }
        if menuItem.action == #selector(toggleCommandBlocks(_:)) {
            menuItem.state = EditorPanel.frontController.map { CommandBlocksPanel.shared.isVisible($0) } == true ? .on : .off
            return EditorPanel.frontController != nil
        }
        if let board = NSApp.keyWindow?.windowController as? BoardController {
            menuItem.state = board.model.showSidebar ? .on : .off
            return true
        }
        menuItem.state = UserDefaults.standard.verticalTabsVisible ? .on : .off
        return true
    }
}
#endif
