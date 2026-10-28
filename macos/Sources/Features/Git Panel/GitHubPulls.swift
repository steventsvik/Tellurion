#if os(macOS)
import AppKit
import Combine

/// A branch's pull request and its checks, from the GitHub CLI.
struct PullRequestInfo: Equatable {
    enum State: String { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

    struct Check: Equatable, Identifiable {
        enum Result { case passed, failed, pending, skipped }
        let name: String
        let result: Result
        let url: URL?
        var id: String { name + (url?.absoluteString ?? "") }
    }

    let number: Int
    let title: String
    let state: State
    let isDraft: Bool
    let url: URL?
    let reviewDecision: String?
    let checks: [Check]

    var failed: Int { checks.filter { $0.result == .failed }.count }
    var pending: Int { checks.filter { $0.result == .pending }.count }
    var passed: Int { checks.filter { $0.result == .passed }.count }

    /// One word for the badge.
    var summary: String {
        switch state {
        case .merged: return "merged"
        case .closed: return "closed"
        case .open:
            if failed > 0 { return isDraft ? "draft · \(failed) failing" : "\(failed) failing" }
            if pending > 0 { return isDraft ? "draft · running" : "running" }
            if isDraft { return "draft" }
            if !checks.isEmpty { return "passing" }
            return "open"
        }
    }
}

/// Pull requests for the branches tabs are on. Asks `gh` only when it's installed and
/// signed in, only for repositories with a GitHub remote, at most once a minute per branch
/// (plus when an agent finishes a turn or the Git panel opens).
final class GitHubPulls: ObservableObject {
    static let shared = GitHubPulls()

    enum Lookup: Equatable {
        case none
        case found(PullRequestInfo)
    }

    /// Keyed by "<repo root>#<branch>".
    @Published private(set) var results: [String: Lookup] = [:]
    /// Nil until checked; false when gh is missing or signed out.
    @Published private(set) var available: Bool?

    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private var gh: String?
    private var checkedAuthAt: Date?
    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.github", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private static let maxAge: TimeInterval = 60

    private init() {
        // A finished turn often means a push: look again shortly after.
        NotificationCenter.default.publisher(for: VerticalTabsAgents.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let surface = note.object as? Ghostty.SurfaceView,
                      VerticalTabsAgents.shared.info(for: surface)?.activity == .done,
                      let root = VerticalTabsGit.shared.root(for: surface.pwd),
                      let branch = VerticalTabsGit.shared.info(for: surface.pwd)?.branch else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.fetch(root: root, branch: branch, force: true) }
            }
            .store(in: &cancellables)
    }

    static func key(_ root: String, _ branch: String) -> String { root + "#" + branch }

    func pull(root: String?, branch: String?) -> PullRequestInfo? {
        guard let root, let branch, case .found(let info) = results[Self.key(root, branch)] else { return nil }
        return info
    }

    /// Fetches if the answer is missing or older than a minute (or `force`).
    func fetch(root: String, branch: String, force: Bool = false) {
        guard ExtremeSettings.isOn(.git), available != false || force else { return }
        let key = Self.key(root, branch)
        guard !inFlight.contains(key) else { return }
        if !force, let at = fetchedAt[key], Date().timeIntervalSince(at) < Self.maxAge { return }
        inFlight.insert(key)
        fetchedAt[key] = Date()
        let checkAuth = checkedAuthAt.map { Date().timeIntervalSince($0) > 600 } ?? true
        queue.async { [weak self] in
            guard let self else { return }
            if checkAuth {
                let gh = SetupChecks.locate("gh")
                let signedIn = gh.map { Self.run($0, ["auth", "status"], in: root).status == 0 } ?? false
                DispatchQueue.main.async {
                    self.gh = gh
                    self.checkedAuthAt = Date()
                    if self.available != signedIn { self.available = signedIn }
                }
                guard signedIn, gh != nil else {
                    DispatchQueue.main.async { self.inFlight.remove(key) }
                    return
                }
            }
            let ghPath = checkAuth ? SetupChecks.locate("gh") : self.gh
            guard let ghPath, Self.hasGitHubRemote(root) else {
                DispatchQueue.main.async { self.inFlight.remove(key) }
                return
            }
            let result = Self.run(ghPath, ["pr", "view", branch, "--json",
                                           "number,title,state,isDraft,url,reviewDecision,statusCheckRollup"], in: root)
            let lookup: Lookup? = result.status == 0 ? Self.parse(result.output).map(Lookup.found)
                : result.error.contains("no pull requests found") ? Lookup.none : nil
            DispatchQueue.main.async {
                self.inFlight.remove(key)
                if let lookup, self.results[key] != lookup { self.results[key] = lookup }
            }
        }
    }

