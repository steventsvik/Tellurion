#if os(macOS)
import AppKit

/// Tellurion's setup work at launch, run once when the first window appears.
enum ExtremeLaunch {
    private static var started = false
    private static var observer: NSObjectProtocol?

    static func start() {
        guard !started else { return }
        started = true
        // The hooks read feature switches from files.
        ExtremeSettings.writeFlags()
        SetupChecks.writeSkipFlags()
        DispatchQueue.global(qos: .utility).async {
            // A rebuilt app brings already-installed hooks up to date.
            HookInstaller.refreshIfInstalled()
            DispatchQueue.main.async {
                // First launch: the welcome window, if agent status isn't set up. Otherwise
                // this is just the first setup check, which feeds the sidebar's warning chip.
                if UserDefaults.standard.bool(forKey: WelcomeWindow.doneKey) {
                    SetupChecks.shared.refresh()
                } else {
                    WelcomeWindow.showIfNeeded()
                }
            }
        }
        // Coming back to the app: check again if it's been a while (setup can change outside).
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            SetupChecks.shared.refreshIfStale(600)
        }
    }
}
#endif
