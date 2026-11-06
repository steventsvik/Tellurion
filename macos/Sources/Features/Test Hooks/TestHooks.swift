#if os(macOS)
import Foundation

/// The switches that drive test copies and recordings: the `TELLURION_TEST_*`,
/// `TELLURION_DEMO*` and `TELLURION_PHONE_*` environment variables. Every reader goes through here, and all of
/// it except `home` exists only in builds made with `TELLURION_TEST_HOOKS` (Debug, and
/// ReleaseLocal as the Xcode project builds it). `release.sh` builds without that flag and
/// checks the app for leftovers, so a shipped app has none of these.
enum TestHooks {
    /// `TELLURION_TEST_HOME=<folder>`: where a test copy keeps `.ghostty-extreme`
    /// instead of the home folder, so it never touches the user's boards, hooks or designs.
    /// Honored in every build: release.sh's launch test relies on it, and a test copy made
    /// from a release build must stay apart too.
    static let home: String? = {
        guard let home = ProcessInfo.processInfo.environment["TELLURION_TEST_HOME"], !home.isEmpty else { return nil }
        return home
    }()

#if TELLURION_TEST_HOOKS
    /// Whether this build has the test hooks.
    static let available = true

    /// A launch driven by a test or a demo. Such launches stay quiet: no welcome window.
    static var isTestLaunch: Bool {
        home != nil || ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("TELLURION_TEST_") || $0 == "TELLURION_DEMO"
        }
    }

    /// The variable's value, if set and not empty.
    static func value(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// Whether the variable is set to `1`.
    static func flag(_ name: String) -> Bool { value(name) == "1" }

    /// `TELLURION_TEST_LOG=<file>`: where a test run collects what happened.
    static var log: String? { value("TELLURION_TEST_LOG") }
    /// `TELLURION_TEST_FEED=<url>`: points a test copy's updater at a local feed.
    static var updateFeed: String? { value("TELLURION_TEST_FEED") }
    /// `TELLURION_TEST_VENICE=<url>`: points a test copy's Venice models at a local server.
    static var veniceServer: String? { value("TELLURION_TEST_VENICE") }
    /// `TELLURION_TEST_WELCOME=1`: shows the welcome window even if it was finished before.
    static var welcome: Bool { flag("TELLURION_TEST_WELCOME") }
    /// `TELLURION_TEST_TOOL=<title>`: chooses that tool once the Tools panel is open.
    static var tool: String? { value("TELLURION_TEST_TOOL") }
    /// `TELLURION_TEST_BACKGROUND_SAMPLE=1`: the Background window shows sample items.
    static var showsBackgroundSample: Bool { flag("TELLURION_TEST_BACKGROUND_SAMPLE") }
    /// `TELLURION_TEST_NOANIM=comet,spinner,bar,dot,film,bracket`: turns those motions
    /// off, to measure what each costs the window server.
    static let motionOff = Set((value("TELLURION_TEST_NOANIM") ?? "").split(separator: ",").map(String.init))

    /// `TELLURION_PHONE_DEV=1`: the phone server serves on this Mac only, without Tailscale,
    /// and lets in local requests that carry no login. Its paired phones are a separate list.
    static var phoneDev: Bool { flag("TELLURION_PHONE_DEV") }
    /// `TELLURION_PHONE_DEV_CODE=<code>`: in phone dev mode, the pairing code, so a test pairs
    /// without the window.
    static var phonePairingCode: String? { value("TELLURION_PHONE_DEV_CODE") }
    /// `TELLURION_PHONE_TEST=on|off`: presses Turn on or Turn off at launch (test bundle id only).
    static var phoneSwitch: String? { value("TELLURION_PHONE_TEST") }

    /// Appends a line to the test log, if there is one. The line is only built when it is.
    static func note(_ line: @autoclosure () -> String) {
        guard let path = log else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line() + "\n").utf8))
        handle.closeFile()
    }
#else
    static let available = false
    static var isTestLaunch: Bool { home != nil }
    static var log: String? { nil }
    static var updateFeed: String? { nil }
    static var veniceServer: String? { nil }
    static var welcome: Bool { false }
    static var tool: String? { nil }
    static var showsBackgroundSample: Bool { false }
    static let motionOff: Set<String> = []
    static var phoneDev: Bool { false }
    static var phonePairingCode: String? { nil }
    static var phoneSwitch: String? { nil }
    static func note(_ line: @autoclosure () -> String) {}
#endif
}
#endif
