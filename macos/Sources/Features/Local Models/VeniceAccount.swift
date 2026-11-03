#if os(macOS)
import AppKit
import Combine
import Security

/// The Venice key, in the login keychain only. Each app (a test copy has its own bundle id)
/// keeps its own.
enum VeniceKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.steventsvik.ghostty-extreme") + ".venice",
         kSecAttrAccount as String: "api-key"]
    }

    /// Whether there's a key, without reading it (which can ask the user).
    static var hasKey: Bool {
        var attributes = query
        attributes[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "Tellurion: Venice API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}

/// What a Codex session on Venice may use beyond coding tools. Both are off unless chosen, and
/// each is a file `tellurion venice codex` looks for, so every way of starting a session agrees.
enum VeniceCodexOption: String {
    case memory = "use-codex-memory"
    case computerUse = "allow-computer-use"
    case secretFiles = "allow-secret-files"

    private var file: URL { AgentTools.root.appendingPathComponent("venice/\(rawValue)") }

    var isOn: Bool { FileManager.default.fileExists(atPath: file.path) }

    func set(_ on: Bool) throws {
        guard on != isOn else { return }
        if on {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        } else {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// A connected Venice account: its models, which are starred for the sidebar, and the proxy
/// agents and chats reach it through. The list is public, so reading it needs no key; it's read
/// when the Local Models window shows it and on Refresh, never in the background.
@MainActor
final class VeniceAccount: ObservableObject {
    static let shared = VeniceAccount()

    struct Star: Codable, Equatable {
        var uncensored: Bool
        var isPrivate: Bool
        var worksInCodex: Bool
    }

    @Published private(set) var connected = VeniceKeychain.hasKey
    @Published private(set) var models: [VeniceAPI.Model] = []
    @Published private(set) var busy = false
    @Published var error: String?
    /// Today's, from the balance Venice reports.
    @Published private(set) var spending = VeniceSpendMeter.shared.today
    /// Starred models, which show in the sidebar.
    @Published private(set) var starred: [String: Star] = [:]

    private static let starredKey = "VeniceStarredModels"
    private static let acknowledgedKey = "VeniceNoticeAcknowledged"

    /// Where everything goes. Test copies can point this at a local server.
    nonisolated static var base: URL {
        #if TELLURION_TEST_HOOKS
        if let url = TestHooks.veniceServer.flatMap(URL.init(string:)) { return url }
        #endif
        return VeniceAPI.base
    }

    nonisolated static var proxyInfoFile: URL {
        URL(fileURLWithPath: HookInstaller.home + "/.ghostty-extreme/venice-proxy.json")
    }

    private let proxy = VeniceProxy(upstream: VeniceAccount.base, infoFile: VeniceAccount.proxyInfoFile) { VeniceKeychain.read() }
    private static let log = StoredFile.logger("Venice")

    private init() {
        VeniceSpendMeter.shared.onChange = { [weak self] spending in
            Task { @MainActor in self?.spending = spending }
        }
        if let data = UserDefaults.standard.data(forKey: Self.starredKey),
           let saved = try? JSONDecoder().decode([String: Star].self, from: data) {
            starred = saved
        }
    }

    /// Agents on Venice can be started from any terminal once the app is open. Doesn't read the
    /// keychain until the first request; with no account, does nothing.
    func startAtLaunch() {
        guard connected else { return }
        do {
            try proxy.start()
        } catch {
            Self.log.error("Couldn't start the connection to Venice: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Connecting

    /// Checks the key against the server, and keeps it only if the server takes it.
    func connect(key typed: String) {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VeniceAPI.isValidKey(key) else {
            error = "That doesn't look like a Venice API key."
            return
        }
        busy = true
        error = nil
        Task { [weak self] in
            let problem = await Self.checkKey(key)
            guard let self else { return }
            self.busy = false
            if let problem {
                self.error = problem
                return
            }
            guard VeniceKeychain.save(key) else {
                self.error = "Couldn't save the key in your keychain."
                return
            }
            self.connected = true
            self.startAtLaunch()
            self.refresh()
            LocalModelsModel.shared.cloudModelsChanged()
        }
    }

    func disconnect() {
        VeniceKeychain.delete()
        proxy.stop()
        connected = false
        error = nil
        LocalModelsModel.shared.cloudModelsChanged()
    }

    nonisolated private static func checkKey(_ key: String) async -> String? {
        var request = URLRequest(url: base.appendingPathComponent(VeniceAPI.keyCheckPath), timeoutInterval: 20)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? nil : VeniceAPI.connectionProblem(status: status)
        } catch {
            return "Couldn't reach Venice: \(error.localizedDescription)"
        }
    }

    // MARK: The list

    func refresh() {
        guard !busy else { return }
        busy = true
        Task { [weak self] in
            let reply = await Self.fetchModels()
            guard let self else { return }
            self.busy = false
            if let reply {
                self.models = VeniceAPI.sorted(reply)
                self.error = nil
            } else {
                self.error = "Couldn't read Venice's model list. Check your connection and refresh."
            }
        }
    }

    nonisolated private static func fetchModels() async -> [VeniceAPI.Model]? {
        guard var parts = URLComponents(url: base.appendingPathComponent(VeniceAPI.modelsPath), resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "type", value: "text")]
        guard let url = parts.url, let (data, response) = try? await URLSession(configuration: .ephemeral).data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return VeniceAPI.parseModels(data)
    }

    // MARK: Stars

    var starredModels: [LocalModel] {
        guard connected else { return [] }
        return starred.keys.sorted().map { id in
            let star = starred[id]
            return LocalModel(host: .venice, name: id, size: nil, detail: "Cloud", loaded: false, memory: nil, gpuShare: nil,
                              uncensored: star?.uncensored ?? false, isPrivate: star?.isPrivate ?? false)
        }
    }

    func toggleStar(_ model: VeniceAPI.Model) {
        if starred[model.id] != nil {
            starred[model.id] = nil
        } else {
            starred[model.id] = Star(uncensored: model.uncensored, isPrivate: model.isPrivate, worksInCodex: model.worksInCodex)
        }
        if let data = try? JSONEncoder().encode(starred) { UserDefaults.standard.set(data, forKey: Self.starredKey) }
        LocalModelsModel.shared.cloudModelsChanged()
    }

    // MARK: Using a model

    /// Before anything goes to Venice: says what that means, and starts the proxy. False if it
    /// can't go ahead.
    func prepareUse(modelName: String, isPrivate: Bool) throws -> Bool {
        guard connected else {
            throw VeniceProxy.Failure(message: "Connect your Venice account first, in Tools → Local models.")
        }
        guard confirmFirstUse(), isPrivate || confirmAnonymized(modelName) else { return false }
        try proxy.start()
        if HookInstaller.filesState() != .current { try HookInstaller.installFiles() }
        return true
    }

    private func confirmFirstUse() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.acknowledgedKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "Venice runs on its servers, not on this Mac"
        alert.informativeText = """
        • Your prompts go to Venice, and so does what an agent reads while it works: your code, and the output of commands it runs.
        • For models marked Private, Venice and its partners say nothing is stored. Tellurion can't verify that.
        • It's billed to your Venice account. Your Claude or ChatGPT subscription isn't used.

        • Your Codex memory, computer use and secret files like .env stay out of reach unless you turn them on in Local models. It can still read your other files.
        • It stops for the day at $\(String(format: "%.2f", VeniceSpendMeter.shared.limit)) spent, which you can change there.

        Commands an agent runs still run on this Mac, under its usual sandbox and approvals.
        """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: Self.acknowledgedKey)
        return true
    }

    /// Every time: this differs model by model, and it's easy to pick one without looking.
    private func confirmAnonymized(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(name) is an Anonymized model"
        alert.informativeText = "Venice strips your identity, but this model's own provider sees what's sent, including any code an agent reads, and may store it. Choose a model marked Private to avoid this."
        alert.addButton(withTitle: "Use It Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Starting Codex on Venice: the variables a pane carries, and the lines typed into it. Typed lines
/// name `tellurion venice codex` outright, so they work whatever the shell; in zsh a plain `codex`
/// in such a pane goes the same way (see ghostty-extreme.zsh).
enum VeniceCodex {
    static let backendVariable = "TELLURION_CODEX_BACKEND"
    static let modelVariable = "TELLURION_VENICE_MODEL"
    /// What `tellurion venice codex` names the provider, which Codex records in each session.
    static let provider = "venice"

    /// Resumes a session (its id already quoted) on Venice.
    static func resumeLine(_ id: String) -> String {
        " " + command("resume \(id)") + "\n"
    }

    /// What a tile whose Venice model was removed comes back to. Nothing starts: its usual
    /// sign-in is another provider, and the work shouldn't go there without being asked.
    static let removedAccountLine = #" printf '%s\n' "This tile's Venice model was removed, so Codex wasn't started. Choose an account in the tile's menu.""# + "\n"

    static func environment(model: String) -> [String: String] {
        [backendVariable: "venice", modelVariable: model]
    }

    /// A session sends what it reads to Venice, so it doesn't start where that could be anything.
    static func needsFolder(_ folder: String?, home: String) -> Bool {
        guard let folder, !folder.isEmpty else { return true }
        let path = (folder as NSString).standardizingPath
        return path == "/" || path == (home as NSString).standardizingPath
    }

    /// The folder to start a session in: this one, or the one asked for. Nil if that's cancelled.
    @MainActor
    static func projectFolder(_ current: String?) -> String? {
        guard needsFolder(current, home: NSHomeDirectory()) else { return current }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Start Codex Here"
        panel.message = "Codex on Venice sends what it reads to Venice. Choose the project to work in."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private static var cli: String { AgentTools.shellQuote(HookInstaller.binFolder.appendingPathComponent("tellurion").path) }

    /// The command, with Codex's own arguments after it: "resume <id>".
    static func command(_ arguments: String = "") -> String {
        cli + " venice codex" + (arguments.isEmpty ? "" : " " + arguments)
    }

    /// A line typed into a new pane on Venice: anything that starts plain Codex goes through
    /// Tellurion instead, whichever shell it lands in.
    static func adapted(_ line: String) -> String {
        let trimmed = line.drop { $0 == " " }
        guard trimmed == "codex\n" || trimmed.hasPrefix("codex ") else { return line }
        let arguments = trimmed.dropFirst("codex".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return " " + command(arguments) + "\n"
    }

    static func adapt(_ config: inout Ghostty.SurfaceConfiguration) {
        guard config.environmentVariables[backendVariable] == "venice", let line = config.initialInput else { return }
        config.initialInput = adapted(line)
    }

    /// What's typed to take a running pane's shell to an account: it clears what the last one
    /// set, so a session never stays on the wrong provider.
    static func switchLine(to account: BoardAccount?, provider: BoardAccount.Provider) -> String {
        guard provider == .codex else {
            let line = account.map { "export \(provider.variable)=\(AgentTools.shellQuote($0.folder.path))" } ?? "unset \(provider.variable)"
            return line + "; claude"
        }
        if let model = account?.veniceModel {
            return "unset \(provider.variable); export \(backendVariable)=venice \(modelVariable)=\(AgentTools.shellQuote(model)); " + command()
        }
        let clear = "unset \(backendVariable) \(modelVariable)"
        guard let account else { return clear + " \(provider.variable); codex" }
        return clear + "; export \(provider.variable)=\(AgentTools.shellQuote(account.folder.path)); codex"
    }
}
#endif
