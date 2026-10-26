import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Tellurion: its own feed, published with every release and signed with its own
        // key (SUPublicEDKey). Ghostty's feeds would offer official Ghostty, which would replace
        // this app. There's one channel; the `auto-update-channel` setting doesn't apply.
        // Test-only: `GHOSTTY_EXTREME_TEST_FEED=<url>` points a test copy at a local feed.
        TestHooks.updateFeed
            ?? "https://github.com/steventsvik/Tellurion/releases/latest/download/appcast.xml"
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        RenameAfterRebrand.updatePending = true
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }

    /// Local builds (version 0.1, not stamped by release.sh) would always see the latest
    /// release as an update, so they only check when asked to.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let isRelease = Bundle.main.infoDictionary?["GhosttyExtremeRelease"] as? Bool == true
        if !isRelease && updateCheck == .updatesInBackground {
            throw NSError(domain: "Tellurion", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Local builds don't check for updates by themselves."])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Tellurion: the installer writes to this app's path, so don't rename it on quit.
        RenameAfterRebrand.updatePending = true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        RenameAfterRebrand.updatePending = true
        // When the updater is relaunching the application we want to get macOS
        // to invalidate and re-encode all of our restorable state so that when
        // we relaunch it uses it.
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
        // Tellurion: keep the windows for this quit and remember what's running in them.
        ResumeAfterUpdate.prepare()
    }
}
