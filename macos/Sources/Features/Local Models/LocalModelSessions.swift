#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// A chat with a model on this Mac, through Ollama: `tellurion local <model>` typed into a
/// shell runs Tellurion's own chat (agent-hooks/local-chat.py). Nothing leaves the Mac. The
/// chat reports to the sidebar itself, naming its model, so the pane shows its status.
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

    /// The `tellurion` command has to be installed (and current) to launch it.
    /// Apple's model is served by Tellurion itself, so that starts too.
    private static func prepare(_ model: LocalModel) -> Bool {
        do {
            if model.host == .apple { try AppleModelServer.shared.start() }
            if HookInstaller.filesState() != .current { try HookInstaller.installFiles() }
            return true
        } catch {
            LocalModelsModel.shared.error = error.localizedDescription
            return false
        }
    }
}

extension UTType {
    /// A local model ("<host>\t<name>"), dragged from the sidebar onto a terminal pane.
    static let tellurionLocalModel = UTType(exportedAs: "com.steventsvik.tellurion.localModel")
}
#endif
