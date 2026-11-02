import AppKit

class DockTilePlugin: NSObject, NSDockTilePlugIn {
    // WARNING: An instance of this class is alive as long as Ghostty's icon is
    // in the doc (running or not!), so keep any state and processing to a
    // minimum to respect resource usage.

    private let pluginBundle = Bundle(for: DockTilePlugin.self)

    // Separate defaults based on debug vs release builds so we can test icons
    // without messing up releases.
    #if DEBUG
    private let ghosttyUserDefaults = UserDefaults(suiteName: "com.mitchellh.ghostty.debug")
    #else
    // Tellurion: read the defaults of the app this plugin belongs to, so a
    // renamed build (different bundle ID) doesn't pick up official Ghostty's icon.
    private lazy var ghosttyUserDefaults = UserDefaults(
        suiteName: ghosttyAppURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "com.mitchellh.ghostty")
    #endif

    private var iconChangeObserver: Any?

    /// The URL to the enclosing app bundle, determined from the plugin bundle path.
    var ghosttyAppURL: URL? {
        Self.appBundleURL(for: pluginBundle.bundleURL)
    }

    /// Determine the enclosing app bundle for the dock tile plugin bundle.
    ///
    /// We intentionally avoid matching a specific bundle name (such as
    /// "Ghostty.app") so renaming the app in Finder still works.
    static func appBundleURL(for pluginBundleURL: URL) -> URL? {
        var url = pluginBundleURL
        while true {
            if url.pathExtension.compare("app", options: .caseInsensitive) == .orderedSame {
                return url
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                // Safety stop: this should only happen at filesystem root.
                return nil
            }

            url = parent
        }
    }

    /// The icon file the app bundle declares (CFBundleIconFile), loaded from disk.
    static func bundleIconImage(for appURL: URL) -> NSImage? {
        guard let bundle = Bundle(url: appURL),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return nil }
        let file = name.hasSuffix(".icns") ? name : name + ".icns"
        return NSImage(contentsOf: appURL.appendingPathComponent("Contents/Resources/\(file)"))
    }

    /// The primary NSDockTilePlugin function.
    func setDockTile(_ dockTile: NSDockTile?) {
        // If no dock tile or no access to Ghostty defaults, we can't do anything.
        guard let dockTile, let ghosttyUserDefaults else {
            iconChangeObserver = nil
            return
        }

        // Try to restore the previous icon on launch.
        iconDidChange(ghosttyUserDefaults.appIcon, dockTile: dockTile)

        // Setup a new observer for when the icon changes so we can update. This message
        // is sent by the primary Ghostty app.
        iconChangeObserver = DistributedNotificationCenter
            .default()
            .publisher(for: .ghosttyIconDidChange)
            .map { [weak self] _ in self?.ghosttyUserDefaults?.appIcon }
            .receive(on: DispatchQueue.global())
            .sink { [weak self] newIcon in self?.iconDidChange(newIcon, dockTile: dockTile) }
    }

    private func iconDidChange(_ newIcon: AppIcon?, dockTile: NSDockTile) {
        guard let appIcon = newIcon?.image(in: pluginBundle) else {
            resetIcon(dockTile: dockTile)
            return
        }

        dockTile.setIcon(appIcon)
    }

    /// Reset the application icon and dock tile icon to the default.
    private func resetIcon(dockTile: NSDockTile) {
        let appIcon: NSImage?
        if #available(macOS 26.0, *) {
            #if DEBUG
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
            #else
            // Tellurion: use the bundle's own icon file directly. Asking
            // NSWorkspace for the composed icon can return a stale cached copy (the
            // stock blue icon) after the app is reinstalled.
            if let bundleIcon = ghosttyAppURL.flatMap(Self.bundleIconImage(for:)) {
                appIcon = bundleIcon
            } else {
                // If the bundle has no icon file, fall back to a bundled icon.
                appIcon = pluginBundle.image(forResource: "AppIconImage")!
            }
            #endif
        } else {
            // Use the bundled icon to keep the corner radius consistent with pre-Tahoe apps.
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
        }
        dockTile.setIcon(appIcon)
    }
}

private extension NSDockTile {
    func setIcon(_ newIcon: NSImage?) {
        // Update the Dock tile on the main thread.
        DispatchQueue.main.async {
            guard let newIcon else {
                self.contentView = nil
                self.display()
                return
            }
            let iconView = NSImageView(frame: CGRect(origin: .zero, size: self.size))
            iconView.wantsLayer = true
            iconView.image = newIcon
            self.contentView = iconView
            self.display()
        }
    }
}

// This is required because of the DispatchQueue call above. This doesn't
// feel right but I don't know a better way to solve this.
extension NSDockTile: @unchecked @retroactive Sendable {}
