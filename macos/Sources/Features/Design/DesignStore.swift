#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// The design in use: loads and saves it, resolves the chrome's colors and the logo for
/// the views, writes the terminal's part into the Ghostty config, and tells the windows
/// to redraw. Every `Extreme` color reads from here.
final class DesignStore: ObservableObject {
    static let shared = DesignStore()

    /// Posted on the main thread after the design changes and the chrome is resolved.
    static let didChange = Notification.Name("com.steventsvik.ghostty-extreme.designDidChange")

    @Published private(set) var design: TellurionDesign
    /// Bumped on every change; views keyed on it rebuild with the new colors.
    @Published private(set) var revision = 0
    /// The user's own saved designs.
    @Published private(set) var mine: [TellurionDesign] = []

    /// The chrome's colors, resolved. Read by `Extreme` on every draw, so it's a plain value.
    private(set) var chrome = ChromeColors.tellurion
    private(set) var chromeColors = ResolvedChrome(ChromeColors.tellurion)
    private(set) var logoRows = DesignLogo.tellurion.rows
    private(set) var logoColors: [Character: Color] = DesignLogo.tellurion.colors(in: .tellurion)

    /// The terminal's colors as the design resolves them (what the preview shows).
    private(set) var terminalColors = TerminalColors.tellurion

    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// Whether the Dock shows the design's logo right now.
    private var dockIconShown = false

    /// Where `design.json` and `designs/` live. Test-only: `GHOSTTY_EXTREME_TEST_HOME`
    /// moves them, so a test copy never changes the maintainer's design.
    static var folder: URL {
        if let home = TestHooks.home {
            return URL(fileURLWithPath: home).appendingPathComponent(".ghostty-extreme", isDirectory: true)
        }
        return AgentTools.root
    }
    static var file: URL { folder.appendingPathComponent("design.json") }
    static var mineFolder: URL { folder.appendingPathComponent("designs", isDirectory: true) }

