#if os(macOS)
import Foundation
import os

/// Pairing glasses by approving them on the Mac. The app on the glasses' menu can't carry
/// a code from a QR, so it asks; the glasses show a short code, the Phone window shows the
/// same one with Approve and Deny, and on Approve the waiting app is handed its token once.
///
/// It only answers for a few minutes after "Pair glasses" is clicked, a few times, and a
/// request lasts two minutes. Plain values and a clock passed in, so it can be tested.
struct GlassesPairRequests {
    static let windowLifetime: TimeInterval = 5 * 60
    static let requestLifetime: TimeInterval = 2 * 60
    /// Requests per click of "Pair glasses".
    static let maxRequests = 3
    /// Waits with the wrong ticket before the window closes.
    static let maxWrongWaits = 5

    struct Request: Equatable {
        enum State: Equatable { case waiting, approved, denied }

        /// What the app waits with. Long and random: it's what the token is handed over for.
        let ticket: String
        /// What the glasses and the Mac both show.
        let code: String
        let name: String
        let login: String?
        let expires: Date
        var state = State.waiting
    }

    enum Asked: Equatable {
        case created(ticket: String, code: String)
        /// Nobody clicked "Pair glasses" lately.
        case closed
        case tooMany
    }

    enum Waited: Equatable {
        case waiting
        /// Approved: the token may be made and handed over, this once.
        case approved(name: String, login: String?)
        case denied
        /// Too late, or not a ticket that was given out.
        case gone
    }

    private(set) var openUntil = Date.distantPast
    private(set) var request: Request?
    private var asked = 0
    private var wrongWaits = 0

    func isOpen(now: Date = Date()) -> Bool { now < openUntil }

    /// The request to show on the Mac, while it waits for an answer.
    func pending(now: Date = Date()) -> Request? {
        guard let request, request.state == .waiting, now < request.expires else { return nil }
        return request
    }

    /// "Pair glasses" was clicked.
    mutating func open(now: Date = Date()) {
        openUntil = now.addingTimeInterval(Self.windowLifetime)
        asked = 0
        wrongWaits = 0
    }

    mutating func close() {
        openUntil = .distantPast
        request = nil
    }

    /// The glasses app asks to pair. A new request replaces one still waiting.
    mutating func ask(name: String, login: String?, now: Date = Date(),
                      ticket: () -> String = { PhoneDevices.random(bytes: 32) },
                      code: () -> String = GlassesPairRequests.shortCode) -> Asked {
        guard isOpen(now: now) else { return .closed }
        guard asked < Self.maxRequests else { return .tooMany }
        asked += 1
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = Request(ticket: ticket(), code: code(), name: trimmed.isEmpty ? "Glasses" : String(trimmed.prefix(40)),
                           login: login, expires: now.addingTimeInterval(Self.requestLifetime))
        request = made
        return .created(ticket: made.ticket, code: made.code)
    }

    /// Approve or Deny on the Mac, for the request showing `code`.
    @discardableResult
    mutating func answer(code: String, approve: Bool, now: Date = Date()) -> Bool {
        guard var current = pending(now: now), PhoneDevices.equal(current.code, code) else { return false }
        current.state = approve ? .approved : .denied
        request = current
        return true
    }

    /// The app asks how its request is doing. An approval is reported once: the request is
    /// gone after it, and so is the window.
    mutating func wait(ticket: String, now: Date = Date()) -> Waited {
        guard let current = request, PhoneDevices.equal(current.ticket, ticket) else {
            wrongWaits += 1
            if wrongWaits >= Self.maxWrongWaits { close() }
            return .gone
        }
        guard now < current.expires else {
            request = nil
            return .gone
        }
        switch current.state {
        case .waiting:
            return .waiting
        case .denied:
            request = nil
            return .denied
        case .approved:
            close()
            return .approved(name: current.name, login: current.login)
        }
    }

    /// Four digits, easy to compare at a glance.
    static func shortCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%04d", Int.random(in: 0...9999, using: &generator))
    }
}

/// The live pairing requests, for the Phone window and the server.
final class GlassesPairing: ObservableObject {
    static let shared = GlassesPairing()

    @Published private(set) var requests = GlassesPairRequests()
    private var expiry: Timer?
    private static let log = StoredFile.logger("Glasses")

    private init() {}

    var isOpen: Bool { requests.isOpen() }
    var pending: GlassesPairRequests.Request? { requests.pending() }

    func open() {
        requests.open()
        watchExpiry()
    }

