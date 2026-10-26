#if os(macOS)
import Foundation

/// The switches that drive test copies and recordings: the `GHOSTTY_EXTREME_TEST_*` and
/// `GHOSTTY_EXTREME_DEMO*` environment variables. Every reader goes through here, and all of
/// it except `home` exists only in builds made with `TELLURION_TEST_HOOKS` (Debug, and
/// ReleaseLocal as the Xcode project builds it). `release.sh` builds without that flag and
/// checks the app for leftovers, so a shipped app has none of these.
enum TestHooks {
    /// `GHOSTTY_EXTREME_TEST_HOME=<folder>`: where a test copy keeps `.ghostty-extreme`
    /// instead of the home folder, so it never touches the user's boards, hooks or designs.
    /// Honored in every build: release.sh's launch test relies on it, and a test copy made
    /// from a release build must stay apart too.
    static let home: String? = {
        guard let home = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_HOME"], !home.isEmpty else { return nil }
        return home
    }()

#if TELLURION_TEST_HOOKS
    /// Whether this build has the test hooks.
    static let available = true

    /// A launch driven by a test or a demo. Such launches stay quiet: no welcome window.
    static var isTestLaunch: Bool {
        home != nil || ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("GHOSTTY_EXTREME_TEST_") || $0 == "GHOSTTY_EXTREME_DEMO"
        }
    }

    /// The variable's value, if set and not empty.
    static func value(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// Whether the variable is set to `1`.
    static func flag(_ name: String) -> Bool { value(name) == "1" }

    /// `GHOSTTY_EXTREME_TEST_LOG=<file>`: where a test run collects what happened.
    static var log: String? { value("GHOSTTY_EXTREME_TEST_LOG") }
    /// `GHOSTTY_EXTREME_TEST_FEED=<url>`: points a test copy's updater at a local feed.
    static var updateFeed: String? { value("GHOSTTY_EXTREME_TEST_FEED") }
    /// `GHOSTTY_EXTREME_TEST_WELCOME=1`: shows the welcome window even if it was finished before.
    static var welcome: Bool { flag("GHOSTTY_EXTREME_TEST_WELCOME") }
    /// `GHOSTTY_EXTREME_TEST_TOOL=<title>`: chooses that tool once the Tools panel is open.
    static var tool: String? { value("GHOSTTY_EXTREME_TEST_TOOL") }
    /// `GHOSTTY_EXTREME_TEST_BACKGROUND_SAMPLE=1`: the Background window shows sample items.
    static var showsBackgroundSample: Bool { flag("GHOSTTY_EXTREME_TEST_BACKGROUND_SAMPLE") }
    /// `GHOSTTY_EXTREME_TEST_NOANIM=comet,spinner,bar,dot,film,bracket`: turns those motions
    /// off, to measure what each costs the window server.
    static let motionOff = Set((value("GHOSTTY_EXTREME_TEST_NOANIM") ?? "").split(separator: ",").map(String.init))

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
    static var welcome: Bool { false }
    static var tool: String? { nil }
    static var showsBackgroundSample: Bool { false }
    static let motionOff: Set<String> = []
    static func note(_ line: @autoclosure () -> String) {}
#endif
}
#endif
