#if os(macOS)
import AppKit
import Combine

/// A model to chat with: on this Mac, from Ollama or LM Studio and the like, or starred from a
/// connected Venice account (the one host that isn't on this Mac).
struct LocalModel: Identifiable, Equatable {
    enum Host: String {
        case ollama = "Ollama", lmStudio = "LM Studio", llamaCpp = "llama.cpp", mlx = "MLX", apple = "Apple"
        case venice = "Venice"

        /// How Tellurion's local chat reaches it (`tellurion local --provider …`).
        var provider: String {
            switch self {
            case .ollama: return "ollama"
            case .lmStudio: return "lmstudio"
            case .llamaCpp, .mlx: return "openai"
            case .apple: return "apple"
            case .venice: return "venice"
            }
        }

        /// Its memory can be freed from here.
        var canUnload: Bool { self == .ollama || self == .lmStudio }
    }

    let host: Host
    let name: String
    /// On disk, in bytes (Ollama).
    let size: Int64?
    /// "8.0B · Q4_K_M", "llm · 4bit".
    let detail: String
    /// Loaded into memory now.
    var loaded: Bool
    /// Memory it takes while loaded (Ollama), and how much of that is on the GPU.
    var memory: Int64?
    var gpuShare: Double?
    /// Can call tools, which Codex needs. Nil when its host doesn't say (LM Studio).
    var tools: Bool?
    /// A cloud model that answers without refusing.
    var uncensored = false
    /// A cloud model whose host says it stores nothing; if not, its own provider may.
    var isPrivate = true
    var id: String { host.rawValue + "/" + name }

    /// A model on Venice, by the id its API uses (see VeniceAccount).
    static func venice(_ id: String, uncensored: Bool, isPrivate: Bool) -> LocalModel {
        LocalModel(host: .venice, name: id, size: nil, detail: "Cloud", loaded: false, memory: nil, gpuShare: nil,
                   uncensored: uncensored, isPrivate: isPrivate)
    }
}

/// What's installed and loaded in Ollama and LM Studio, and the few things worth doing
/// with it from a terminal: unload, run, pull, remove.
@MainActor
final class LocalModelsModel: ObservableObject {
    enum HostState: Equatable {
        case notInstalled
        /// Installed but its server isn't answering.
        case stopped
        case running(version: String?)
    }

    @Published private(set) var ollama: HostState = .notInstalled
    @Published private(set) var lmStudio: HostState = .notInstalled
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var busy: Set<String> = []
    @Published var error: String?

    /// The one the sidebar and the Local Models window share.
    static let shared = LocalModelsModel()

    /// Downloads in progress: model name → fraction done (nil until Ollama reports sizes).
    @Published private(set) var downloads: [String: Double?] = [:]

    /// What was found on this Mac; `models` adds the starred cloud ones.
    private var onThisMac: [LocalModel] = []
    private var loading = false
    private var watchers = 0
    private var activation: NSObjectProtocol?

    /// This Mac's memory, read once.
    nonisolated static let memory = Int64(ProcessInfo.processInfo.physicalMemory)

