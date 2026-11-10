#if os(macOS)
import Foundation

/// A short piece of text Tellurion asks a model for: a commit message from a diff, a title, a
/// one-paragraph summary, a classification. Short input, short output, nothing to look up.
struct SmallJob {
    enum Kind: String, Codable, CaseIterable {
        case commitMessage, title, summary, classify

        /// Room to leave for the answer, in tokens.
        var outputTokens: Int {
            switch self {
            case .commitMessage: return 220
            case .title: return 40
            case .summary: return 300
            case .classify: return 20
            }
        }
    }

    /// The path the job took before small jobs existed, usually your own Claude Code or Codex.
    /// Calls back once, on any queue.
    typealias Fallback = (@escaping (Result<String, Error>) -> Void) -> Void

    var kind: Kind
    /// What to write and how (the system prompt).
    var instructions: String
    /// What to write it from.
    var prompt: String
    /// For `classify`: the answers it may give.
    var choices: [String]
    /// Whose path `fallback` is, as shown in Settings: "Claude Code".
    var fallbackName: String
    /// Cleans an answer up and says whether it will do.
    var validator: (String) -> SmallJobCheck
    var fallback: Fallback

    /// `validator` nil: the usual checks for the kind.
    init(kind: Kind, instructions: String, prompt: String, choices: [String] = [], fallbackName: String,
         validator: ((String) -> SmallJobCheck)? = nil, fallback: @escaping Fallback) {
        self.kind = kind
        self.instructions = instructions
        self.prompt = prompt
        self.choices = choices
        self.fallbackName = fallbackName
        self.validator = validator ?? { SmallJobText.check(kind, $0, parts: [instructions, prompt], choices: choices) }
        self.fallback = fallback
    }
}

/// What a validator made of an answer: the text to use, or why it won't do.
enum SmallJobCheck: Equatable {
    case ok(String)
    case rejected(String)
}

/// How one job went. Kept in the log: no prompt and no answer, only where it ran.
struct SmallJobOutcome: Codable, Equatable, Identifiable {
    enum Route: Codable, Equatable {
        /// A model on this Mac wrote it.
        case local(model: String)
        /// A model on this Mac was tried and the job was sent on.
        case escalated(reason: String)
        /// Nothing on this Mac was tried.
        case fallbackOnly
    }

    var id = UUID()
    var kind: SmallJob.Kind
    var route: Route
    /// The model on this Mac that wrote it or was tried.
    var model: String?
    /// Where it went instead: "Claude Code".
    var fallbackName: String
    /// Why nothing on this Mac was tried.
    var note: String?
    var duration: TimeInterval
    var date = Date()

    var isLocal: Bool {
        if case .local = route { return true }
        return false
    }

    /// Why it was sent on, if it was.
    var reason: String? {
        switch route {
        case .local: return nil
        case .escalated(let reason): return reason
        case .fallbackOnly: return note
        }
    }
}
#endif
