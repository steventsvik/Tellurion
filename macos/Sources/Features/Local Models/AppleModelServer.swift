#if os(macOS)
import Foundation
import Network
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Serves Apple's on-device model (Apple Intelligence, macOS 26) to Tellurion's local chat,
/// which runs in a terminal and can't call the framework itself.
///
/// It answers OpenAI-style chat requests on 127.0.0.1 only, on a port chosen at start, and
/// only with this launch's key. The port and key are in ~/.ghostty-extreme/apple-model.json,
/// readable only by the user. It starts the first time an Apple chat is opened.
final class AppleModelServer {
    static let shared = AppleModelServer()

    /// Whether this Mac can run Apple's model (Apple Intelligence on and ready). Checked once.
    static let isAvailable: Bool = {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }()

    static var infoFile: URL { AgentTools.root.appendingPathComponent("apple-model.json") }

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.apple-model")
    private var listener: NWListener?
    private let key = UUID().uuidString + UUID().uuidString

    /// Starts serving (once) and writes where. Throws if the model or the port isn't there.
    func start() throws {
        guard Self.isAvailable else {
            throw HookInstaller.Failure(message: "Apple's model isn't available. Turn on Apple Intelligence in System Settings.")
        }
        if listener != nil { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw HookInstaller.Failure(message: "Couldn't start serving Apple's model.")
        }
        self.listener = listener
        let info = try JSONSerialization.data(withJSONObject: ["port": Int(port), "token": key])
        let file = Self.infoFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: info, attributes: [.posixPermissions: 0o600])
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Reads one request: headers, then as much body as Content-Length says (64 KB at most).
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count < 1_048_576 else { connection.cancel(); return }
            guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let head = String(bytes: buffer[..<split.lowerBound], encoding: .utf8) ?? ""
            // The key comes first: without it nothing is waited for and no body is read.
            guard Self.authorized(head, key: self.key) else {
                return self.respond(connection, status: "401 Unauthorized", json: ["error": ["message": "Wrong key"]])
            }
            let body = buffer[split.upperBound...]
            let length = Self.bodyLength(head)
            if body.count < length, !done {
                self.receive(on: connection, buffer: buffer)
                return
            }
            self.handle(head: head, body: Data(body.prefix(length)), on: connection)
        }
    }

    /// Whether the request's head carries this launch's key.
    static func authorized(_ head: String, key: String) -> Bool {
        head.components(separatedBy: "\r\n").dropFirst().contains { line in
            guard line.lowercased().hasPrefix("authorization:") else { return false }
            return line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) == "Bearer " + key
        }
    }

    /// How much body the head announces: none when the length is missing, empty, negative
    /// or not a number, and never more than a request may be in all.
    static func bodyLength(_ head: String) -> Int {
        min(VeniceProxy.contentLength(head), 1_048_576)
    }

    private func handle(head: String, body: Data, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n")
        guard lines.first?.hasPrefix("POST /v1/chat/completions") == true,
              let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = request["messages"] as? [[String: Any]], !messages.isEmpty else {
            return respond(connection, status: "404 Not Found", json: ["error": ["message": "Only chat completions are served"]])
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        Task { [weak self] in
            await self?.stream(messages, to: connection)
        }
    }

    private func respond(_ connection: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// One server-sent event per new piece of the answer, then [DONE].
    private func stream(_ messages: [[String: Any]], to connection: NWConnection) async {
        func event(_ object: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            connection.send(content: Data("data: ".utf8) + data + Data("\n\n".utf8), completion: .contentProcessed { _ in })
        }
        func finish() {
            connection.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                // The framework keeps its own conversation; each request carries the whole one,
                // so earlier turns go in the instructions and the last message is the prompt.
                let text = { (message: [String: Any]) in message["content"] as? String ?? "" }
                let system = messages.filter { $0["role"] as? String == "system" }.map(text)
                let turns = messages.filter { $0["role"] as? String != "system" }
                let earlier = turns.dropLast().map { ($0["role"] as? String == "assistant" ? "Assistant: " : "User: ") + text($0) }
                var instructions = system.joined(separator: "\n")
                if !earlier.isEmpty { instructions += "\n\nThe conversation so far:\n" + earlier.joined(separator: "\n") }
                let session = instructions.isEmpty ? LanguageModelSession() : LanguageModelSession(instructions: instructions)
                var sent = ""
                for try await snapshot in session.streamResponse(to: text(turns.last ?? [:])) {
                    let content = snapshot.content
                    guard content.count > sent.count, content.hasPrefix(sent) else { continue }
                    event(["choices": [["delta": ["content": String(content.dropFirst(sent.count))]]]])
                    sent = content
                }
            } catch {
                event(["error": ["message": Self.describe(error)]])
            }
            return finish()
        }
        #endif
        event(["error": ["message": "Apple's model needs macOS 26 with Apple Intelligence."]])
        finish()
    }

    private static func describe(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return "The conversation is too long for Apple's model. Type /clear to start over."
            case .guardrailViolation:
                return "Apple's model declined to answer that."
            default: break
            }
        }
        #endif
        return error.localizedDescription
    }
}
#endif
