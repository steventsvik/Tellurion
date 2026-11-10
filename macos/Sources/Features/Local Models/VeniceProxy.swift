import Foundation
import Network

/// Lets agents and chats in a terminal use a Venice account without ever having its key.
///
/// They talk to this on 127.0.0.1 only, on a port chosen at start, with this launch's token. Port
/// and token are in a file only the user can read. This adds the key, takes out what Venice
/// shouldn't get (`VeniceAPI.forwardedBody`) and passes the answer through as it arrives, for the
/// requests `VeniceAPI.proxyAllows` names and no others. So the key stays in this process and the
/// keychain: never in a terminal's environment, a command line or a file an agent can read.
///
/// A program running as the user can read the token and use the account while Tellurion runs,
/// but can't learn the key or reach anything else it can do.
final class VeniceProxy: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The most a request can carry: a long conversation, with pictures.
    private static let maxRequest = 64 * 1_048_576
    /// How long a request waits for the keychain before it's told why nothing is happening.
    private static let keyPatience: TimeInterval = 15

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.venice-proxy")
    private let upstream: URL
    private let infoFile: URL
    /// Reads the key when the first request needs it, so that starting at launch doesn't touch
    /// the keychain (which can ask the user).
    private let readKey: @Sendable () -> String?
    private let meter: VeniceSpendMeter
    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private var apiKey: String?
    /// Requests waiting for the keychain, which can be waiting for the user.
    private var keyWaiters: [(String?) -> Void] = []
    /// The requests in flight; closing one's connection stops it, which stops the model too.
    private var relays: [ObjectIdentifier: Relay] = [:]

    init(upstream: URL, infoFile: URL, meter: VeniceSpendMeter = .shared, readKey: @escaping @Sendable () -> String?) {
        self.meter = meter
        self.upstream = upstream
        self.infoFile = infoFile
        self.readKey = readKey
    }

    /// Serves, and writes where. Starting again does nothing but forget the key it had read,
    /// unless the listener has failed since: then it starts a new one.
    func start() throws {
        try queue.sync {
            apiKey = nil
            if listener != nil { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: ready.signal()
                case .failed:
                    ready.signal()
                    // It stopped serving: forget it, so the next `start()` makes a new one.
                    self?.queue.async {
                        guard let self, let listener, self.listener === listener else { return }
                        listener.cancel()
                        self.listener = nil
                        try? FileManager.default.removeItem(at: self.infoFile)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
            // A listener on this Mac is ready at once; this is called on the main thread.
            _ = ready.wait(timeout: .now() + 1)
            guard let port = listener.port?.rawValue else {
                listener.cancel()
                throw Failure(message: "Couldn't start the connection to Venice.")
            }
            self.listener = listener
            let info = try JSONSerialization.data(withJSONObject: ["port": Int(port), "token": token], options: .sortedKeys)
            try FileManager.default.createDirectory(at: infoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Made with its mode, so it's never readable by anyone else, even for a moment.
            FileManager.default.createFile(atPath: infoFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: infoFile.path)
            try info.write(to: infoFile)
        }
    }

    /// Stops serving and forgets the key: the account was disconnected.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            apiKey = nil
            relays.values.forEach { $0.cancel() }
            relays = [:]
            try? FileManager.default.removeItem(at: infoFile)
        }
    }

    // MARK: Reading a request

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= Self.maxRequest else { connection.cancel(); return }
            guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let head = String(bytes: buffer[..<split.lowerBound], encoding: .utf8) ?? ""
            let length = Self.contentLength(head)
            let available = buffer.distance(from: split.upperBound, to: buffer.endIndex)
            if available < length {
                if done { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            self.handle(head: head, body: Data(buffer[split.upperBound...].prefix(length)), on: connection)
        }
    }

    /// This runs before the token is checked, so any program on the Mac can send anything here:
    /// a negative length counts as none, or taking that much of the body would crash the app.
    static func contentLength(_ head: String) -> Int {
        let length = head.components(separatedBy: "\r\n").lazy.compactMap { line -> Int? in
            guard line.lowercased().hasPrefix("content-length:") else { return nil }
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        return max(0, length)
    }

    private func handle(head: String, body: Data, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let authorized = lines.dropFirst().contains { line in
            guard line.lowercased().hasPrefix("authorization:") else { return false }
            return line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) == "Bearer " + token
        }
        guard authorized else {
            return respond(connection, status: "401 Unauthorized", code: "proxy_token", message: "Wrong token")
        }
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        guard request.count == 3, VeniceAPI.proxyAllows(method: request[0], target: request[1]),
              let url = URL(string: upstream.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + request[1]) else {
            return respond(connection, status: "404 Not Found", code: "not_forwarded", message: "Only the model list and model requests go through here")
        }
        // A body this can't read could carry what `forwardedBody` is there to leave out.
        let unreadable = lines.dropFirst().contains { line in
            let lower = line.lowercased()
            return lower.hasPrefix("content-encoding:") || lower.hasPrefix("transfer-encoding:")
        }
        if request[0] == "POST", unreadable {
            return respond(connection, status: "415 Unsupported Media Type", code: "unreadable_body", message: "Send the request as plain JSON with a Content-Length")
        }
        // Reading the model list costs nothing; every model request is checked against the limit.
        if request[0] == "POST", meter.overLimit {
            return respond(connection, status: "402 Payment Required", code: "spending_limit", message: meter.limitMessage)
        }
        var answered = false
        queue.asyncAfter(deadline: .now() + Self.keyPatience) { [weak self] in
            guard !answered else { return }
            answered = true
            self?.respond(connection, status: "503 Service Unavailable", code: "waiting_for_keychain",
                          message: "Waiting for your Venice key. Look for a Keychain prompt from Tellurion and click Always Allow.")
        }
        withKey { [weak self] key in
            guard let self, !answered else { return }
            answered = true
            guard let key, !key.isEmpty else {
                return self.respond(connection, status: "503 Service Unavailable", code: "not_connected", message: "Not connected")
            }
            self.forward(request, url: url, body: body, key: key, on: connection)
        }
    }

    /// Off this queue, since macOS can sit on the read until the user answers its prompt, and
    /// nothing else here could run meanwhile.
    private func withKey(_ use: @escaping (String?) -> Void) {
        if let apiKey { return use(apiKey) }
        keyWaiters.append(use)
        guard keyWaiters.count == 1 else { return }
        let read = readKey
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = read()
            self?.queue.async {
                guard let self else { return }
                if self.listener != nil { self.apiKey = key }
                let waiting = self.keyWaiters
                self.keyWaiters = []
                waiting.forEach { $0(self.apiKey) }
            }
        }
    }

    private func forward(_ request: [String], url: URL, body: Data, key apiKey: String, on connection: NWConnection) {
        var outgoing = URLRequest(url: url, timeoutInterval: 600)
        outgoing.httpMethod = request[0]
        outgoing.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if request[0] == "POST" {
            guard let forwarded = VeniceAPI.forwardedBody(body, keepSecrets: VeniceCodexOption.secretFiles.isOn) else {
                return respond(connection, status: "400 Bad Request", code: "not_json", message: "The request isn't a JSON object")
            }
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
            outgoing.httpBody = forwarded
        }
        let relay = Relay(connection: connection, queue: queue, meter: meter) { [weak self] relay in
            self?.relays[ObjectIdentifier(relay)] = nil
        }
        relays[ObjectIdentifier(relay)] = relay
        relay.start(outgoing)
    }

    private func respond(_ connection: NWConnection, status: String, code: String, message: String) {
        let json: [String: Any] = ["error": ["code": code, "message": message]]
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Passing the answer through

    /// One request: its answer goes to the connection piece by piece as it arrives. Redirects
    /// aren't followed, so the key only ever goes to the address asked for.
    private final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let meter: VeniceSpendMeter
        private let finished: (Relay) -> Void
        private var session: URLSession?
        private var closed = false

        init(connection: NWConnection, queue: DispatchQueue, meter: VeniceSpendMeter, finished: @escaping (Relay) -> Void) {
            self.meter = meter
            self.connection = connection
            self.queue = queue
            self.finished = finished
        }

        func start(_ request: URLRequest) {
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            session.dataTask(with: request).resume()
            watchForHangUp()
        }

        func cancel() {
            guard !closed else { return }
            closed = true
            session?.invalidateAndCancel()
            session = nil
            connection.cancel()
        }

        /// The chat closes its side when Ctrl-C stops a reply, or when it ends.
        private func watchForHangUp() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
                guard let self, !self.closed else { return }
                if done || error != nil {
                    self.cancel()
                    self.finished(self)
                } else {
                    self.watchForHangUp()
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            if let balance = http?.value(forHTTPHeaderField: "x-venice-balance-usd").flatMap(Double.init) {
                meter.record(balance: balance)
            }
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            head += "Content-Type: \(Self.headerValue(http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"))\r\n"
            // What an agent reads to back off and to size its requests.
            for case let (name as String, value as String) in http?.allHeaderFields ?? [:] {
                let lower = name.lowercased()
                guard lower == "retry-after" || lower.hasPrefix("x-ratelimit-") || lower.hasPrefix("x-venice-")
                    || lower == "x-request-id" else { continue }
                head += "\(Self.headerValue(name)): \(Self.headerValue(value))\r\n"
            }
            head += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            completionHandler(.allow)
        }

        private static func headerValue(_ text: String) -> String {
            text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !closed else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !closed else { return }
            closed = true
            session.finishTasksAndInvalidate()
            self.session = nil
            if error != nil, task.response == nil {
                // Never reached the server: the chat says so, the way it does for any model server.
                let body = Data(#"{"error":{"code":"unreachable","message":"Venice isn't answering. Check your connection."}}"#.utf8)
                let head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [connection] _ in connection.cancel() })
            } else {
                // After everything already handed over.
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
            }
            finished(self)
        }
    }
}
