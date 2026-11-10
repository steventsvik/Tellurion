#if os(macOS)
import Foundation

/// The line typed to bring back an agent's saved session. Every place that resumes one
/// builds its line here, so nothing but a real session id is ever typed.
enum AgentResume {
    /// Where the session ran. Codex only; Claude Code has one.
    enum Backend: Equatable {
        /// The agent's own sign-in.
        case plain
        /// Codex on Venice. A model is named on the line when the pane doesn't carry one.
        case venice(model: String?)
        /// Codex on a model on this Mac, by what's known of its host and model.
        case local(provider: String?, model: String?)
    }

    /// The line, with a leading space (it stays out of shell history) and a newline. Nil when
    /// `session` isn't a session id (they're UUIDs) or the agent can't resume: session ids
    /// come from files any program can write, so nothing else is typed.
    static func line(_ agent: VerticalTabAgentKind, session: String, on backend: Backend = .plain) -> String? {
        guard UUID(uuidString: session) != nil else { return nil }
        switch agent {
        case .claude:
            return " claude --resume \(session)\n"
        case .codex:
            switch backend {
            case .plain:
                return " codex resume \(session)\n"
            case .venice(let model):
                let chosen = model.flatMap { VeniceAPI.isValidSlug($0) ? "\(VeniceCodex.modelVariable)=\(AgentTools.shellQuote($0)) " : nil } ?? ""
                return " " + chosen + VeniceCodex.command("resume \(session)") + "\n"
            case .local(let provider, let model):
                return LocalCodex.resumeLine(session, provider: provider, model: model)
            }
        default:
            return nil
        }
    }

    /// The same without the space and the newline, for a caller that presses Enter itself.
    static func command(_ agent: VerticalTabAgentKind, session: String, on backend: Backend = .plain) -> String? {
        line(agent, session: session, on: backend).map { String($0.dropFirst().dropLast()) }
    }
}
#endif
