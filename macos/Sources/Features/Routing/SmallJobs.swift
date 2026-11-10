#if os(macOS)
import Foundation

/// Sends Tellurion's small jobs to a model on this Mac when one can take them, and on to the
/// path they'd have taken anyway (your Claude Code or Codex) when it can't or its answer won't
/// do. Off unless you turn it on, and then a job goes nowhere its own path wouldn't send it.
final class SmallJobs {
    static let shared = SmallJobs()

    /// The model picked in Settings, as `SmallJobModel.id`. Empty: Automatic.
    static let modelKey = "SmallJobs.model"

    /// How long a model may take: one that's in memory, and one that has to load first.
    struct Limits {
        var loaded: TimeInterval = 30
        var loading: TimeInterval = 120
    }

    private let client: SmallJobClient
    private let isOn: () -> Bool
    private let chosen: () -> String?
    private let limits: Limits
    private let record: (SmallJobOutcome) async -> Void

    init(client: SmallJobClient = .live,
         isOn: @escaping () -> Bool = { TellurionSettings.isOn(.smallJobs) },
         chosen: @escaping () -> String? = { UserDefaults.standard.string(forKey: SmallJobs.modelKey) },
         limits: Limits = Limits(),
         record: ((SmallJobOutcome) async -> Void)? = nil) {
        self.client = client
        self.isOn = isOn
        self.chosen = chosen
        self.limits = limits
        self.record = record ?? Self.log
    }

    private static func log(_ outcome: SmallJobOutcome) async {
        await SmallJobLog.shared.record(outcome)
    }

    /// Runs a job and says where it ran. The text is cleaned up and checked either way; it's
    /// text to show or put in a field, never something to run.
    func run(_ job: SmallJob) async -> (result: Result<String, Error>, outcome: SmallJobOutcome) {
        let started = Date()
        // Off: the job takes its own path, and nothing is looked up or logged.
        guard isOn() else {
            let result = await fallback(job)
            return (result, SmallJobOutcome(kind: job.kind, route: .fallbackOnly, fallbackName: job.fallbackName,
                                            duration: Date().timeIntervalSince(started)))
        }
        var outcome = SmallJobOutcome(kind: job.kind, route: .fallbackOnly, fallbackName: job.fallbackName, duration: 0)
        var result: Result<String, Error>?
        let characters = job.instructions.count + job.prompt.count
        switch SmallJobModels.pick(await client.models(), chosen: chosen(), characters: characters, output: job.kind.outputTokens) {
        case .none(let why):
            outcome.note = why
        case .model(let model):
            outcome.model = model.name
            do {
                let answer = try await client.ask(model, instructions: job.instructions, prompt: job.prompt,
                                                  outputTokens: job.kind.outputTokens,
                                                  timeout: model.loaded ? limits.loaded : limits.loading)
                switch job.validator(answer) {
                case .ok(let text):
                    outcome.route = .local(model: model.name)
                    result = .success(text)
                case .rejected(let why):
                    outcome.route = .escalated(reason: why)
                }
            } catch let failure as SmallJobClient.Failure {
                outcome.route = .escalated(reason: failure.reason)
            } catch {
                outcome.route = .escalated(reason: SmallJobClient.Failure.unreachable.reason)
            }
        }
        let final: Result<String, Error>
        if let result { final = result } else { final = await fallback(job) }
        outcome.duration = Date().timeIntervalSince(started)
        await record(outcome)
        return (final, outcome)
    }

    /// The same, calling back on the main queue.
    @discardableResult
    func run(_ job: SmallJob, completion: @escaping (Result<String, Error>, SmallJobOutcome) -> Void) -> Task<Void, Never> {
        Task {
            let (result, outcome) = await run(job)
            await MainActor.run { completion(result, outcome) }
        }
    }

    /// The job's own path. Its answer gets the same cleaning; one that fails the checks is
    /// still used (there's nowhere further to send it), without its control characters.
    private func fallback(_ job: SmallJob) async -> Result<String, Error> {
        let result: Result<String, Error> = await withCheckedContinuation { continuation in
            job.fallback { continuation.resume(returning: $0) }
        }
        return result.flatMap { answer -> Result<String, Error> in
            if case .ok(let text) = job.validator(answer) { return .success(text) }
            let text = SmallJobText.plain(answer).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failure(Unanswered(name: job.fallbackName)) : .success(text)
        }
    }

    struct Unanswered: LocalizedError {
        let name: String
        var errorDescription: String? { "\(name) didn't answer." }
    }
}
#endif