    private init() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.file), let saved = try? decoder.decode(TellurionDesign.self, from: data) {
            design = saved
        } else {
            design = .standard
        }
        mine = Self.loadMine()
        resolve(reload: false, notify: false)
        // Not from init: the views and `Extreme` read `shared`, which is still being made.
        DispatchQueue.main.async { [weak self] in self?.applyDockIcon() }
        observers.append(NotificationCenter.default.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // The config can change under a design that follows it (new colors, or the
            // app icon reset by Ghostty's own handling).
            if case .mine = self.design.terminal { self.resolve(reload: false) }
            if self.design.logo.dockIcon { DispatchQueue.main.async { self.dockIconShown = false; self.applyDockIcon() } }
        })
    }

    // MARK: Applying

    /// Makes `design` the one in use: saves it, writes the terminal's part to the Ghostty
    /// config and reloads it, and redraws the chrome.
    func apply(_ next: TellurionDesign) {
        pending?.cancel()
        pending = nil
        design = next
        save()
        resolve(reload: true)
    }

    /// Like `apply`, a moment after the last call: for sliders and color pickers.
    func preview(_ next: TellurionDesign) {
        guard next != design || pending != nil else { return }
        design = next
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.save()
            self.resolve(reload: true)
        }
        pending?.cancel()
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Back to Tellurion as shipped.
    func reset() { apply(.standard) }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(design) { try? data.write(to: Self.file, options: .atomic) }
    }

    /// Resolves the terminal colors, the chrome and the logo from `design`; writes the
    /// Ghostty fragment and reloads when `reload`; tells the views when something they
    /// draw changed.
    private func resolve(reload: Bool, notify: Bool = true) {
        let before = (chrome, logoRows)
        let live = (NSApp.delegate as? AppDelegate).flatMap { TerminalColors(config: $0.ghostty.config) }
        switch design.terminal {
        case .mine: terminalColors = live ?? .tellurion
        case .theme(let name): terminalColors = GhosttyThemes.colors(named: name) ?? live ?? .tellurion
        case .custom(let colors): terminalColors = colors
        }
        switch design.chrome {
        case .fixed(let colors): chrome = colors
        case .auto(let accent, let ai): chrome = .derived(from: terminalColors, accent: accent, ai: ai)
        }
        chromeColors = ResolvedChrome(chrome)
        logoRows = design.logo.rows
        logoColors = design.logo.colors(in: chrome)
        if reload {
            GhosttyDesignConfig.write(design)
            (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
        }
        guard notify else { return }
        applyDockIcon()
        guard before.0 != chrome || before.1 != logoRows else { return }
        revision += 1
        AgentToolWindows.designDidChange()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: My designs

    func saveToMine(_ draft: TellurionDesign) {
        var saved = draft
        saved.builtIn = false
        if saved.name.trimmingCharacters(in: .whitespaces).isEmpty { saved.name = "My design" }
        if saved.id.isEmpty || DesignTemplates.all.contains(where: { $0.id == saved.id }) { saved.id = "mine-" + UUID().uuidString.lowercased() }
        try? FileManager.default.createDirectory(at: Self.mineFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(saved) {
            try? data.write(to: Self.mineFolder.appendingPathComponent(saved.id + ".json"), options: .atomic)
        }
        mine = Self.loadMine()
        apply(saved)
    }

    func deleteFromMine(_ id: String) {
        try? FileManager.default.removeItem(at: Self.mineFolder.appendingPathComponent(id + ".json"))
        mine = Self.loadMine()
    }

    private static func loadMine() -> [TellurionDesign] {
        let decoder = JSONDecoder()
        let urls = (try? FileManager.default.contentsOfDirectory(at: mineFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(TellurionDesign.self, from: $0) } }
    }

    // MARK: Dock icon

    /// Draws the logo on an ink tile as the running app's icon, or restores the bundle's icon.
    private func applyDockIcon() {
        if design.logo.dockIcon, !design.logo.isEmpty {
            NSApp.applicationIconImage = Self.dockIcon(logo: design.logo, chrome: chrome)
            dockIconShown = true
        } else if dockIconShown {
            // Back to the bundle's icon (a `macos-icon = custom` icon comes back on the next config reload).
            dockIconShown = false
            if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
               let icon = Bundle.main.image(forResource: (name as NSString).deletingPathExtension) {
                NSApp.applicationIconImage = icon
            }
        }
    }

    static func dockIcon(logo: DesignLogo, chrome: ChromeColors, size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            // macOS's icon grid: the tile is about 80% of the canvas, with continuous corners.
            let tile = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
            chrome.ink.nsColor.setFill()
            path.fill()
            chrome.line.nsColor.setStroke()
            path.lineWidth = size * 0.006
            path.stroke()
            let pixel = (tile.width * 0.78 / CGFloat(DesignLogo.size)).rounded(.down)
            let origin = NSPoint(x: tile.midX - pixel * CGFloat(DesignLogo.size) / 2, y: tile.midY - pixel * CGFloat(DesignLogo.size) / 2)
            for (y, row) in logo.rows.enumerated() {
                for (x, char) in row.enumerated() {
                    guard let role = DesignLogo.Role(rawValue: char) else { continue }
                    role.color(in: chrome).nsColor.setFill()
                    NSRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel, width: pixel, height: pixel).fill()
                }
            }
            return true
        }
    }
}

/// The chrome's colors as SwiftUI colors, made once per change rather than on every draw.
struct ResolvedChrome {
    let ink, panel, raised, line, lineStrong, bronze, gold, core, text, muted, dim, live, warn, danger: Color

    init(_ c: ChromeColors) {
        ink = c.ink.color
        panel = c.panel.color
        raised = c.raised.color
        line = c.line.color
        lineStrong = c.lineStrong.color
        bronze = c.bronze.color
        gold = c.gold.color
        core = c.core.color
        text = c.text.color
        muted = c.muted.color
        dim = c.dim.color
        live = c.live.color
        warn = c.warn.color
        danger = c.danger.color
    }
}