    func close() {
        requests.close()
        expiry?.invalidate()
        expiry = nil
    }

    func ask(name: String, login: String?) -> GlassesPairRequests.Asked {
        let asked = requests.ask(name: name, login: login)
        if case .created = asked { Self.log.info("Glasses asked to pair") }
        return asked
    }

    func answer(code: String, approve: Bool) {
        if requests.answer(code: code, approve: approve) {
            Self.log.info("A glasses pairing request was \(approve ? "approved" : "denied", privacy: .public)")
        }
    }

    func wait(ticket: String) -> GlassesPairRequests.Waited { requests.wait(ticket: ticket) }

    /// The window reads the clock: looked at again every few seconds while anything is open.
    private func watchExpiry() {
        guard expiry == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            if !self.requests.isOpen() { self.close() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }
}

/// The glasses app's HTTP requests: pairing, and a ping that says whether glasses are on.
enum GlassesHTTP {
    /// The answer for a request under /glasses/, or nil when it's an ordinary file.
    static func response(for request: PhoneHTTPServer.Request, isOn: Bool = TellurionSettings.isOn(.glasses)) -> PhoneHTTPServer.Response? {
        guard request.path == "/glasses" || request.path.hasPrefix(GlassesRoutes.prefix) else { return nil }
        let cors = GlassesRoutes.corsHeaders(path: request.path)
        func with(_ response: PhoneHTTPServer.Response) -> PhoneHTTPServer.Response {
            var response = response
            response.headers.merge(cors) { _, new in new }
            return response
        }
        guard isOn else { return with(.json(["error": "Glasses are turned off in Tellurion's settings.", "code": "off"], status: 404)) }
        guard request.path.hasPrefix(GlassesRoutes.api) else {
            // The page itself is a file; the tests and the packaging helper beside it aren't served.
            let hidden = request.method != "GET" || request.path == "/glasses" || GlassesRoutes.isHidden(path: request.path)
            return hidden ? .text("Not found", status: 404) : nil
        }
        if request.method == "OPTIONS" { return with(PhoneHTTPServer.Response(status: 204)) }
        let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let login = request.headers["tailscale-user-login"]
        let name = body["name"] as? String ?? "Glasses"
        switch (request.method, String(request.path.dropFirst(GlassesRoutes.api.count))) {
        case ("GET", "ping"):
            return with(.json(["ok": true, "v": GlassesServer.version]))
        case ("POST", "pair"):
            guard let code = body["code"] as? String, code.count <= 64 else { return with(.json(["error": "Missing code"], status: 400)) }
            switch PhoneDevices.shared.pair(code: code, name: name, login: login, kind: PhoneDevice.glassesKind) {
            case .paired(let token, let device): return with(.json(paired(token, device)))
            case .invalid: return with(.json(["error": "That pairing code isn't valid any more. Show a new one on your Mac."], status: 401))
            case .locked: return with(.json(["error": "Too many wrong codes. Show a new one on your Mac."], status: 429))
            }
        case ("POST", "pair-request"):
            switch GlassesPairing.shared.ask(name: name, login: login) {
            case .created(let ticket, let code):
                return with(.json(["ticket": ticket, "code": code, "expires": Int(GlassesPairRequests.requestLifetime)]))
            case .closed:
                return with(.json(["error": "On your Mac: Tellurion → Phone → Pair glasses.", "code": "closed"], status: 403))
            case .tooMany:
                return with(.json(["error": "Too many tries. Click Pair glasses on your Mac again.", "code": "closed"], status: 429))
            }
        case ("POST", "pair-wait"):
            guard let ticket = body["ticket"] as? String, ticket.count <= 128 else { return with(.json(["error": "Missing ticket"], status: 400)) }
            switch GlassesPairing.shared.wait(ticket: ticket) {
            case .waiting: return with(.json(["state": "waiting"]))
            case .denied: return with(.json(["state": "denied"]))
            case .gone: return with(.json(["state": "gone"]))
            case .approved(let name, let login):
                let (token, device) = PhoneDevices.shared.add(name: name, login: login, kind: PhoneDevice.glassesKind)
                var reply = paired(token, device)
                reply["state"] = "approved"
                return with(.json(reply))
            }
        default:
            return with(.text("Not found", status: 404))
        }
    }

    private static func paired(_ token: String, _ device: PhoneDevice) -> [String: Any] {
        ["token": token, "device": device.id, "mac": Host.current().localizedName ?? "Mac"]
    }
}
#endif