    /// Lists the models once when a view first shows them. No polling: the list is checked
    /// again only when something can have changed it (a download or removal here, a local
    /// chat starting or ending, or coming back to Tellurion from another app).
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if on && watchers == 1 { start() } else if watchers == 0 { stop() }
    }

    /// Ollama's address: OLLAMA_HOST like Ollama's own CLI, else its default.
    nonisolated static var ollamaBase: URL { ollamaURL(ProcessInfo.processInfo.environment["OLLAMA_HOST"]) }

    /// Reads OLLAMA_HOST the way Ollama does: "host", "host:port", ":port" or a URL; no port
    /// means 11434, and "0.0.0.0" (listen everywhere) is reached on 127.0.0.1.
    nonisolated static func ollamaURL(_ value: String?) -> URL {
        let fallback = URL(string: "http://127.0.0.1:11434")!
        var text = (value ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return fallback }
        var scheme = "http"
        if let range = text.range(of: "://") {
            scheme = String(text[..<range.lowerBound])
            text = String(text[range.upperBound...])
        }
        text = String(text.prefix { $0 != "/" })
        var host = text, port = scheme == "https" ? "443" : "11434"
        if let colon = text.lastIndex(of: ":"), !text.hasSuffix("]") {
            host = String(text[..<colon])
            port = String(text[text.index(after: colon)...])
        }
        if host.isEmpty || host == "0.0.0.0" || host == "[::]" { host = "127.0.0.1" }
        return URL(string: "\(scheme)://\(host):\(port)") ?? fallback
    }

    nonisolated static let lmStudioBase = URL(string: "http://127.0.0.1:1234")!

    nonisolated static var ollamaBinary: String? {
        ToolPath.find("ollama") ?? ["/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var lmsBinary: String? {
        ToolPath.find("lms") ?? [NSHomeDirectory() + "/.lmstudio/bin/lms", NSHomeDirectory() + "/.cache/lm-studio/bin/lms"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Memory taken by loaded models, in bytes.
    var loadedMemory: Int64 { models.filter(\.loaded).compactMap(\.memory).reduce(0, +) }

    /// One check now, and another each time Tellurion becomes the active app (a model
    /// downloaded or removed in a terminal or Ollama's own app shows up then).
    func start() {
        load()
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    func stop() {
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
    }

    func load() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            async let ollama = Self.readOllama()
            async let studio = Self.readLMStudio()
            async let server = Self.readModelServer()
            let (o, l) = await (ollama, studio)
            guard let self else { return }
            self.loading = false
            self.ollama = o.state
            self.lmStudio = l.state
            self.onThisMac = o.models + l.models + (await server) + Self.appleModels
            self.cloudModelsChanged()
        }
    }

    /// A cloud model was starred, or the account connected or disconnected. Needs no checking.
    func cloudModelsChanged() {
        let models = onThisMac + VeniceAccount.shared.starredModels
        if self.models != models { self.models = models }
    }

    // MARK: Ollama

    nonisolated private static func readOllama() async -> (state: HostState, models: [LocalModel]) {
        guard let version = await getJSON(ollamaBase.appendingPathComponent("api/version")) else {
            let installed = ollamaBinary != nil || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            return (installed ? .stopped : .notInstalled, [])
        }
        let tags = await getJSON(ollamaBase.appendingPathComponent("api/tags"))?["models"] as? [[String: Any]] ?? []
        let running = await getJSON(ollamaBase.appendingPathComponent("api/ps"))?["models"] as? [[String: Any]] ?? []
        var loaded: [String: (Int64, Int64)] = [:]
        for model in running {
            guard let name = model["name"] as? String else { continue }
            loaded[name] = (int64(model["size"]), int64(model["size_vram"]))
        }
        let tools = await ollamaTools(tags)
        let models = tags.compactMap { model -> LocalModel? in
            guard let name = model["name"] as? String else { return nil }
            let details = model["details"] as? [String: Any] ?? [:]
            let detail = [details["parameter_size"] as? String, details["quantization_level"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let memory = loaded[name]
            return LocalModel(host: .ollama, name: name, size: int64(model["size"]), detail: detail, loaded: memory != nil,
                              memory: memory?.0, gpuShare: memory.map { $0.0 > 0 ? Double($0.1) / Double($0.0) : 0 }, tools: tools[name])
        }
        return (.running(version: version["version"] as? String), models.sorted { ($0.loaded ? 0 : 1, $0.name) < ($1.loaded ? 0 : 1, $1.name) })
    }

    /// Whether each model can call tools, by name. Ollama says so per model (`/api/show`, which
    /// reads the model's file), so each is asked once and remembered by its digest.
    nonisolated private static let toolsByDigest = ToolsCache()

    nonisolated private static func ollamaTools(_ tags: [[String: Any]]) async -> [String: Bool] {
        var tools: [String: Bool] = [:]
        await withTaskGroup(of: (String, String, Bool?).self) { group in
            for model in tags {
                guard let name = model["name"] as? String else { continue }
                let digest = model["digest"] as? String ?? name
                if let known = toolsByDigest[digest] {
                    tools[name] = known
                    continue
                }
                group.addTask {
                    let shown = await postJSON(ollamaBase.appendingPathComponent("api/show"), body: ["model": name])
                    return (name, digest, (shown?["capabilities"] as? [String]).map { $0.contains("tools") })
                }
            }
            for await (name, digest, can) in group {
                guard let can else { continue }
                tools[name] = can
                toolsByDigest[digest] = can
            }
        }
        return tools
    }

    // MARK: LM Studio

    nonisolated private static func readLMStudio() async -> (state: HostState, models: [LocalModel]) {
        guard let reply = await getJSON(lmStudioBase.appendingPathComponent("api/v0/models")) else {
            let installed = lmsBinary != nil || FileManager.default.fileExists(atPath: "/Applications/LM Studio.app")
            return (installed ? .stopped : .notInstalled, [])
        }
        let models = (reply["data"] as? [[String: Any]] ?? []).compactMap { model -> LocalModel? in
            // Only models that chat (not embedding models).
            guard let id = model["id"] as? String, ["llm", "vlm"].contains(model["type"] as? String ?? "llm") else { return nil }
            let detail = [model["type"] as? String == "vlm" ? "vision" : nil, model["quantization"] as? String]
                .compactMap { $0 }.joined(separator: " · ")
            return LocalModel(host: .lmStudio, name: id, size: nil, detail: detail,
                              loaded: model["state"] as? String == "loaded", memory: nil, gpuShare: nil)
        }
        return (.running(version: nil), models.sorted { ($0.loaded ? 0 : 1, $0.name) < ($1.loaded ? 0 : 1, $1.name) })
    }

    // MARK: llama.cpp, MLX and Apple

    /// The address llama.cpp's `llama-server` and MLX's `mlx_lm.server` both use by default.
    nonisolated static let modelServerBase = URL(string: "http://127.0.0.1:8080")!

    /// What a llama.cpp or MLX server on 127.0.0.1:8080 is serving, if one is running.
    nonisolated private static func readModelServer() async -> [LocalModel] {
        guard let reply = await getJSON(modelServerBase.appendingPathComponent("v1/models")),
              let data = reply["data"] as? [[String: Any]] else { return [] }
        // llama.cpp answers /props; MLX's server doesn't.
        let host: LocalModel.Host = await getJSON(modelServerBase.appendingPathComponent("props")) != nil ? .llamaCpp : .mlx
        return data.compactMap { model in
            guard let id = model["id"] as? String else { return nil }
            return LocalModel(host: host, name: id, size: nil, detail: "\(host.rawValue) server · 127.0.0.1:8080",
                              loaded: true, memory: nil, gpuShare: nil)
        }
    }

    /// Apple's on-device model, on Macs with Apple Intelligence (checked once).
    nonisolated static let appleModels: [LocalModel] = AppleModelServer.isAvailable
        ? [LocalModel(host: .apple, name: "Apple on-device", size: nil, detail: "Apple Intelligence · built in, nothing to download",
                      loaded: false, memory: nil, gpuShare: nil)]
        : []

    // MARK: Actions

    /// Frees the model's memory now (it loads again on the next request).
    func unload(_ model: LocalModel) {
        busy.insert(model.id)
        error = nil
        Task { [weak self] in
            var failure: String?
            switch model.host {
            case .ollama:
                var request = URLRequest(url: Self.ollamaBase.appendingPathComponent("api/generate"), timeoutInterval: 20)
                request.httpMethod = "POST"
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model.name, "keep_alive": 0])
                let status = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode ?? 0 }
                if status != 200 { failure = "Ollama didn't unload \(model.name)" }
            case .lmStudio:
                if let lms = Self.lmsBinary {
                    let result = await Task.detached { ToolPath.run(lms, ["unload", model.name], in: NSHomeDirectory()) }.value
                    if !result.ok { failure = result.error.isEmpty ? "lms unload failed" : String(result.error.prefix(300)) }
                } else {
                    failure = "Unload it in LM Studio (its lms command isn't installed)"
                }
            case .llamaCpp, .mlx, .apple, .venice:
                break
            }
            let message = failure
            guard let self else { return }
            self.busy.remove(model.id)
            self.error = message
            self.load()
        }
    }

    /// Chats with it in a new tab.
    func run(_ model: LocalModel) {
        switch model.host {
        case .ollama:
            SetupChecks.openTab(running: "\(Self.ollamaBinary.map(AgentTools.shellQuote) ?? "ollama") run \(AgentTools.shellQuote(model.name))")
        case .lmStudio:
            SetupChecks.openTab(running: "\(Self.lmsBinary.map(AgentTools.shellQuote) ?? "lms") chat \(AgentTools.shellQuote(model.name))")
        case .llamaCpp, .mlx, .apple, .venice:
            guard let owner = LocalModelsWindow.frontTerminal else { return }
            LocalModelSessions.openTab(model, from: owner)
        }
    }

    /// Downloads a model in a new tab, where the progress shows.
    func pull(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        SetupChecks.openTab(running: "\(Self.ollamaBinary.map(AgentTools.shellQuote) ?? "ollama") pull \(AgentTools.shellQuote(name))")
    }

    /// Downloads a model through Ollama's API, with its progress in `downloads`; the list is
    /// checked again when it's done.
    func download(_ name: String) {
        guard downloads[name] == nil else { return }
        downloads[name] = .some(nil)
        error = nil
        Task { [weak self] in
            var request = URLRequest(url: Self.ollamaBase.appendingPathComponent("api/pull"), timeoutInterval: 3600)
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
            var failure: String?
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                var last = Date.distantPast
                for try await line in bytes.lines {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let message = event["error"] as? String { failure = message; break }
                    let total = Self.int64(event["total"]), done = Self.int64(event["completed"])
                    // A few updates a second is plenty for a progress bar.
                    guard total > 0, Date().timeIntervalSince(last) > 0.25 else { continue }
                    last = Date()
                    let fraction = Double(done) / Double(total)
                    await MainActor.run { self?.downloads[name] = fraction }
                }
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            await MainActor.run {
                guard let self else { return }
                self.downloads[name] = nil
                if let message { self.error = "Couldn't download \(name): \(message)" }
                self.load()
            }
        }
    }

    /// Deletes an Ollama model from disk.
    func remove(_ model: LocalModel) {
        guard model.host == .ollama else { return }
        busy.insert(model.id)
        error = nil
        Task { [weak self] in
            var request = URLRequest(url: Self.ollamaBase.appendingPathComponent("api/delete"), timeoutInterval: 30)
            request.httpMethod = "DELETE"
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model.name, "name": model.name])
            let status = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode ?? 0 }
            guard let self else { return }
            self.busy.remove(model.id)
            if status != 200 { self.error = "Ollama didn't remove \(model.name)" }
            self.load()
        }
    }

    /// Starts Ollama: its app if installed, else `ollama serve` in a tab.
    func startOllama() {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
        } else if let ollama = Self.ollamaBinary {
            SetupChecks.openTab(running: "\(AgentTools.shellQuote(ollama)) serve")
        }
    }

    /// Starts LM Studio's local server (`lms server start`), or opens the app.
    func startLMStudio() {
        if let lms = Self.lmsBinary {
            SetupChecks.openTab(running: "\(AgentTools.shellQuote(lms)) server start")
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/LM Studio.app"))
        }
    }

    // MARK: Helpers

    nonisolated private static func getJSON(_ url: URL) async -> [String: Any]? {
        let request = URLRequest(url: url, timeoutInterval: 2)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func postJSON(_ url: URL, body: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }
}

/// Which model files can call tools, read from any thread.
private final class ToolsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    subscript(digest: String) -> Bool? {
        get { lock.withLock { values[digest] } }
        set { lock.withLock { values[digest] = newValue } }
    }
}
#endif
