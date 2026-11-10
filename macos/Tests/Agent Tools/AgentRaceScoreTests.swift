import Foundation
import Testing
@testable import Ghostty

/// The race scoreboard: what kind of task a prompt is, what's remembered of a decided race,
/// the standings worked out from the history, and when it's willing to give advice.
struct AgentRaceScoreTests {
    // MARK: Helpers

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("race-scores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func race(task: String = "Fix the crash on launch", agents: [String] = ["claude", "codex"],
                      created: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> AgentRace {
        var numbers: [String: Int] = [:]
        let contestants = agents.map { agent -> AgentRace.Contestant in
            numbers[agent, default: 0] += 1
            let id = "\(agent)-\(numbers[agent] ?? 1)"
            return AgentRace.Contestant(id: id, agent: agent, worktree: "/tmp/races/app/\(id)", branch: "race/x/\(id)", baseline: "abc")
        }
        return AgentRace(id: "app-20250101-120000", task: task, repoRoot: "/tmp/projects/app", directory: "/tmp/races/app",
                         created: created, contestants: contestants)
    }

    /// A decided race between one of each agent in `agents`; `winner` is an agent or nil.
    private func decided(_ n: Int, winner: String?, root: String = "/tmp/projects/app", category: AgentRaceCategory = .bugFix,
                         agents: [String] = ["claude", "codex"], seconds: [String: Double] = [:],
                         models: [String: String] = [:]) -> AgentRaceRecord {
        let entries = agents.map { agent in
            AgentRaceRecord.Entry(id: "\(agent)-1", agent: agent, model: models[agent], backend: nil,
                                  outcome: .finished, seconds: seconds[agent], files: 1, added: 2, removed: 1, checkPassed: nil)
        }
        return AgentRaceRecord(id: "race-\(root)-\(category.rawValue)-\(n)", date: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(n)),
                               root: root, project: (root as NSString).lastPathComponent, title: "Task \(n)",
                               category: category, entries: entries, winner: winner.map { "\($0)-1" })
    }

    /// `wins` races won by Codex and the rest by Claude Code.
    private func history(codex wins: Int, of total: Int, root: String = "/tmp/projects/app",
                         category: AgentRaceCategory = .bugFix) -> [AgentRaceRecord] {
        (0..<total).map { decided($0, winner: $0 < wins ? "codex" : "claude", root: root, category: category) }
    }

    // MARK: Categories

    @Test func tasksAreSortedByTheirWording() {
        let table: [(String, AgentRaceCategory)] = [
            ("Fix the crash when opening an empty file", .bugFix),
            ("The login form doesn't work on Safari, find out why and fix it", .bugFix),
            ("Fix the off-by-one in pagination", .bugFix),
            ("Uploads over 2 GB fail to finish. Fix it.", .bugFix),
            ("Fix the crash when clicking the Save button", .bugFix),
            ("Resolve the deadlock between the sync queue and the writer", .bugFix),
            ("Dates show the wrong timezone in the export", .bugFix),
            ("Fix the crash in the parser and add a test for it", .bugFix),
            ("Add CSV export to the reports page", .feature),
            ("Implement password reset by email", .feature),
            ("Add a button to duplicate a board", .feature),
            ("Let users pin a tab", .feature),
            ("Support for multiple accounts", .feature),
            ("Create a webhook endpoint for Stripe events", .feature),
            ("Refactor the session manager into smaller types", .refactor),
            ("Clean up the networking layer and remove dead code", .refactor),
            ("Rename UserManager to AccountStore everywhere", .refactor),
            ("Extract the date formatting into a helper", .refactor),
            ("Simplify the state machine in Checkout", .refactor),
            ("Migrate the callbacks to async/await", .refactor),
            ("Add tests for the parser", .tests),
            ("Write unit tests for AccountStore", .tests),
            ("Fix the flaky test in LoginTests", .tests),
            ("Increase coverage of the billing module", .tests),
            ("Fix failing tests in CI", .tests),
            ("Update the README with the new install steps", .docs),
            ("Fix typo in README", .docs),
            ("Document the public API of the storage module", .docs),
            ("Add doc comments to every exported function", .docs),
            ("Write the changelog entry for 2.0", .docs),
            ("Fix button alignment on the settings page", .interface),
            ("Add a dark mode toggle to settings", .interface),
            ("Redesign the onboarding screen", .interface),
            ("Increase the padding around cards and use the new font", .interface),
            ("The sidebar text overlaps the icon at narrow widths", .interface),
            ("Fix slow query in the dashboard", .performance),
            ("Speed up app launch", .performance),
            ("Optimize image loading with caching", .performance),
            ("Reduce memory usage of the log viewer", .performance),
            ("Scrolling is laggy with 10k rows", .performance),
            ("Bump eslint to v9", .config),
            ("Upgrade React to 19 and fix what breaks", .config),
            ("Add a GitHub Actions workflow that runs lint", .config),
            ("Update the Dockerfile to use node 22", .config),
            ("Move the API key into an environment variable", .config),
            ("Have a look around and tell me what you think", .other),
            ("", .other),
        ]
        for (task, expected) in table {
            #expect(AgentRaceCategory.classify(task) == expected, "\(task)")
        }
    }

