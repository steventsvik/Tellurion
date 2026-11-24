#if os(macOS)
import CryptoKit
import Foundation
import os
import Security

/// A phone allowed to use this Mac's terminal.
struct PhoneDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// SHA-256 of its token, hex. The token itself is only ever on the phone.
    let tokenHash: String
    let paired: Date
    var lastSeen: Date?
    /// The Tailscale account it paired from.
    var login: String?
    /// "glasses" for Even G2 glasses; nothing for a phone (and in lists saved before there were glasses).
    var kind: String?

    static let glassesKind = "glasses"
    var isGlasses: Bool { kind == Self.glassesKind }
}

/// Paired phones and the one-time code that pairs a new one. Saved (tokens hashed) in
/// ~/Library/Application Support/GhosttyEXTREME/phone-devices.json, readable only by the user.
final class PhoneDevices: ObservableObject {
    static let shared = PhoneDevices()

    @Published private(set) var devices: [PhoneDevice] = []
    /// The code the pairing QR carries, while one is showing.
    @Published private(set) var pairingCode: String?
    private var pairingExpires = Date.distantPast
    private var failedAttempts = 0

    static let pairingLifetime: TimeInterval = 10 * 60

    private static let log = StoredFile.logger("Phone")

    /// The list's file. Dev-mode test copies keep their own list, and `TELLURION_TEST_HOME`
    /// moves the folder.
    private static var file: URL {
        AgentTools.supportFolder.appendingPathComponent(PhoneServer.devMode ? "phone-devices-dev.json" : "phone-devices.json")
    }

    private init() {
        // A list that can't be read is moved aside rather than replaced by the next save.
        devices = StoredFile.loadList(PhoneDevice.self, from: Self.file, what: "the paired phones", log: Self.log,
                                      decoder: Self.decoder).value ?? []
    }

    // MARK: Pairing

    /// A fresh one-time code, valid for 10 minutes or one pairing. Short enough to type
    /// ("K7QM-2XRD") for the Home Screen app, which can't scan the QR: 40 bits, and five
    /// wrong tries withdraw it.
    @discardableResult
    func newPairingCode() -> String {
        let code = Self.shortCode()
        pairingCode = code
        pairingExpires = Date().addingTimeInterval(Self.pairingLifetime)
        failedAttempts = 0
        return code
    }

    /// Dev-mode tests only (see PhoneServer.startIfEnabled).
    func useTestPairingCode(_ code: String) {
        guard PhoneServer.devMode else { return }
        pairingCode = code
        pairingExpires = Date().addingTimeInterval(Self.pairingLifetime)
        failedAttempts = 0
    }

    func cancelPairing() {
        pairingCode = nil
    }

    enum PairResult {
        case paired(token: String, device: PhoneDevice)
        case invalid
        /// Too many wrong codes; the code was withdrawn.
        case locked
    }

    /// Trades a valid code for a new device token.
    func pair(code: String, name: String, login: String?, kind: String? = nil) -> PairResult {
        guard let current = pairingCode, Date() < pairingExpires else { return .invalid }
        guard Self.equal(Self.normalized(code), Self.normalized(current)) else {
            failedAttempts += 1
            if failedAttempts >= 5 {
                pairingCode = nil
                return .locked
            }
            return .invalid
        }
        pairingCode = nil
        let (token, device) = add(name: name, login: login, kind: kind)
        return .paired(token: token, device: device)
    }

    /// A new device and its token, once it has shown it may pair: with a code, or approved
    /// on the Mac (see `GlassesPairing`).
    func add(name: String, login: String?, kind: String? = nil) -> (token: String, device: PhoneDevice) {
        let token = Self.random(bytes: 32)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == PhoneDevice.glassesKind ? "Glasses" : "Phone"
        let device = PhoneDevice(id: UUID().uuidString, name: trimmed.isEmpty ? fallback : String(trimmed.prefix(40)),
                                 tokenHash: Self.hash(token), paired: Date(), lastSeen: Date(), login: login, kind: kind)
        devices.append(device)
        save()
        return (token, device)
    }

    // MARK: Devices

    /// The device a token belongs to.
    func device(for token: String) -> PhoneDevice? {
        let hash = Self.hash(token)
        return devices.first { Self.equal($0.tokenHash, hash) }
    }

    func touch(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        // Saved at most once a minute.
        let previous = devices[index].lastSeen ?? .distantPast
        devices[index].lastSeen = Date()
        if Date().timeIntervalSince(previous) > 60 { save() }
    }

    /// Forgets a phone and disconnects it. False when the list couldn't be saved: the phone
    /// is gone until Tellurion quits, and would be paired again after that.
    @discardableResult
    func remove(_ id: String) -> Bool {
        devices.removeAll { $0.id == id }
        let saved = save()
        PhoneServer.shared.disconnect(device: id)
        return saved
    }

    /// `remove` for every phone.
    @discardableResult
    func removeAll() -> Bool {
        let ids = devices.map(\.id)
        devices = []
        let saved = save()
        for id in ids { PhoneServer.shared.disconnect(device: id) }
        return saved
    }

    @discardableResult
    private func save() -> Bool {
        Self.write(devices, to: Self.file)
    }

    /// Writes the list, readable only by the user. Returns whether it worked.
    static func write(_ devices: [PhoneDevice], to file: URL) -> Bool {
        guard StoredFile.write(json: devices, to: file, what: "the paired phones", log: log, encoder: encoder) else { return false }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            log.error("Couldn't make the paired phones' file private: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// URL-safe random text.
    static func random(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Letters and digits that can't be mistaken for each other (no I, L, O, U).
    private static let codeAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func shortCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { codeAlphabet[Int($0) & 31] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    /// A typed code as the Mac shows it: upper case, no spaces or dashes, look-alikes fixed.
    static func normalized(_ code: String) -> String {
        String(code.uppercased().compactMap { char -> Character? in
            switch char {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return char
            }
        })
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without returning early, so timing doesn't hint at how much matched.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}
#endif