    /// Opens the GitHub page to create a pull request for the branch.
    /// `branch` names the branch when git has none checked out, as in a jj repository.
    func createPullRequest(root: String, branch: String? = nil) {
        queue.async {
            guard let gh = SetupChecks.locate("gh") else { return }
            _ = Self.run(gh, ["pr", "create", "--web"] + (branch.map { ["--head", $0] } ?? []), in: root)
        }
    }

    // MARK: Helpers

    private static func hasGitHubRemote(_ root: String) -> Bool {
        AgentTools.git(["remote", "-v"], in: root).output.contains("github.com")
    }

    static func parse(_ json: String) -> PullRequestInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let number = object["number"] as? Int else { return nil }
        // Re-runs leave the earlier attempts in the list: keep each check's latest run.
        var latest: [String: [String: Any]] = [:]
        var order: [String] = []
        for item in object["statusCheckRollup"] as? [[String: Any]] ?? [] {
            let name = [item["workflowName"] as? String, item["name"] as? String ?? item["context"] as? String]
                .compactMap { $0 }.joined(separator: " · ")
            let started = item["startedAt"] as? String ?? item["createdAt"] as? String ?? ""
            if let existing = latest[name] {
                if started > (existing["startedAt"] as? String ?? existing["createdAt"] as? String ?? "") { latest[name] = item }
            } else {
                latest[name] = item
                order.append(name)
            }
        }
        let rollup = order.compactMap { latest[$0] }
        let checks = rollup.map { item -> PullRequestInfo.Check in
            let result: PullRequestInfo.Check.Result
            if item["__typename"] as? String == "StatusContext" {
                switch item["state"] as? String {
                case "SUCCESS": result = .passed
                case "FAILURE", "ERROR": result = .failed
                default: result = .pending
                }
                return .init(name: item["context"] as? String ?? "status", result: result,
                             url: (item["targetUrl"] as? String).flatMap(URL.init(string:)))
            }
            if item["status"] as? String != "COMPLETED" {
                result = .pending
            } else {
                switch item["conclusion"] as? String {
                case "SUCCESS": result = .passed
                case "NEUTRAL", "SKIPPED": result = .skipped
                default: result = .failed
                }
            }
            let workflow = item["workflowName"] as? String
            let name = item["name"] as? String ?? "check"
            return .init(name: workflow.map { "\($0) · \(name)" } ?? name, result: result,
                         url: (item["detailsUrl"] as? String).flatMap(URL.init(string:)))
        }
        return PullRequestInfo(
            number: number,
            title: object["title"] as? String ?? "",
            state: PullRequestInfo.State(rawValue: object["state"] as? String ?? "") ?? .open,
            isDraft: object["isDraft"] as? Bool ?? false,
            url: (object["url"] as? String).flatMap(URL.init(string:)),
            reviewDecision: object["reviewDecision"] as? String,
            checks: checks)
    }

    private static func run(_ path: String, _ args: [String], in directory: String) -> AgentTools.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        // gh needs git; the app's PATH is short.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = EventToken.scrubbed(environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return AgentTools.Result(status: -1, output: "", error: "\(error)") }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return AgentTools.Result(status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
                                 error: String(decoding: errData, as: UTF8.self))
    }
}
#endif
