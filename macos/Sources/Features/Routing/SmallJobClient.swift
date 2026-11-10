#if os(macOS)
import Foundation

/// Asks Ollama or LM Studio for one answer, straight over HTTP: no proxy, no redirects, a time
/// limit, a size limit, and only to this Mac or the server OLLAMA_HOST names.
struct SmallJobClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    enum Failure: Error, Equatable {
        case notAllowed, timedOut, unreachable, status(Int), tooLarge, unreadable, cutOff

        /// For the log. Never anything the server said: that could carry the prompt.
        var reason: String {
            switch self {
            case .notAllowed: return "the model's server isn't on this Mac"
            case .timedOut: return "it took too long"
            case .unreachable: return "the model's server didn't answer"
            case .status(let code): return "the model's server answered \(code)"
            case .tooLarge: return "an answer that's too big"
            case .unreadable: return "an answer that couldn't be read"
            case .cutOff: return "an answer that was cut off"
            }
        }
    }

    /// The most a server may send back, in bytes.
    static let responseLimit = 256 * 1024

    var transport: Transport
    var ollamaBase: URL
    var lmStudioBase: URL
    /// Hosts that aren't this Mac but were named on purpose (OLLAMA_HOST).
    var configuredHosts: Set<String>

    /// The servers the rest of Tellurion talks to.
    static var live: SmallJobClient {
        let named = ProcessInfo.processInfo.environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let ollama = LocalModelsModel.ollamaBase
        return SmallJobClient(transport: { try await direct($0) }, ollamaBase: ollama, lmStudioBase: LocalModelsModel.lmStudioBase,
                              configuredHosts: named.isEmpty ? [] : Set([ollama.host].compactMap { $0 }))
    }

    // MARK: Asking

    /// Every model the two servers have, loaded or not. Empty when neither is running.
    func models() async -> [SmallJobModel] {
        async let tags = get(ollamaBase.appendingPathComponent("api/tags"))
        async let running = get(ollamaBase.appendingPathComponent("api/ps"))
        async let studio = get(lmStudioBase.appendingPathComponent("api/v0/models"))
        let (listed, loaded, served) = await (tags, running, studio)
        return SmallJobModels.ollama(tags: listed, running: loaded) + SmallJobModels.lmStudio(served)
    }

    /// One answer from `model`, as it came. Throws a `Failure`.
    func ask(_ model: SmallJobModel, instructions: String, prompt: String, outputTokens: Int, timeout: TimeInterval) async throws -> String {
        guard let request = request(model, instructions: instructions, prompt: prompt, outputTokens: outputTokens, timeout: timeout) else {
            throw Failure.notAllowed
        }
        let (data, response) = try await send(request, timeout: timeout)
        guard response.statusCode == 200 else { throw Failure.status(response.statusCode) }
        return try Self.answer(model.host, in: data)
    }

    /// The request for one answer, or nil for a model on a host small jobs don't talk to.
    func request(_ model: SmallJobModel, instructions: String, prompt: String, outputTokens: Int, timeout: TimeInterval) -> URLRequest? {
        let messages = [["role": "system", "content": instructions], ["role": "user", "content": prompt]]
        let url: URL
        var body: [String: Any] = ["model": model.name, "messages": messages, "stream": false]
        switch model.host {
        case .ollama:
            url = ollamaBase.appendingPathComponent("api/chat")
            // Nothing here changes how the model is loaded (no context size), so a loaded
            // model answers as it is. Twice the room, for a model that thinks aloud anyway.
            body["options"] = ["temperature": 0.2, "num_predict": outputTokens * 2]
            if model.thinks { body["think"] = false }
        case .lmStudio:
            url = lmStudioBase.appendingPathComponent("v1/chat/completions")
            body["temperature"] = 0.2
            body["max_tokens"] = outputTokens * 2
        case .llamaCpp, .mlx, .apple, .venice:
            return nil
        }
        guard isAllowed(url), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    /// The text of an answer: Ollama's `/api/chat`, or the OpenAI shape LM Studio speaks.
    static func answer(_ host: LocalModel.Host, in data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        let text: String?, stop: String?
        if host == .ollama {
            text = (json["message"] as? [String: Any])?["content"] as? String
            stop = json["done_reason"] as? String
        } else {
            let choice = (json["choices"] as? [[String: Any]])?.first
            text = (choice?["message"] as? [String: Any])?["content"] as? String
            stop = choice?["finish_reason"] as? String
        }
        guard let text else { throw Failure.unreadable }
        if stop == "length" { throw Failure.cutOff }
        return text
    }

    // MARK: Where it may go

    /// This Mac, by name or address.
    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } && parts[0] == "127"
    }

    func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { return false }
        return Self.isLoopback(host) || configuredHosts.contains(host)
    }

    // MARK: Transport

    private func get(_ url: URL) async -> [String: Any]? {
        guard isAllowed(url), let (data, response) = try? await send(URLRequest(url: url, timeoutInterval: 2), timeout: 2),
              response.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Sends it, giving up after `timeout` however slowly the answer trickles in.
    private func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let transport = self.transport
        do {
            let reply = try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
                group.addTask { try await transport(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw Failure.unreachable }
                return first
            }
            guard reply.0.count <= Self.responseLimit else { throw Failure.tooLarge }
            return reply
        } catch let failure as Failure {
            throw failure
        } catch let error as URLError where error.code == .timedOut {
            throw Failure.timedOut
        } catch {
            throw Failure.unreachable
        }
    }

    /// Straight to the server, whatever proxy the system names: through one, a prompt for a
    /// model on this Mac would leave it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Reads no more than `responseLimit` of an answer.
    static func direct(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard response.expectedContentLength <= Int64(responseLimit) else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > responseLimit { throw Failure.tooLarge }
        }
        return (data, http)
    }
}

/// A redirect could point anywhere, so none is followed: the redirect itself is the answer.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
