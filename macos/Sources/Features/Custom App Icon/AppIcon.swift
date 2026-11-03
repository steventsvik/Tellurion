import AppKit
import System

/// The icon style for the app. Tellurion ships one icon: Ghostty's alternate icons and
/// its colorized ghost are Ghostty's artwork, so those settings fall back to it. A custom
/// icon file (`macos-icon = custom`) still works.
enum AppIcon: Equatable, Codable, Sendable {
    case official
    case blueprint
    case chalkboard
    case glass
    case holographic
    case microchip
    case paper
    case retro
    case xray
    /// Save full image data to avoid sandboxing issues
    case custom(_ iconFile: Data)
    case customStyle(_ icon: ColorizedGhosttyIcon)

#if !DOCK_TILE_PLUGIN
    init?(config: Ghostty.Config) {
        switch config.macosIcon {
        case .official, .blueprint, .chalkboard, .glass, .holographic, .microchip, .paper, .retro, .xray, .customStyle:
            return nil
        case .custom:
            if let data = try? Data(contentsOf: URL(filePath: config.macosCustomIcon, relativeTo: nil)) {
                self = .custom(data)
            } else {
                return nil
            }
        }
    }
#endif

    func image(in bundle: Bundle) -> NSImage? {
        switch self {
        case .official, .blueprint, .chalkboard, .glass, .holographic, .microchip, .paper, .retro, .xray, .customStyle:
            return nil
        case let .custom(file):
            return NSImage(data: file)
        }
    }
}

#if !DOCK_TILE_PLUGIN
/// Making sure that `NSWorkspace.shared.setIcon` executes on only one thread at a time
actor AppIconUpdater {
    func update(icon: AppIcon?) {
        UserDefaults.ghostty.appIcon = icon
        // Notify DockTilePlugin to update dock icon
        DistributedNotificationCenter.default()
            .postNotificationName(
                .ghosttyIconDidChange,
                object: nil,
                userInfo: nil,
                deliverImmediately: true,
            )

        NSWorkspace.shared.setIcon(
            icon?.image(in: .main),
            forFile: Bundle.main.bundlePath,
        )
        NSWorkspace.shared.noteFileSystemChanged(Bundle.main.bundlePath)
    }
}
#endif
