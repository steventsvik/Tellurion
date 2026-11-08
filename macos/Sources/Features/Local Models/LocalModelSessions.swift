#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// A chat with a model: `tellurion local <model>` typed into a shell runs Tellurion's own chat
/// (agent-hooks/local-chat.py). For a model on this Mac nothing leaves it; a model on Venice goes
/// through VeniceProxy, so the shell never has the key. The chat reports to the sidebar itself,
/// naming its model, so the pane shows its status.
@MainActor
enum LocalModelSessions {
    /// What's typed into the shell: the screen is cleared first, so the pane starts with the
    /// chat rather than the command line (the leading space keeps it out of shell history).
    static func command(_ model: LocalModel) -> String {
        let cli = HookInstaller.binFolder.appendingPathComponent("tellurion").path
        var provider = model.host == .ollama ? "" : " --provider \(model.host.provider)"
        if model.host == .llamaCpp || model.host == .mlx {
            provider += " --base \(LocalModelsModel.modelServerBase.absoluteString)"
        }
        return " clear; \(AgentTools.shellQuote(cli)) local\(provider) \(AgentTools.shellQuote(model.name))"
    }

    /// Opens it below the chat in front, or in a tab (or tile) of its own when there's no chat there.
    static func open(_ model: LocalModel, from owner: BaseTerminalController) {
        if let surface = owner.focusedSurface, VerticalTabsAgents.shared.info(for: surface) != nil {
            open(model, below: surface, in: owner)
        } else {
            openTab(model, from: owner)
        }
    }

    /// Splits the pane and opens it underneath, in the pane's folder.
    static func open(_ model: LocalModel, below surface: Ghostty.SurfaceView, in controller: BaseTerminalController) {
        guard prepare(model) else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = surface.pwd
        config.initialInput = command(model) + "\n"
        controller.newSplit(at: surface, direction: .down, baseConfig: config)
    }

    static func openTab(_ model: LocalModel, from owner: BaseTerminalController) {
        guard prepare(model) else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = owner.focusedSurface?.pwd
        config.initialInput = command(model) + "\n"
        TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config)
    }

    /// Codex, with its usual setup, on a model on this Mac (Ollama or LM Studio): a tab, or a tile
    /// on a board. Nothing leaves the Mac, so it starts where the pane is, like a chat.
    static func openCodex(_ model: LocalModel, from owner: BaseTerminalController) {
        guard model.host == .ollama || model.host == .lmStudio, prepare(model) else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = owner.focusedSurface?.pwd
        config.environmentVariables.merge(LocalCodex.environment(model: model.name, provider: model.host.provider)) { $1 }
        config.initialInput = " " + LocalCodex.command() + "\n"
        TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config)
    }

    /// Codex, with its usual setup, on a Venice model: a tile that stays on it through restarts
    /// on a board, or a tab in a window.
    static func openCodex(_ model: LocalModel, name: String, from owner: BaseTerminalController) {
        if let board = owner as? BoardController {
            board.connect(BoardAccounts.shared.veniceAccount(model: model.name, name: name, isPrivate: model.isPrivate))
            return
        }
        guard prepare(model) else { return }
        guard let folder = VeniceCodex.projectFolder(owner.focusedSurface?.pwd) else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = folder
        config.environmentVariables.merge(VeniceCodex.environment(model: model.name)) { $1 }
        config.initialInput = " " + VeniceCodex.command() + "\n"
        TerminalWindows.newTerminal(owner.ghostty, from: owner, config: config)
    }

    /// The `tellurion` command has to be installed (and current) to launch it.
    /// Apple's model is served by Tellurion itself, so that starts too.
    private static func prepare(_ model: LocalModel) -> Bool {
        do {
            if model.host == .apple { try AppleModelServer.shared.start() }
            if model.host == .venice, try !VeniceAccount.shared.prepareUse(modelName: model.name, isPrivate: model.isPrivate) { return false }
            if HookInstaller.filesState() != .current { try HookInstaller.installFiles() }
            return true
        } catch {
            LocalModelsModel.shared.error = error.localizedDescription
            return false
        }
    }
}

/// Starting Codex on a model on this Mac: the variables a pane carries, and the lines typed into
/// it. Typed lines name `tellurion local codex` outright, so they work whatever the shell; in zsh a
/// plain `codex` in such a pane goes the same way (see ghostty-extreme.zsh). The pane's backend
/// variable is the one Venice panes carry, with "local" in it.
enum LocalCodex {
    static let backend = "local"
    static let modelVariable = "TELLURION_LOCAL_MODEL"
    static let providerVariable = "TELLURION_LOCAL_PROVIDER"
    /// What Codex records as the provider in a session on a model here: its own names for them.
    static let providers: Set<String> = ["ollama", "lmstudio"]

    static func environment(model: String, provider: String) -> [String: String] {
        [VeniceCodex.backendVariable: backend, modelVariable: model, providerVariable: provider]
    }

    /// Model names as Ollama and LM Studio write them ("publisher/model:tag"). A name from a
    /// file isn't typed into a shell unchecked.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.][A-Za-z0-9_.:/-]{0,199}$"#, options: .regularExpression) != nil
    }

    private static var cli: String { AgentTools.shellQuote(HookInstaller.binFolder.appendingPathComponent("tellurion").path) }

    /// The command, with Codex's own arguments after it: "resume <id>".
    static func command(_ arguments: String = "") -> String {
        cli + " local codex" + (arguments.isEmpty ? "" : " " + arguments)
    }

    /// Resumes a session (its id already quoted) on the model and provider it ran on. Without a
    /// known model, `tellurion local codex` picks one that's here; it never goes to another provider.
    static func resumeLine(_ id: String, provider: String?, model: String?) -> String {
        var chosen = ""
        if let provider, providers.contains(provider) { chosen += "\(providerVariable)=\(provider) " }
        if let model, isValidName(model) { chosen += "\(modelVariable)=\(AgentTools.shellQuote(model)) " }
        return " " + chosen + command("resume \(id)") + "\n"
    }

    /// What Codex recorded for a session, when it ran on a model on this Mac: its host, and the
    /// model if a turn named one. Nil for a session on any other provider, or one that can't be read.
    static func session(_ id: String) -> (provider: String, model: String?)? {
        guard let path = CodexTracking.transcript(session: id), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The start of the file has what's needed; a long session isn't read whole.
        guard let data = try? handle.read(upToCount: 256 * 1024), let text = String(data: data, encoding: .utf8) else { return nil }
        var provider: String?
        var model: String?
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else { continue }
            switch record["type"] as? String {
            case "session_meta": provider = payload["model_provider"] as? String
            case "turn_context":
                if let name = payload["model"] as? String, !name.isEmpty { model = name }
            default: break
            }
            if provider != nil, model != nil { break }
        }
        guard let provider, providers.contains(provider) else { return nil }
        return (provider, model)
    }
}

/// What a Codex session on a model on this Mac may use beyond coding tools: a file
/// `tellurion local codex` looks for, so every way of starting a session agrees.
enum LocalCodexOption: String {
    case webSearch = "use-web-search"

    private var file: URL { AgentTools.root.appendingPathComponent("local/\(rawValue)") }

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

extension UTType {
    /// A local model ("<host>\t<name>"), dragged from the sidebar onto a terminal pane.
    static let tellurionLocalModel = UTType(exportedAs: "com.steventsvik.tellurion.localModel")
}
#endif
