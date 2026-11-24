#if os(macOS)
import CryptoKit
import Foundation
import Network

/// A small HTTP/1.1 and WebSocket server for the phone. It listens on 127.0.0.1 only; the
/// phone reaches it through `tailscale serve`, which terminates HTTPS on the tailnet and
/// forwards here with the Tailscale user in a header.
final class PhoneHTTPServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        /// Lowercased names.
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }

        static func text(_ text: String, status: Int) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }
    }

    /// Answers a plain request (called on the main queue).
    var handleRequest: (Request) -> Response = { _ in .text("Not found", status: 404) }
    /// Whether to accept a WebSocket upgrade; the socket's events go to the returned value.
    var acceptSocket: (Request, PhoneSocket) -> Bool = { _, _ in false }

    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.phone", qos: .userInitiated)

    init(port: UInt16) {
        self.port = port
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { DispatchQueue.main.async { self?.stop() } }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connections

    private static let maxHeader = 16 * 1024
    private static let maxBody = 256 * 1024

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (done && data == nil) { connection.cancel(); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeader { connection.cancel() } else { self.readRequest(connection, buffer: buffer) }
                return
            }
            guard end.lowerBound - buffer.startIndex <= Self.maxHeader else {
                self.send(.text("Headers too large", status: 431), on: connection)
                return
            }
            guard var request = Self.parseHead(buffer[..<end.lowerBound]) else { connection.cancel(); return }
            let length = Int(request.headers["content-length"] ?? "0") ?? 0
            guard length <= Self.maxBody else { self.send(.text("Too large", status: 413), on: connection); return }
            let body = buffer[end.upperBound...]
            if body.count < length {
                self.readBody(connection, request: request, body: Data(body), length: length)
                return
            }
            request = Request(method: request.method, path: request.path, query: request.query,
                              headers: request.headers, body: Data(body.prefix(length)))
            self.dispatch(request, on: connection)
        }
    }

    private func readBody(_ connection: NWConnection, request: Request, body: Data, length: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: length - body.count) { [weak self] data, _, done, error in
            guard let self else { return }
            var body = body
            if let data { body.append(data) }
            if error != nil || (done && body.count < length) { connection.cancel(); return }
            if body.count < length { self.readBody(connection, request: request, body: body, length: length); return }
            self.dispatch(Request(method: request.method, path: request.path, query: request.query,
                                  headers: request.headers, body: body), on: connection)
        }
    }

    private static func parseHead(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: target?.path ?? "/", query: query, headers: headers, body: Data())
    }

    private func dispatch(_ request: Request, on connection: NWConnection) {
        if request.headers["upgrade"]?.lowercased() == "websocket" {
            upgrade(request, on: connection)
            return
        }
        DispatchQueue.main.async {
            let response = self.handleRequest(request)
            self.send(response, on: connection)
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Referrer-Policy"] = "no-referrer"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }

    // MARK: WebSocket

    private func upgrade(_ request: Request, on connection: NWConnection) {
        guard request.method == "GET", let key = request.headers["sec-websocket-key"],
              request.headers["sec-websocket-version"] == "13" else {
            send(.text("Bad WebSocket request", status: 400), on: connection)
            return
        }
        let socket = PhoneSocket(connection: connection, queue: queue)
        DispatchQueue.main.async {
            guard self.acceptSocket(request, socket) else {
                self.send(.text("Forbidden", status: 403), on: connection)
                return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in socket.startReading() })
        }
    }
}

/// One WebSocket connection: text messages in and out, and binary ones in (the glasses'
/// sound). Events arrive on the main queue.
final class PhoneSocket {
    var onMessage: (String) -> Void = { _ in }
    var onBinary: (Data) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var assembler = MessageAssembler()
    private var closed = false
    /// Messages handed to the network and not yet sent (read and written on `queue`).
    private var pending = 0

    static let maxMessage = 1024 * 1024

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Whether the connection is keeping up; screen updates are skipped while it isn't.
    var isBackedUp: Bool { queue.sync { pending > 4 } }

