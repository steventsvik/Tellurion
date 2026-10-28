#if os(macOS)
import Foundation
import Security

/// A secret that proves an escape-sequence event came from this app's own hooks.
///
/// Agent and localhost events arrive as OSC 777 notifications, which any text printed in a
/// terminal can contain: a README, a web response, a file an agent reads. Without proof,
/// such text could fake agent statuses and "needs permission" alerts, or stop and restart
/// localhost servers. Each launch makes a new random token and hands it to this app's
/// terminals only (as `GHOSTTY_EXTREME_EVENT_TOKEN`); the hooks run inside them, include it
/// in every event, and events without it are ignored. Printed text can't know it.
enum EventToken {
    static let environmentKey = "GHOSTTY_EXTREME_EVENT_TOKEN"

    static let value: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    /// Puts the token in this process's environment, so every terminal it opens inherits it.
    static func install() {
        setenv(environmentKey, value, 1)
    }

    /// `environment` without the token, for programs the app starts by itself (git, gh,
    /// providers' CLIs): only terminals and the hooks in them need it.
    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: environmentKey)
        return environment
    }

    /// Whether an event's JSON body carries this launch's token (`"t"`).
    static func verify(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["t"] as? String, token.utf8.count == value.utf8.count else { return false }
        // Constant-time comparison.
        return zip(token.utf8, value.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
#endif