/// Rebuilds its content whenever the design changes, so every `Extreme` color inside is
/// read again. Put it at the root of a window or a chrome subtree, never around a terminal.
struct DesignRoot<Content: View>: View {
    @ObservedObject private var store = DesignStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id(store.revision)
    }
}

/// The tool-window styling (`extremeWindow()`) re-applied on every design change without
/// rebuilding the content: for views that keep state while the design changes under them.
struct DesignSkin<Content: View>: View {
    @ObservedObject private var store = DesignStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(store.chromeColors.ink)
            .buttonStyle(ExtremeButtonStyle())
            .tint(store.chromeColors.gold)
            .environment(\.colorScheme, store.chrome.isLight ? .light : .dark)
            .onAppear { Extreme.registerFonts() }
    }
}

// MARK: - The Ghostty config

/// The terminal's part of a design lives in `tellurion-design.ghostty` next to the Ghostty
/// config, which includes it with a `config-file` line. Because includes are read after the
/// whole config, the design's colors win over the config's own.
enum GhosttyDesignConfig {
    static let fragmentName = "tellurion-design.ghostty"
    static let includeLine = "config-file = ?\(fragmentName)"
    static let marker = "# Tellurion's Design window writes the file below; keep this line to use it."

    /// The config file Ghostty reads: the default files in Ghostty's order of
    /// preference (created if there is none); in debug builds `GHOSTTY_CONFIG_PATH`,
    /// which is the only build where the app itself honors it.
    static var configFile: URL {
#if DEBUG
        if let path = ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
#endif
        // Ghostty finds the XDG file from `$HOME` and the Application Support one from
        // the account's home, so this does the same.
        let env = ProcessInfo.processInfo.environment
        let home = URL(fileURLWithPath: env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory())
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        let appSupport = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
        let candidates = [
            xdg.appendingPathComponent("ghostty/config.ghostty"),
            xdg.appendingPathComponent("ghostty/config"),
            appSupport.appendingPathComponent("config.ghostty"),
            appSupport.appendingPathComponent("config"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[2]
    }

    static var fragmentFile: URL { configFile.deletingLastPathComponent().appendingPathComponent(fragmentName) }

    /// What the fragment says for `design`.
    static func fragment(for design: TellurionDesign) -> String {
        var lines = [
            "# Written by Tellurion (Tools → Design). Edit the design there; changes here are overwritten.",
            "# Remove the `config-file` line from your config to stop using it.",
            "",
        ]
        switch design.terminal {
        case .mine:
            lines.append("# Terminal colors: yours, from the config.")
        case .theme(let name):
            lines.append("# Terminal colors: the \(name) theme.")
            if let colors = GhosttyThemes.colors(named: name) {
                lines += colors.configLines
                lines.append("window-theme = \(colors.background.isLight ? "light" : "dark")")
            } else {
                lines.append("theme = \(name)")
            }
        case .custom(let colors):
            lines.append("# Terminal colors: custom.")
            lines += colors.configLines
            lines.append("window-theme = \(colors.background.isLight ? "light" : "dark")")
        }
        let font = design.font.configLines
        if !font.isEmpty {
            lines.append("")
            lines += font
        }
        if let window = design.window {
            lines.append("")
            lines += window.configLines
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the fragment and makes sure the config includes it.
    static func write(_ design: TellurionDesign) {
        let config = configFile
        let folder = config.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fragment(for: design).write(to: fragmentFile, atomically: true, encoding: .utf8)
            let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            let included = existing.split(whereSeparator: \.isNewline).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("config-file"), let eq = trimmed.firstIndex(of: "=") else { return false }
                var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("?") { value.removeFirst() }
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == fragmentName
            }
            if !included {
                var text = existing
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                if !text.isEmpty { text += "\n" }
                text += marker + "\n" + includeLine + "\n"
                try text.write(to: config, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Tellurion design: could not write the Ghostty config fragment: \(error)")
        }
    }
}
#endif
