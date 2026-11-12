import Foundation
import Testing
@testable import Ghostty

/// Pairing glasses by approving them on the Mac (GlassesPairRequests), and the kind kept
/// with a paired device.
struct GlassesPairingTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func opened() -> GlassesPairRequests {
        var requests = GlassesPairRequests()
        requests.open(now: start)
        return requests
    }

    private func ask(_ requests: inout GlassesPairRequests, at seconds: TimeInterval = 0, ticket: String = "ticket-1",
                     code: String = "4821") -> GlassesPairRequests.Asked {
        requests.ask(name: " Even G2 ", login: "someone@example.com", now: start.addingTimeInterval(seconds),
                     ticket: { ticket }, code: { code })
    }

    @Test func nothingIsAnsweredUntilPairGlassesIsClicked() {
        var requests = GlassesPairRequests()
        #expect(ask(&requests) == .closed)
        #expect(requests.pending(now: start) == nil)
        #expect(requests.wait(ticket: "ticket-1", now: start) == .gone)
    }

    @Test func theWindowClosesAfterAFewMinutes() {
        var requests = opened()
        #expect(requests.isOpen(now: start.addingTimeInterval(GlassesPairRequests.windowLifetime - 1)))
        #expect(!requests.isOpen(now: start.addingTimeInterval(GlassesPairRequests.windowLifetime)))
        #expect(ask(&requests, at: GlassesPairRequests.windowLifetime + 1) == .closed)
    }

    @Test func anApprovedRequestGetsItsTokenOnce() {
        var requests = opened()
        #expect(ask(&requests) == .created(ticket: "ticket-1", code: "4821"))
        #expect(requests.pending(now: start)?.code == "4821")
        #expect(requests.pending(now: start)?.name == "Even G2")
        #expect(requests.wait(ticket: "ticket-1", now: start) == .waiting)
        let answered = requests.answer(code: "4821", approve: true, now: start)
        #expect(answered)
        #expect(requests.pending(now: start) == nil)
        #expect(requests.wait(ticket: "ticket-1", now: start) == .approved(name: "Even G2", login: "someone@example.com"))
        // Once: asking again gets nothing, and the window is closed with it.
        #expect(requests.wait(ticket: "ticket-1", now: start) == .gone)
        #expect(!requests.isOpen(now: start))
        #expect(ask(&requests) == .closed)
    }

    @Test func aDeniedRequestGetsNothing() {
        var requests = opened()
        _ = ask(&requests)
        let answered = requests.answer(code: "4821", approve: false, now: start)
        #expect(answered)
        #expect(requests.wait(ticket: "ticket-1", now: start) == .denied)
        #expect(requests.wait(ticket: "ticket-1", now: start) == .gone)
    }

    @Test func aRequestExpires() {
        var requests = opened()
        _ = ask(&requests)
        let late = start.addingTimeInterval(GlassesPairRequests.requestLifetime)
        #expect(requests.pending(now: late) == nil)
        // Approving what's no longer shown does nothing.
        let answered = requests.answer(code: "4821", approve: true, now: late)
        #expect(!answered)
        #expect(requests.wait(ticket: "ticket-1", now: late) == .gone)
    }

    @Test func approvalIsForTheCodeThatWasShown() {
        var requests = opened()
        _ = ask(&requests)
        // A second request took its place between looking and clicking.
        _ = ask(&requests, ticket: "ticket-2", code: "7777")
        let stale = requests.answer(code: "4821", approve: true, now: start)
        #expect(!stale)
        #expect(requests.wait(ticket: "ticket-1", now: start) == .gone)
        #expect(requests.wait(ticket: "ticket-2", now: start) == .waiting)
        let answered = requests.answer(code: "7777", approve: true, now: start)
        #expect(answered)
        #expect(requests.wait(ticket: "ticket-2", now: start) == .approved(name: "Even G2", login: "someone@example.com"))
    }

    @Test func onlyAFewRequestsPerClick() {
        var requests = opened()
        for n in 0..<GlassesPairRequests.maxRequests {
            #expect(ask(&requests, ticket: "ticket-\(n)") == .created(ticket: "ticket-\(n)", code: "4821"))
        }
        #expect(ask(&requests) == .tooMany)
        // Clicking again starts over.
        requests.open(now: start)
        #expect(ask(&requests) == .created(ticket: "ticket-1", code: "4821"))
    }

    @Test func guessingTicketsClosesTheWindow() {
        var requests = opened()
        _ = ask(&requests)
        let answered = requests.answer(code: "4821", approve: true, now: start)
        #expect(answered)
        for n in 0..<GlassesPairRequests.maxWrongWaits {
            #expect(requests.wait(ticket: "guess-\(n)", now: start) == .gone)
        }
        // Even the right ticket is too late now: the approval went with the window.
        #expect(requests.wait(ticket: "ticket-1", now: start) == .gone)
        #expect(!requests.isOpen(now: start))
    }

    @Test func theCodeIsFourDigitsAndTheTicketIsLong() {
        for _ in 0..<50 {
            let code = GlassesPairRequests.shortCode()
            #expect(code.count == 4)
            #expect(code.allSatisfy { $0.isNumber })
        }
        var requests = opened()
        guard case .created(let ticket, _) = requests.ask(name: "", login: nil, now: start) else {
            Issue.record("no request")
            return
        }
        #expect(ticket.count >= 40)
        #expect(requests.pending(now: start)?.name == "Glasses")
    }

    // MARK: The kind of a paired device

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func aListSavedBeforeThereWereGlassesStillLoads() throws {
        let old = """
        [{"id": "one", "name": "iPhone", "tokenHash": "\(String(repeating: "a", count: 64))",
          "paired": "2025-01-01T10:00:00Z", "lastSeen": "2025-01-02T10:00:00Z", "login": "someone@example.com"}]
        """
        let devices = try decoder.decode([PhoneDevice].self, from: Data(old.utf8))
        #expect(devices.count == 1)
        #expect(devices[0].kind == nil)
        #expect(!devices[0].isGlasses)
    }

    @Test func glassesAreSavedAsGlasses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glasses-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("phone-devices.json")
        let phone = PhoneDevice(id: "one", name: "iPhone", tokenHash: String(repeating: "a", count: 64),
                                paired: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: nil, login: nil)
        let glasses = PhoneDevice(id: "two", name: "Even G2", tokenHash: String(repeating: "b", count: 64),
                                  paired: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: nil, login: nil,
                                  kind: PhoneDevice.glassesKind)
        #expect(PhoneDevices.write([phone, glasses], to: file))
        let loaded = try decoder.decode([PhoneDevice].self, from: Data(contentsOf: file))
        #expect(loaded == [phone, glasses])
        #expect(loaded.map(\.isGlasses) == [false, true])
        // A phone's entry is written as it always was, with no kind in it.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "\"kind\"").count == 2)
    }
}
