import Foundation
import Testing
@testable import Ghostty

/// Saving the paired phones (PhoneDevices.write): private to the user, and a failure is
/// reported, since a phone that was removed must not come back.
struct PhoneDevicesTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phones-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let phone = PhoneDevice(id: "one", name: "Phone", tokenHash: String(repeating: "a", count: 64),
                                    paired: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: nil, login: "someone@example.com")

    @Test func theListIsWrittenReadableOnlyByTheUser() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("support/phone-devices.json")
        #expect(PhoneDevices.write([phone], to: file))
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([PhoneDevice].self, from: Data(contentsOf: file)) == [phone])
        // Removing the last phone writes an empty list, not nothing.
        #expect(PhoneDevices.write([], to: file))
        #expect(try decoder.decode([PhoneDevice].self, from: Data(contentsOf: file)).isEmpty)
    }

    @Test func aWriteThatFailsSaysSo() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        #expect(!PhoneDevices.write([phone], to: blocker.appendingPathComponent("phone-devices.json")))
    }
}