    func send(_ text: String) {
        let data = Self.frame(opcode: 0x1, payload: Data(text.utf8))
        queue.async { self.write(data) }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.write(Self.frame(opcode: 0x8, payload: Data([0x03, 0xE8])))
            self.finish()
        }
    }

    fileprivate func startReading() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.parse() }
            if error != nil || done { self.finish(); return }
            if !self.closed { self.startReading() }
        }
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            data.append(126)
            data.append(UInt8(payload.count >> 8))
            data.append(UInt8(payload.count & 0xFF))
        } else {
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        data.append(payload)
        return data
    }

    /// Sends a frame (on `queue`).
    private func write(_ data: Data) {
        guard !closed else { return }
        pending += 1
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.pending -= 1 }
        })
    }

    /// The start of a frame from a client: where its mask is and how long its payload is.
    struct FrameHeader: Equatable {
        let fin: Bool
        let opcode: UInt8
        /// Where the four mask bytes start; the payload follows them.
        let offset: Int
        let length: Int
        /// The header, the mask and the payload together.
        var size: Int { offset + 4 + length }
    }

    enum FrameStart: Equatable {
        /// More bytes are needed to tell.
        case incomplete
        /// Not a frame this accepts; the connection closes.
        case invalid
        case header(FrameHeader)
    }

    /// Reads a frame's header from the first bytes of what has arrived. This runs before the
    /// device says who it is, so the length is whatever was sent: it's read unsigned and
    /// held to `maxMessage`, or a huge one would turn negative and crash the app when the
    /// payload is taken.
    static func frameStart(_ bytes: [UInt8]) -> FrameStart {
        guard bytes.count >= 2 else { return .incomplete }
        var length = UInt64(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return .incomplete }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return .incomplete }
            length = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            offset = 10
        }
        // Clients must mask their frames.
        guard bytes[1] & 0x80 != 0, length <= UInt64(maxMessage) else { return .invalid }
        return .header(FrameHeader(fin: bytes[0] & 0x80 != 0, opcode: bytes[0] & 0x0F, offset: offset, length: Int(length)))
    }

    /// Puts a message together from its frames: one text or binary frame, then any
    /// continuations. Held to `maxMessage` in all, like a single frame.
    struct MessageAssembler {
        enum Output: Equatable {
            /// More frames to come.
            case none
            case text(String)
            case binary(Data)
            /// Not how messages are framed, or too long; the connection closes.
            case invalid
        }

        private var fragments = Data()
        /// Whether the message being put together is binary; nil between messages.
        private var binary: Bool?

        mutating func add(opcode: UInt8, fin: Bool, payload: [UInt8], limit: Int = PhoneSocket.maxMessage) -> Output {
            switch opcode {
            case 0x0: guard binary != nil else { return .invalid }
            case 0x1, 0x2:
                guard binary == nil else { return .invalid }
                binary = opcode == 0x2
            default: return .invalid
            }
            fragments.append(contentsOf: payload)
            guard fragments.count <= limit else { return .invalid }
            guard fin else { return .none }
            let whole = fragments
            let wasBinary = binary == true
            fragments = Data()
            binary = nil
            return wasBinary ? .binary(whole) : .text(String(decoding: whole, as: UTF8.self))
        }
    }

    /// Reads whole frames out of `buffer` (on `queue`).
    private func parse() {
        while buffer.count >= 2 {
            let header: FrameHeader
            switch Self.frameStart([UInt8](buffer.prefix(14))) {
            case .incomplete: return
            case .invalid: finish(); return
            case .header(let found): header = found
            }
            guard buffer.count >= header.size else { return }
            let start = buffer.startIndex + header.offset
            let mask = [UInt8](buffer[start..<(start + 4)])
            var payload = [UInt8](buffer[(start + 4)..<(start + 4 + header.length)])
            for i in payload.indices { payload[i] ^= mask[i % 4] }
            buffer.removeFirst(header.size)

            switch header.opcode {
            case 0x0, 0x1, 0x2:
                switch assembler.add(opcode: header.opcode, fin: header.fin, payload: payload) {
                case .none: break
                case .text(let text): DispatchQueue.main.async { self.onMessage(text) }
                case .binary(let data): DispatchQueue.main.async { self.onBinary(data) }
                case .invalid: finish(); return
                }
            case 0x8:
                write(Self.frame(opcode: 0x8, payload: Data(payload.prefix(2))))
                finish()
                return
            case 0x9:
                write(Self.frame(opcode: 0xA, payload: Data(payload)))
            case 0xA:
                break
            default:
                finish()
                return
            }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
        DispatchQueue.main.async { self.onClose() }
    }
}
#endif