    @Test func wordsOnlyCountWhole() {
        // "prefix" has "fix" in it, "latest" has "test", "address" has "add".
        #expect(AgentRaceCategory.classify("Prefix handling in the importer") == .other)
        #expect(AgentRaceCategory.classify("Use the latest address") == .other)
        #expect(AgentRaceCategory.classify("FIX THE CRASH") == .bugFix)
    }

    @Test func classifyingIsRepeatable() {
        let task = "Fix the flaky test and speed up the suite"
        let first = AgentRaceCategory.classify(task)
        for _ in 0..<5 { #expect(AgentRaceCategory.classify(task) == first) }
    }

    // MARK: Records

    @Test func aTitleIsOneShortLine() {
        #expect(AgentRaceRecord.title(of: "\n  Fix   the\tcrash \nand here is the long story") == "Fix the crash")
        let long = AgentRaceRecord.title(of: String(repeating: "word ", count: 60))
        #expect(long.count == AgentRaceRecord.titleLength)
        #expect(long.hasSuffix("…"))
        #expect(AgentRaceRecord.title(of: " \n ").isEmpty)
    }

    @Test func aRecordHoldsWhatWasKnownWhenTheRaceWasDecided() {
        let race = race(agents: ["claude", "codex", "codex"])
        var first = AgentRaceDiff()
        first.files = [("a.swift", 10, 2), ("b.swift", 5, 0)]
        first.text = "diff --git a/a.swift b/a.swift\n+let secret = 1"
        var second = AgentRaceDiff()
        second.files = [("a.swift", 3, 3)]
        let facts = [
            "claude-1": AgentRaceFacts(activity: .done, since: race.created.addingTimeInterval(240), model: "model-a", checkPassed: true),
            "codex-1": AgentRaceFacts(activity: .working, since: race.created.addingTimeInterval(300), model: "model-b", backend: "venice"),
            "codex-2": AgentRaceFacts(activity: .failed, checkPassed: false),
        ]
        let record = AgentRaceRecord(race: race, category: .performance, winner: "claude-1", facts: facts,
                                     diffs: ["claude-1": first, "codex-1": second], date: race.created.addingTimeInterval(600))
        #expect(record.id == race.id)
        #expect(record.root == "/tmp/projects/app")
        #expect(record.project == "app")
        #expect(record.title == "Fix the crash on launch")
        #expect(record.category == .performance)
        #expect(record.winner == "claude-1")
        #expect(record.entries.map(\.id) == ["claude-1", "codex-1", "codex-2"])
        #expect(record.entries[0] == .init(id: "claude-1", agent: "claude", model: "model-a", backend: nil, outcome: .finished,
                                           seconds: 240, files: 2, added: 15, removed: 2, checkPassed: true))
        #expect(record.entries[1] == .init(id: "codex-1", agent: "codex", model: "model-b", backend: "venice", outcome: .working,
                                           seconds: nil, files: 1, added: 3, removed: 3, checkPassed: nil))
        #expect(record.entries[2] == .init(id: "codex-2", agent: "codex", model: nil, backend: nil, outcome: .failed,
                                           seconds: nil, files: 0, added: 0, removed: 0, checkPassed: false))
        #expect(record.winnerEntry?.name == "Claude Code 1")
    }

    @Test func aContestantNothingIsKnownAboutIsStillListed() {
        let record = AgentRaceRecord(race: race(), category: .other, winner: "codex-1", facts: [:], diffs: [:])
        #expect(record.entries.map(\.outcome) == [.unknown, .unknown])
        #expect(record.entries.allSatisfy { $0.seconds == nil && $0.files == 0 && $0.model == nil })
        // An idle agent that never reported finishing isn't counted as finished.
        let idle = AgentRaceRecord(race: race(), category: .other, winner: nil,
                                   facts: ["claude-1": AgentRaceFacts(activity: .ready), "codex-1": AgentRaceFacts(activity: .needsInput)], diffs: [:])
        #expect(idle.entries.map(\.outcome) == [.unknown, .working])
    }

    @Test func aWinnerHasToBeInTheRace() {
        let record = AgentRaceRecord(race: race(), category: .other, winner: "gemini-1", facts: [:], diffs: [:])
        #expect(record.winner == nil)
    }

    @Test func aRaceWithoutAWinnerCountsOnlyIfSomeoneFinished() {
        let finished = AgentRaceRecord(race: race(), category: .bugFix, winner: nil,
                                       facts: ["codex-1": AgentRaceFacts(activity: .done)], diffs: [:])
        #expect(finished.winner == nil)
        #expect(finished.countsWithoutWinner)
        let unfinished = AgentRaceRecord(race: race(), category: .bugFix, winner: nil,
                                         facts: ["codex-1": AgentRaceFacts(activity: .working), "claude-1": AgentRaceFacts(activity: .failed)], diffs: [:])
        #expect(!unfinished.countsWithoutWinner)
    }

    @Test func theStoredHistoryHasNoPromptBodyOrChanges() throws {
        let race = race(task: "Fix the login crash\nThe customer is Initech and the door code is tangerine")
        var diff = AgentRaceDiff()
        diff.files = [("Sources/Billing/Invoice.swift", 4, 1)]
        diff.text = "+let greeting = \"planted-line\""
        let record = AgentRaceRecord(race: race, category: .bugFix, winner: "claude-1",
                                     facts: ["claude-1": AgentRaceFacts(activity: .done, transcriptPath: "/tmp/transcripts/session.jsonl")],
                                     diffs: ["claude-1": diff])
        let stored = String(decoding: try StoredFile.encoder.encode([record]), as: UTF8.self)
        #expect(stored.contains("Fix the login crash"))
        for leaked in ["tangerine", "Initech", "planted-line", "Invoice.swift", "session.jsonl", "worktree", "race/x"] {
            #expect(!stored.contains(leaked), "\(leaked)")
        }
    }

    @Test func factsComeFromWhatTheAgentReported() {
        var info = VerticalTabAgentInfo(kind: .codex, activity: .done, task: nil, detail: nil, unseen: false)
        info.transcriptPath = "/tmp/transcripts/rollout.jsonl"
        let plain = AgentRaceFacts(info: info, checkPassed: true)
        #expect(plain.activity == .done)
        #expect(plain.since == info.since)
        #expect(plain.model == nil)
        #expect(plain.backend == nil)
        #expect(plain.transcriptPath == "/tmp/transcripts/rollout.jsonl")
        #expect(plain.checkPassed == true)

        info.veniceModel = "qwen3-coder"
        #expect(AgentRaceFacts(info: info, checkPassed: nil).backend == "venice")
        #expect(AgentRaceFacts(info: info, checkPassed: nil).model == "qwen3-coder")
        // Started with the model on its command line: on Venice, model not known here.
        info.veniceModel = ""
        #expect(AgentRaceFacts(info: info, checkPassed: nil).backend == "venice")
        #expect(AgentRaceFacts(info: info, checkPassed: nil).model == nil)

        info.veniceModel = nil
        info.localCodex = .init(provider: "ollama", model: "qwen3:4b")
        #expect(AgentRaceFacts(info: info, checkPassed: nil).backend == "ollama")
        #expect(AgentRaceFacts(info: info, checkPassed: nil).model == "qwen3:4b")

        #expect(AgentRaceFacts(info: nil, checkPassed: nil) == AgentRaceFacts())
    }

    // MARK: Models

    @Test func theModelIsReadFromTheEndOfATranscript() throws {
        let claude = """
        {"type":"user","message":{"role":"user","content":"say \\"model\\":\\"planted\\""}}
        {"type":"assistant","message":{"id":"m1","model":"model-old","content":[]}}
        {"type":"assistant","message":{"id":"m2","model":"model-new","content":[]}}
        {"type":"assistant","message":{"id":"m3","model":"<synthetic>","content":[]}}
        """
        #expect(AgentRaceScores.model(inTranscript: Data(claude.utf8)) == "model-new")

        let codex = """
        {"type":"session_meta","payload":{"id":"s1","model_provider":"openai"}}
        {"type":"turn_context","payload":{"cwd":"/tmp/x","model":"model-c"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"hello"}}
        """
        #expect(AgentRaceScores.model(inTranscript: Data(codex.utf8)) == "model-c")

        // The first line of a tail is usually cut off; it's skipped.
        let cut = "\"model\":\"half\"}}\n" + #"{"type":"turn_context","payload":{"model":"whole"}}"#
        #expect(AgentRaceScores.model(inTranscript: Data(cut.utf8)) == "whole")
        #expect(AgentRaceScores.model(inTranscript: Data("not json\n\n".utf8)) == nil)
        #expect(AgentRaceScores.model(inTranscript: Data()) == nil)
    }

    @Test func theModelIsReadFromATranscriptFile() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let filler = String(repeating: #"{"type":"user","message":{"content":"x"}}"# + "\n", count: 9000)
        try Data((#"{"type":"assistant","message":{"model":"too-early"}}"# + "\n" + filler
                  + #"{"type":"assistant","message":{"model":"model-late"}}"# + "\n").utf8).write(to: file)
        #expect(AgentRaceScores.transcriptModel(at: file.path) == "model-late")
        #expect(AgentRaceScores.transcriptModel(at: root.appendingPathComponent("missing.jsonl").path) == nil)
        let facts = AgentRaceFacts(activity: .done, transcriptPath: file.path).resolvingModel()
        #expect(facts.model == "model-late")
        // A model already known isn't replaced.
        #expect(AgentRaceFacts(model: "given", transcriptPath: file.path).resolvingModel().model == "given")
    }

    @Test func modelNamesAreKeptPlain() {
        #expect(AgentRaceScores.modelName("  gpt-x  ") == "gpt-x")
        #expect(AgentRaceScores.modelName("") == nil)
        #expect(AgentRaceScores.modelName("<synthetic>") == nil)
        #expect(AgentRaceScores.modelName("a\nb") == nil)
        #expect(AgentRaceScores.modelName(String(repeating: "m", count: 81)) == nil)
    }

    // MARK: Standings

    @Test func winsAndRatesAreCountedPerAgent() throws {
        var records = history(codex: 7, of: 9)
        records.append(decided(100, winner: nil))
        let standings = AgentRaceScores.standings(records)
        #expect(standings.map(\.agent) == ["codex", "claude"])
        let codex = try #require(standings.first)
        #expect(codex.wins == 7)
        #expect(codex.races == 10)
        #expect(codex.rate == 0.7)
        #expect(codex.model == nil)
        #expect(standings[1].wins == 2)
        #expect(standings[1].races == 10)
    }

    @Test func standingsFollowTheProjectAndTheCategory() {
        let other = "/tmp/projects/site"
        let records = history(codex: 3, of: 4)
            + history(codex: 0, of: 2, root: other)
            + history(codex: 1, of: 3, category: .docs)
        func codex(root: String?, category: AgentRaceCategory?) -> [Int] {
            AgentRaceScores.standings(records, root: root, category: category).filter { $0.agent == "codex" }.map { [$0.wins, $0.races] }.first ?? []
        }
        #expect(codex(root: nil, category: nil) == [4, 9])
        #expect(codex(root: "/tmp/projects/app", category: nil) == [4, 7])
        #expect(codex(root: "/tmp/projects/app", category: .bugFix) == [3, 4])
        #expect(codex(root: "/tmp/projects/app", category: .docs) == [1, 3])
        #expect(codex(root: other, category: nil) == [0, 2])
        #expect(codex(root: nil, category: .bugFix) == [3, 6])
        #expect(AgentRaceScores.standings(records, root: "/tmp/projects/none").isEmpty)
        #expect(AgentRaceScores.standings(records, root: other, category: .docs).isEmpty)
        #expect(AgentRaceScores.standings([]).isEmpty)
    }

    @Test func aRaceBetweenTheSameAgentSaysNothingAboutAgents() throws {
        let solo = AgentRaceRecord(id: "solo", date: Date(timeIntervalSinceReferenceDate: 1), root: "/tmp/projects/app", project: "app",
                                   title: "t", category: .bugFix, entries: [
                                    .init(id: "claude-1", agent: "claude", model: "model-a", backend: nil, outcome: .finished, seconds: 100, files: 1, added: 1, removed: 0, checkPassed: nil),
                                    .init(id: "claude-2", agent: "claude", model: "model-b", backend: nil, outcome: .finished, seconds: 300, files: 1, added: 1, removed: 0, checkPassed: nil),
                                   ], winner: "claude-2")
        #expect(AgentRaceScores.standings([solo]).isEmpty)
        // But it does compare the two models.
        let models = AgentRaceScores.standings([solo], byModel: true)
        #expect(models.map(\.model) == ["model-b", "model-a"])
        #expect(models.map(\.wins) == [1, 0])
        #expect(models.map(\.races) == [1, 1])
        // Its times still count towards the agent's median once the agent has a standing.
        let standings = AgentRaceScores.standings([solo, decided(1, winner: "claude", seconds: ["claude": 200])])
        let claude = try #require(standings.first { $0.agent == "claude" })
        #expect(claude.races == 1)
        #expect(claude.medianSeconds == 200)
    }

    @Test func twoOfOneAgentInARaceCountOnce() {
        let record = AgentRaceRecord(id: "r", date: Date(timeIntervalSinceReferenceDate: 1), root: "/tmp/projects/app", project: "app",
                                     title: "t", category: .bugFix, entries: [
                                        .init(id: "codex-1", agent: "codex", model: nil, backend: nil, outcome: .finished, seconds: 60, files: 1, added: 1, removed: 0, checkPassed: nil),
                                        .init(id: "codex-2", agent: "codex", model: nil, backend: nil, outcome: .finished, seconds: 120, files: 1, added: 1, removed: 0, checkPassed: nil),
                                        .init(id: "claude-1", agent: "claude", model: nil, backend: nil, outcome: .working, seconds: nil, files: 0, added: 0, removed: 0, checkPassed: nil),
                                     ], winner: "codex-2")
        let standings = AgentRaceScores.standings([record])
        #expect(standings.map(\.agent) == ["codex", "claude"])
        #expect(standings.map(\.races) == [1, 1])
        #expect(standings.map(\.wins) == [1, 0])
        #expect(standings[0].medianSeconds == 90)
        #expect(standings[1].medianSeconds == nil)
        // Without models there's nothing to list per model.
        #expect(AgentRaceScores.standings([record], byModel: true).isEmpty)
    }

    @Test func modelsGetTheirOwnStandings() {
        let records = [
            decided(1, winner: "codex", models: ["codex": "model-c", "claude": "model-a"]),
            decided(2, winner: "codex", models: ["codex": "model-c", "claude": "model-a"]),
            decided(3, winner: "claude", models: ["codex": "model-d"]),
        ]
        let models = AgentRaceScores.standings(records, byModel: true)
        #expect(models.map(\.id) == ["codex/model-c", "claude/model-a", "codex/model-d"])
        #expect(models.map(\.wins) == [2, 0, 0])
        #expect(models.map(\.races) == [2, 2, 1])
    }

    @Test func theMedianIsTheMiddle() {
        #expect(AgentRaceScores.median([]) == nil)
        #expect(AgentRaceScores.median([5]) == 5)
        #expect(AgentRaceScores.median([9, 1, 5]) == 5)
        #expect(AgentRaceScores.median([4, 1, 3, 2]) == 2.5)
        let records = [
            decided(1, winner: "codex", seconds: ["codex": 100, "claude": 400]),
            decided(2, winner: "codex", seconds: ["codex": 300]),
            decided(3, winner: "claude", seconds: ["codex": 200, "claude": 600]),
        ]
        let standings = AgentRaceScores.standings(records)
        #expect(standings.first { $0.agent == "codex" }?.medianSeconds == 200)
        #expect(standings.first { $0.agent == "claude" }?.medianSeconds == 500)
    }

    @Test func durationsReadShort() {
        #expect(AgentRaceScores.duration(45.2) == "45s")
        #expect(AgentRaceScores.duration(250) == "4m")
        #expect(AgentRaceScores.duration(3599) == "59m")
        #expect(AgentRaceScores.duration(3600) == "1h")
        #expect(AgentRaceScores.duration(3900) == "1h 5m")
    }

    // MARK: Advice

    @Test func theLowerBoundAllowsForFewRaces() {
        func bound(_ wins: Int, _ races: Int) -> Double { AgentRaceScores.wilsonLowerBound(wins: wins, of: races) }
        #expect(abs(bound(7, 9) - 0.4526) < 0.001)
        #expect(abs(bound(4, 5) - 0.3755) < 0.001)
        #expect(abs(bound(3, 5) - 0.2307) < 0.001)
        #expect(abs(bound(7, 10) - 0.3968) < 0.001)
        #expect(bound(0, 5) == 0)
        #expect(bound(0, 0) == 0)
        #expect(bound(50, 100) > bound(5, 10))
    }

    @Test func adviceNeedsEnoughRacesInTheProject() throws {
        let root = "/tmp/projects/app"
        // Four races, however one-sided, aren't enough.
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: history(codex: 4, of: 4)) == nil)
        // Five are, when they're clear.
        let advice = try #require(AgentRaceScores.advice(for: .bugFix, root: root, in: history(codex: 4, of: 5)))
        #expect(advice.leader == "codex")
        #expect(advice.wins == 4)
        #expect(advice.races == 5)
        #expect(advice.project == "app")
        #expect(advice.category == .bugFix)
        #expect(advice.lineup == ["codex": 2, "claude": 1])
        #expect(advice.count(.codex) == 2)
        #expect(advice.count(.claude) == 1)
        #expect(advice.count(.gemini) == 0)
        // And not when they're close.
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: history(codex: 3, of: 5)) == nil)
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: history(codex: 2, of: 5)) == nil)
        // It works either way round.
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: history(codex: 1, of: 5))?.leader == "claude")
    }

    @Test func adviceReadsLikeASentence() throws {
        let advice = try #require(AgentRaceScores.advice(for: .bugFix, root: "/tmp/projects/app", in: history(codex: 7, of: 9)))
        #expect(advice.text == "For bug fixes in this project, Codex has won 7 of 9. Race 2 Codex + 1 Claude Code?")
        let overall = try #require(AgentRaceScores.advice(for: .docs, root: nil, in: history(codex: 2, of: 10, category: .docs)))
        #expect(overall.text == "For docs across your projects, Claude Code has won 8 of 10. Race 2 Claude Code + 1 Codex?")
    }

    @Test func adviceIsPerCategory() {
        let root = "/tmp/projects/app"
        let records = history(codex: 5, of: 5) + history(codex: 0, of: 5, category: .refactor)
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: records)?.leader == "codex")
        #expect(AgentRaceScores.advice(for: .refactor, root: root, in: records)?.leader == "claude")
        #expect(AgentRaceScores.advice(for: .tests, root: root, in: records) == nil)
    }

    @Test func withoutEnoughInTheProjectItTakesTenEverywhere() throws {
        let here = "/tmp/projects/app"
        let elsewhere = "/tmp/projects/site"
        // 4 here + 5 elsewhere = 9: not enough.
        let nine = history(codex: 4, of: 4, root: here) + history(codex: 5, of: 5, root: elsewhere)
        #expect(AgentRaceScores.advice(for: .bugFix, root: here, in: nine) == nil)
        #expect(AgentRaceScores.advice(for: .bugFix, root: nil, in: nine) == nil)
        // 4 here + 6 elsewhere = 10, 7 of them Codex's.
        let ten = history(codex: 3, of: 4, root: here) + history(codex: 4, of: 6, root: elsewhere)
        let advice = try #require(AgentRaceScores.advice(for: .bugFix, root: here, in: ten))
        #expect(advice.project == nil)
        #expect(advice.wins == 7)
        #expect(advice.races == 10)
        #expect(AgentRaceScores.advice(for: .bugFix, root: nil, in: ten) == advice)
        #expect(AgentRaceScores.advice(for: .bugFix, root: "/tmp/projects/new", in: ten) == advice)
        // 6 of 10 isn't clear enough.
        let close = history(codex: 3, of: 4, root: here) + history(codex: 3, of: 6, root: elsewhere)
        #expect(AgentRaceScores.advice(for: .bugFix, root: here, in: close) == nil)
    }

    @Test func aProjectWithItsOwnEvidenceIsntOverruledByTheOthers() {
        let here = "/tmp/projects/app"
        // Close here, one-sided everywhere else: no advice for this project.
        let records = history(codex: 3, of: 5, root: here) + history(codex: 20, of: 20, root: "/tmp/projects/site")
        #expect(AgentRaceScores.advice(for: .bugFix, root: here, in: records) == nil)
        #expect(AgentRaceScores.advice(for: .bugFix, root: "/tmp/projects/site", in: records)?.leader == "codex")
    }

    @Test func racesNobodyWonCountAgainstEveryone() {
        let root = "/tmp/projects/app"
        // Codex won 3 of 5 and nobody won the other two: 3 of 5 isn't enough to count on.
        let records = history(codex: 3, of: 3) + [decided(10, winner: nil), decided(11, winner: nil)]
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: records) == nil)
        // 4 of 5 with one nobody won is.
        let clearer = history(codex: 4, of: 4) + [decided(10, winner: nil)]
        #expect(AgentRaceScores.advice(for: .bugFix, root: root, in: clearer)?.wins == 4)
    }

    @Test func racesOfOneAgentArentEvidence() {
        let solo = (0..<12).map { decided($0, winner: "codex", agents: ["codex"]) }
        #expect(AgentRaceScores.advice(for: .bugFix, root: "/tmp/projects/app", in: solo) == nil)
    }

    @Test func adviceIsOnlyForAgentsARaceCanStart() {
        let records = (0..<6).map { decided($0, winner: "gemini", agents: ["gemini", "codex"]) }
        #expect(AgentRaceScores.advice(for: .bugFix, root: "/tmp/projects/app", in: records) == nil)
        let advice = AgentRaceScores.advice(for: .bugFix, root: "/tmp/projects/app", in: records, racers: ["gemini"])
        #expect(advice?.lineup == ["gemini": 2])
    }

    @Test func anEmptyTaskGetsNoAdvice() {
        #expect(AgentRaceScores.advice(forTask: "  \n ", root: "/tmp/projects/app") == nil)
    }

    // MARK: History

    @Test func theHistoryKeepsTheNewest() {
        var records: [AgentRaceRecord] = []
        for n in 0..<(AgentRaceScores.limit + 10) {
            records = AgentRaceScores.adding(decided(n, winner: "codex"), to: records)
        }
        #expect(records.count == AgentRaceScores.limit)
        #expect(records.first?.title == "Task \(AgentRaceScores.limit + 9)")
        #expect(records.last?.title == "Task 10")
        #expect(AgentRaceScores.adding(decided(1, winner: nil), to: [decided(0, winner: nil)], limit: 1).map(\.title) == ["Task 1"])
    }

    @Test func decidingARaceAgainReplacesItsRecord() {
        let first = decided(1, winner: "codex")
        var second = first
        second.winner = "claude-1"
        let records = AgentRaceScores.adding(second, to: AgentRaceScores.adding(first, to: [decided(0, winner: "codex")]))
        #expect(records.count == 2)
        #expect(records.first?.winner == "claude-1")
    }

    @Test func theHistorySurvivesARestart() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/race-scores.json")
        let scores = AgentRaceScores(file: file)
        #expect(scores.records.isEmpty)
        #expect(!scores.isDecided("x"))
        let one = decided(1, winner: "codex", seconds: ["codex": 61.5], models: ["codex": "model-c"])
        let two = decided(2, winner: nil, root: "/tmp/projects/site", category: .docs)
        scores.record(one)
        scores.record(two)
        #expect(scores.isDecided(one.id))

        let again = AgentRaceScores(file: file)
        #expect(again.records == [two, one])

        again.forget(root: "/tmp/projects/site")
        #expect(AgentRaceScores(file: file).records == [one])
        again.forget(root: nil)
        #expect(AgentRaceScores(file: file).records.isEmpty)
    }

    @Test func anUnreadableHistoryIsKeptAside() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("race-scores.json")
        let damaged = Data(#"[{"id":"race-1","title":"Fix th"#.utf8)
        try damaged.write(to: file)

        let scores = AgentRaceScores(file: file)
        #expect(scores.records.isEmpty)
        func copies() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("race-scores.json.unreadable-") }
        }
        let kept = try #require(try copies().first)
        #expect(try Data(contentsOf: root.appendingPathComponent(kept)) == damaged)

        // Saving afterwards doesn't touch the copy.
        scores.record(decided(1, winner: "codex"))
        #expect(AgentRaceScores(file: file).records.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent(kept)) == damaged)
    }

    @Test func oneBadRecordDoesntLoseTheRest() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("race-scores.json")
        let good = decided(1, winner: "codex")
        var text = String(decoding: try StoredFile.encoder.encode([good]), as: UTF8.self)
        text = "[{\"id\":\"from-a-newer-version\",\"category\":\"unheard-of\"}," + text.dropFirst()
        try Data(text.utf8).write(to: file)

        #expect(AgentRaceScores(file: file).records == [good])
        // The file as it was is kept beside it, since the next save drops the bad record.
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("race-scores.json.unreadable-") }
        #expect(copies.count == 1)
    }

    @Test func aHistoryRowSaysWhatEachContestantDid() {
        let entry = AgentRaceRecord.Entry(id: "codex-2", agent: "codex", model: "model-c", backend: "ollama", outcome: .finished,
                                          seconds: 250, files: 3, added: 40, removed: 12, checkPassed: true)
        #expect(AgentRaceScoreboardView.summary(of: entry) == "Codex 2 · model-c · on ollama · 4m · 3 files +40 −12 · check passed")
        let bare = AgentRaceRecord.Entry(id: "claude-1", agent: "claude", model: nil, backend: nil, outcome: .unknown,
                                         seconds: nil, files: 0, added: 0, removed: 0, checkPassed: nil)
        #expect(AgentRaceScoreboardView.summary(of: bare) == "Claude Code 1")
    }
}
