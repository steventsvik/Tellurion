#if os(macOS)
import AppKit
import SwiftUI

/// Hold ⌃⌘ for a moment and every ⌃⌘ shortcut appears over the window; let go and it's
/// gone. ⌃⌘/ shows it until Escape or a click.
///
/// The list is read from the menus each time it opens, so it always matches what's there:
/// a feature turned off in Settings has no menu item, so it isn't listed either. It only
/// watches modifier-key changes, which costs nothing while you type.
final class ShortcutSheet {
    static let shared = ShortcutSheet()

    private var monitor: Any?
    private var pending: DispatchWorkItem?
    private var panel: NSPanel?
    private var sticky = false
    private static let holdDelay: TimeInterval = 0.6

    var isVisible: Bool { panel?.isVisible == true }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if modifiers == [.control, .command] {
                guard !isVisible, pending == nil else { return event }
                let work = DispatchWorkItem { [weak self] in
                    self?.pending = nil
                    self?.show(sticky: false)
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
            } else {
                cancelPending()
                if isVisible && !sticky { hide() }
            }
        case .keyDown:
            // A shortcut is being pressed, not looked up.
            cancelPending()
            if isVisible {
                if sticky && event.keyCode == 53 {  // Escape
                    hide()
                    return nil
                }
                if !sticky { hide() }
            }
        case .leftMouseDown:
            cancelPending()
            if isVisible && event.window !== panel { hide() }
        default:
            break
        }
        return event
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func toggleSticky() {
        if isVisible { hide() } else { show(sticky: true) }
    }

    func show(sticky: Bool) {
        self.sticky = sticky
        let view = DesignRoot { ShortcutSheetView(groups: Self.collect(), sticky: sticky) }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        let anchor = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: anchor.midX - size.width / 2, y: anchor.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        // Drop the view; the panel itself is reused.
        panel?.contentView = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
        return panel
    }

    // MARK: Reading the menus

    struct Shortcut: Hashable {
        let keys: String
        let title: String
    }

    struct Group: Identifiable {
        let id: String
        let shortcuts: [Shortcut]
    }

    /// Ghostty's own shortcuts worth knowing, looked up in the menus by title so they show
    /// whatever key the user bound.
    private static let essentials = [
        "New Window", "New Tab", "Split Right", "Split Down", "Close", "Go to Tab or Command…",
        "Command Palette", "Find…", "Toggle Full Screen", "Enter Full Screen", "Reload Configuration",
    ]

    static func collect() -> [Group] {
        var extreme: [Shortcut] = []
        var splits: [Shortcut] = []
        var ghostty: [String: Shortcut] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard !item.isHidden, !item.isSeparatorItem, !item.keyEquivalent.isEmpty else { continue }
                let mask = item.keyEquivalentModifierMask
                let shortcut = Shortcut(keys: keys(item), title: item.title)
                if mask.contains(.control) && mask.contains(.command) {
                    // Ghostty's own ⌃⌘ shortcuts are for splits.
                    if item.title.hasPrefix("Move Divider") || item.title.hasPrefix("Equalize") {
                        if !splits.contains(shortcut) { splits.append(shortcut) }
                    } else if !extreme.contains(shortcut) {
                        extreme.append(shortcut)
                    }
                } else if essentials.contains(item.title), ghostty[item.title] == nil {
                    ghostty[item.title] = shortcut
                }
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
        let ordered = essentials.compactMap { ghostty[$0] }
        return [
            Group(id: "Tellurion", shortcuts: extreme.sorted { $0.title < $1.title }),
            Group(id: "Terminal", shortcuts: ordered),
            Group(id: "Splits", shortcuts: splits.sorted { $0.title < $1.title }),
        ].filter { !$0.shortcuts.isEmpty }
    }

    private static func keys(_ item: NSMenuItem) -> String {
        let mask = item.keyEquivalentModifierMask
        var result = ""
        if mask.contains(.control) { result += "⌃" }
        if mask.contains(.option) { result += "⌥" }
        // An uppercase key equivalent implies Shift.
        let key = item.keyEquivalent
        if mask.contains(.shift) || (key.count == 1 && key != key.lowercased()) { result += "⇧" }
        if mask.contains(.command) { result += "⌘" }
        if mask.contains(.function) { result = "fn " + result }
        switch key {
        case "\r": result += "↩"
        case "\u{1b}": result += "⎋"
        case "\t": result += "⇥"
        case " ": result += "Space"
        case "\u{7f}", "\u{8}": result += "⌫"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): result += "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): result += "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): result += "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): result += "→"
        default: result += key.uppercased()
        }
        return result
    }
}

private struct ShortcutSheetView: View {
    let groups: [ShortcutSheet.Group]
    let sticky: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    TellurionSectionLabel(group.id)
                    LazyVGrid(columns: [GridItem(.fixed(250), alignment: .leading), GridItem(.fixed(250), alignment: .leading)],
                              alignment: .leading, spacing: 7) {
                        ForEach(group.shortcuts, id: \.self) { shortcut in
                            HStack(spacing: 10) {
                                Text(shortcut.keys)
                                    .font(Tellurion.font(12, weight: .semibold))
                                    .foregroundColor(Tellurion.gold)
                                    .frame(width: 58, alignment: .trailing)
                                Text(shortcut.title)
                                    .font(Tellurion.font(12, weight: .regular))
                                    .foregroundColor(Tellurion.text)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            Text(sticky ? "Escape or click to close" : "Let go of ⌃⌘ to close · ⌃⌘/ keeps it open")
                .font(Tellurion.font(10.5, weight: .regular))
                .foregroundColor(Tellurion.dim)
        }
        .padding(20)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tellurion.ink.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tellurion.lineStrong, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .onAppear { Tellurion.registerFonts() }
    }
}
#endif
