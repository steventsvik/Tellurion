#if os(macOS)
import Foundation

/// The agent CLIs a board can start, and how. Agents are typed into a normal login shell in
/// the tile, so they run with your own PATH, logins and settings.
struct BoardAgent: Identifiable, Hashable {
    let kind: VerticalTabAgentKind
    /// The executable on PATH.
    let binary: String
    /// The flag that starts an interactive session with a first prompt, if the CLI has one.
    /// Claude Code and Codex take the prompt as their first argument.
    let promptFlag: String?
    let takesPrompt: Bool

    var id: String { binary }

    static let catalog: [BoardAgent] = [
        BoardAgent(kind: .claude, binary: "claude", promptFlag: nil, takesPrompt: true),
        BoardAgent(kind: .codex, binary: "codex", promptFlag: nil, takesPrompt: true),
        BoardAgent(kind: .gemini, binary: "gemini", promptFlag: "-i", takesPrompt: true),
        BoardAgent(kind: .qwen, binary: "qwen", promptFlag: "-i", takesPrompt: true),
        BoardAgent(kind: .opencode, binary: "opencode", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .amp, binary: "amp", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .copilot, binary: "copilot", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .cursor, binary: "cursor-agent", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .droid, binary: "droid", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .goose, binary: "goose", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .kimi, binary: "kimi", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .mistral, binary: "vibe", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .aider, binary: "aider", promptFlag: nil, takesPrompt: false),
        BoardAgent(kind: .crush, binary: "crush", promptFlag: nil, takesPrompt: false),
    ]

    static func forKind(_ kind: VerticalTabAgentKind) -> BoardAgent? {
        catalog.first { $0.kind == kind }
    }

    /// The agents installed on this Mac. Looks on the login shell's PATH, so call it off the
    /// main thread.
    static func installed() -> [BoardAgent] {
        catalog.filter { ToolPath.find($0.binary) != nil }
    }

    /// The shell line that starts the agent, with `prompt` as its first message when it takes one.
    func command(prompt: String?) -> String {
        guard let prompt, !prompt.isEmpty, takesPrompt,
              let file = AgentTools.writePrompt(prompt, folder: "board", name: UUID().uuidString) else {
            return binary + "\n"
        }
        if promptFlag == nil, kind == .claude || kind == .codex {
            return AgentTools.agentCommand(kind, promptFile: file)
        }
        let flag = promptFlag.map { $0 + " " } ?? ""
        return "\(binary) \(flag)\"$(cat \(AgentTools.shellQuote(file.path)))\"\n"
    }

    /// The line that resumes a saved session, or starts the agent again when it can't resume.
    static func resumeCommand(for tile: BoardTile) -> String? {
        let kind = tile.agent.map(VerticalTabAgentKind.init(id:))
        if let session = tile.session, UUID(uuidString: session) != nil {
            switch kind {
            case .claude: return " claude --resume \(session)\n"
            case .codex: return " codex resume \(session)\n"
            default: break
            }
        }
        return tile.command
    }
}
#endif
