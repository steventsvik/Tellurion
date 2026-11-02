import Foundation

/// The parts of Venice's API Tellurion uses, as plain functions: what a key and a model's name
/// look like, reading its model list, what the local proxy lets through and what it changes.
enum VeniceAPI {
    static let base = URL(string: "https://api.venice.ai")!
    /// Where keys are made: in the browser, while signed in.
    static let keysPage = URL(string: "https://venice.ai/settings/api")!
    /// Asked with a key to see whether Venice takes it. Spends nothing.
    static let keyCheckPath = "api/v1/api_keys/rate_limits"
    static let modelsPath = "api/v1/models"

    /// Venice doesn't document a key's format, so this only keeps out what can't be one: anything
    /// that couldn't travel in a header.
    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 512 && key.utf8.allSatisfy { (33...126).contains($0) }
    }

    /// A name fit to put on a command line and in a window title: names come from the server.
    static func isValidSlug(_ slug: String) -> Bool {
        guard let first = slug.utf8.first, first != UInt8(ascii: "-"), slug.utf8.count <= 200 else { return false }
        return slug.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || [UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ":")].contains(byte)
        }
    }

    /// The only requests the proxy forwards. A key can do more than this (its account's balance,
    /// other keys), and that stays out of a terminal's reach. Compared as written, so an encoded
    /// path or `..` is simply not one of these; the model list's query can't hold anything that
    /// could change where a request goes.
    static func proxyAllows(method: String, target: String) -> Bool {
        switch (method, target) {
        case ("POST", "/api/v1/responses"), ("POST", "/api/v1/chat/completions"), ("GET", "/api/v1/models"):
            return true
        case ("GET", _):
            let prefix = "/api/v1/models?"
            guard target.hasPrefix(prefix) else { return false }
            return target.dropFirst(prefix.count).utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                    || [UInt8(ascii: "="), UInt8(ascii: "&"), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ".")].contains(byte)
            }
        default:
            return false
        }
    }

    /// A request on its way to Venice. Codex's `client_metadata` holds this Mac's folder paths and
    /// its installation id, which Venice has no use for, so it's left out; and Venice's own system
    /// prompt, on by default, doesn't go on top of the agent's. Nil if the body isn't a JSON object.
    ///
    /// Keys are written in sorted order, so a request's tools come out the same every turn: the
    /// model's prompt cache only matches on an identical start.
    static func forwardedBody(_ body: Data) -> Data? {
        guard var request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        request["client_metadata"] = nil
        var parameters = request["venice_parameters"] as? [String: Any] ?? [:]
        parameters["include_venice_system_prompt"] = false
        request["venice_parameters"] = parameters
        return try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    struct Model: Identifiable, Equatable {
        let id: String
        var name: String
        var uncensored: Bool
        /// "Private": Venice says nothing is stored. Otherwise anonymized: the model's own
        /// provider sees what's sent, under its own policy.
        var isPrivate: Bool
        var context: Int?
        var maxOutput: Int?
        /// US dollars per million tokens.
        var inputPrice: Double?
        var cachedInputPrice: Double?
        var outputPrice: Double?
        /// Can call tools, which an agent needs.
        var tools: Bool
        var optimizedForCode: Bool
        var vision: Bool
        var reasoning: Bool
        /// Needs encryption on the client's side, which only a chat request can carry.
        var encrypted: Bool

        /// An agent can use it: tools, and Venice's Responses API (not for E2EE models).
        var worksInCodex: Bool { tools && !encrypted }

        var detail: String {
            var parts: [String] = []
            if let context { parts.append(context >= 1_000_000 ? "\(context / 1_000_000)M context" : "\(context / 1000)K context") }
            if let inputPrice, let outputPrice {
                parts.append("$\(Self.price(inputPrice)) in · $\(Self.price(outputPrice)) out per M")
            }
            parts.append(tools ? "Tools" : "No tools")
            return parts.joined(separator: " · ")
        }

        private static func price(_ value: Double) -> String {
            value >= 10 || value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
        }
    }

    /// GET /models?type=text: `{"data":[{"id":"…","model_spec":{…}}]}`. Nil if it isn't that.
    /// Offline models are left out, and any with a name that couldn't go on a command line.
    static func parseModels(_ data: Data) -> [Model]? {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = reply["data"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, isValidSlug(id) else { return nil }
            let spec = row["model_spec"] as? [String: Any] ?? [:]
            guard spec["offline"] as? Bool != true else { return nil }
            let capabilities = spec["capabilities"] as? [String: Any] ?? [:]
            let pricing = spec["pricing"] as? [String: Any] ?? [:]
            func dollars(_ key: String) -> Double? { ((pricing[key] as? [String: Any])?["usd"] as? NSNumber)?.doubleValue }
            func can(_ key: String) -> Bool { capabilities[key] as? Bool ?? false }
            return Model(id: id, name: printable(spec["name"] as? String) ?? id,
                         uncensored: spec["uncensored"] as? Bool ?? false,
                         isPrivate: spec["privacy"] as? String == "private",
                         context: spec["availableContextTokens"] as? Int,
                         maxOutput: spec["maxCompletionTokens"] as? Int,
                         inputPrice: dollars("input"), cachedInputPrice: dollars("cache_input"), outputPrice: dollars("output"),
                         tools: can("supportsFunctionCalling"), optimizedForCode: can("optimizedForCode"),
                         vision: can("supportsVision"), reasoning: can("supportsReasoning"), encrypted: can("supportsE2EE"))
        }
    }

    /// Text from the server, without anything that could steer a terminal or a label.
    private static func printable(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 && !(127...159).contains($0.value) }))
        return kept.isEmpty ? nil : kept
    }

    /// Uncensored first, then what's made for code, then by name.
    static func sorted(_ models: [Model]) -> [Model] {
        models.sorted {
            ($0.uncensored ? 0 : 1, $0.optimizedForCode ? 0 : 1, $0.name.lowercased())
                < ($1.uncensored ? 0 : 1, $1.optimizedForCode ? 0 : 1, $1.name.lowercased())
        }
    }

    /// What to tell the person when connecting with a key fails.
    static func connectionProblem(status: Int) -> String {
        switch status {
        case 401, 403: return "Venice doesn't accept that key. It may be mistyped, expired or revoked."
        case 429: return "Venice is limiting requests right now. Try again in a minute."
        default: return "Venice answered with an error (\(status)). Try again."
        }
    }
}
