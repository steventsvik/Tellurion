import Foundation
import Testing
@testable import Ghostty

private func scratchFile() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orchestrators-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("orchestrators.json")
}

/// The sidebar's one line about an orchestrator.
struct OrchestratorStatusTests {
    @Test func beforeAnyCommandItIsIdle() {
        let status = OrchestratorStatus()
        #expect(status.line == "Idle")
        #expect(status.tone == .idle)
    }

    @Test func whileItRunsItSaysTheTurnAndWhoIsWorking() {
        var status = OrchestratorStatus(running: true, turn: 3, limit: 12, working: 2, wired: 3)
        #expect(status.line == "Turn 3 of 12 · 2 working")
        #expect(status.tone == .working)
        status.busy = true
        #expect(status.line == "Turn 3 of 12 · thinking")
        status.busy = false
        status.working = 0
        #expect(status.line == "Turn 3 of 12 · waiting")
        status.turn = 0
        #expect(status.line == "Turn 1 of 12 · waiting")
    }

    @Test func aPermissionPromptPutsYouFirst() {
        var status = OrchestratorStatus(running: true, turn: 2, limit: 12, working: 1, needPermission: ["Ada"], wired: 3)
        #expect(status.line == "Waiting on you: Ada needs permission")
        #expect(status.tone == .needsYou)
        status.needPermission = ["Ada", "Otto"]
        #expect(status.line == "Waiting on you: Ada and Otto need permission")
        status.needPermission = ["Ada", "Otto", "Cy"]
        #expect(status.line == "Waiting on you: 3 agents need permission")
    }

    @Test func afterwardsItSaysHowItEnded() {
        #expect(OrchestratorStatus(ending: .stopped).line == "Stopped")
        #expect(OrchestratorStatus(ending: .stopped).tone == .stopped)
        #expect(OrchestratorStatus(ending: .done).line == "Done")
        // Not running: a wired agent's own prompt is on its card, not here.
        #expect(OrchestratorStatus(needPermission: ["Ada"], ending: .stopped).line == "Stopped")
    }
}

/// A project's classic orchestrator: one per project root, what's kept between launches, and
/// wires that go when their panes do.
struct ClassicOrchestratorTests {
    @Test func thereIsOneOrchestratorPerProjectRoot() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        let web = orchestrators.open(root: "/tmp/web")
        let api = orchestrators.open(root: "/tmp/api")
        #expect(web !== api)
        #expect(orchestrators.open(root: "/tmp/web") === web)
        #expect(orchestrators.orchestrator(root: "/tmp/api") === api)
        #expect(orchestrators.orchestrator(root: "/tmp/other") == nil)
        #expect(orchestrators.list.count == 2)
        #expect(web.projectName == "web")
        // Each has its own goal and limit.
        web.setGoal("Ship the form", for: web.id)
        api.setTurns(20)
        #expect(web.team.goal == "Ship the form")
        #expect(api.team.goal == nil)
        #expect(web.brain.limit == BoardTeams.turns)
        #expect(api.brain.limit == 20)
    }

    @Test func goalRolesLimitAndEngineSurviveARelaunch() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ada = UUID(), otto = UUID()
        do {
            let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
            let web = orchestrators.open(root: "/tmp/web")
            web.setGoal("Ship the form", for: web.id)
            web.wire([ada, otto])
            web.setRole("  Reviewer ", for: otto)
            web.setTurns(20)
            web.setEngine(.codex)
            #expect(orchestrators.wired == [ada, otto])
        }
        let relaunched = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        let record = try #require(relaunched.record(root: "/tmp/web"))
        #expect(record.goal == "Ship the form")
        #expect(record.turns == 20)
        #expect(record.engine == "codex")
        #expect(record.members == [.init(pane: ada.uuidString, role: nil), .init(pane: otto.uuidString, role: "Reviewer")])
        #expect(relaunched.list.isEmpty)

        let web = relaunched.open(root: "/tmp/web")
        #expect(web.team.goal == "Ship the form")
        #expect(web.brain.limit == 20)
        #expect(web.brain.preferredEngine == .codex)
        // It comes back stopped, with nothing in its log, whatever it was doing.
        #expect(!web.brain.running)
        #expect(!web.brain.busy)
        #expect(web.brain.log.isEmpty)
        #expect(web.status.line == "Idle")
        #expect(relaunched.record(root: "/tmp/api") == nil)
    }

    @Test func theDefaultLimitAndNoRoleAreNotWrittenDown() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        let web = orchestrators.open(root: "/tmp/web")
        web.setTurns(20)
        web.setTurns(BoardTeams.turns)
        let pane = UUID()
        web.wire([pane], role: "Coder")
        web.setRole("", for: pane)
        #expect(web.record.turns == nil)
        #expect(web.record.members == [.init(pane: pane.uuidString, role: nil)])
        #expect(web.record.engine == nil)
    }

    @Test func anUnreadableFileIsSetAsideAndStartsEmpty() throws {
        let file = try scratchFile()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ not json".utf8).write(to: file)
        let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        #expect(orchestrators.record(root: "/tmp/web") == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("orchestrators.json.unreadable-") })
        #expect(!names.contains("orchestrators.json"))
        // Saving again is safe: the damaged file was kept beside it.
        let web = orchestrators.open(root: "/tmp/web")
        web.setGoal("Start over", for: web.id)
        #expect(ClassicOrchestratorStore(file: file).load()["/tmp/web"]?.goal == "Start over")
    }

    @Test func aMissingFileIsJustEmpty() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(ClassicOrchestratorStore(file: file).load().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).isEmpty)
    }

    @Test func whatTheFileSaysIsCheckedBeforeItIsUsed() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let pane = UUID()
        let json = """
        {"projects": {"/tmp/web": {"goal": "  Ship it  ", "turns": 9000, "engine": "rm -rf", "members": [
          {"pane": "\(pane.uuidString)", "role": "  Reviewer "}, {"pane": "\(pane.uuidString)"}, {"pane": "not an id", "role": "x"}]},
          "/tmp/empty": {"goal": "   "}}}
        """
        try Data(json.utf8).write(to: file)
        let records = ClassicOrchestratorStore(file: file).load()
        let web = try #require(records["/tmp/web"])
        #expect(web.goal == "Ship it")
        #expect(web.turns == nil)
        #expect(web.engine == nil)
        #expect(web.members == [.init(pane: pane.uuidString, role: "Reviewer")])
        #expect(records["/tmp/empty"] == nil)
    }

    @Test func wiringIsOncePerPaneAndRolesCanChange() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        let web = orchestrators.open(root: "/tmp/web")
        let ada = UUID()
        web.wire([ada], role: "Coder")
        web.wire([ada], role: "Reviewer")
        #expect(web.team.members.count == 1)
        #expect(web.role(of: ada) == "Coder")
        web.setRole("Tester", for: ada)
        #expect(web.role(of: ada) == "Tester")
        #expect(orchestrators.orchestrator(wiring: ada) === web)
        web.unwire(ada)
        #expect(!web.isWired(ada))
        #expect(orchestrators.wired.isEmpty)
        #expect(orchestrators.orchestrator(wiring: ada) == nil)
    }

    @Test func aClosedPanesWireGoesWithIt() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        let web = orchestrators.open(root: "/tmp/web")
        let api = orchestrators.open(root: "/tmp/api")
        let ada = UUID(), otto = UUID(), cy = UUID()
        web.wire([ada, otto], role: "Coder")
        api.wire([cy])
        #expect(orchestrators.wired == [ada, otto, cy])
        // Otto's tab closed.
        for orchestrator in orchestrators.list { orchestrator.prune(keeping: [ada, cy]) }
        #expect(web.team.members.map(\.tile) == [ada])
        #expect(api.team.members.map(\.tile) == [cy])
        #expect(orchestrators.wired == [ada, cy])
        #expect(ClassicOrchestratorStore(file: file).load()["/tmp/web"]?.members == [.init(pane: ada.uuidString, role: "Coder")])
        // A pane with no terminal behind it is never an agent to message.
        #expect(web.orchestratorAgents(web.id).isEmpty)
        #expect(web.mentionable().isEmpty)
    }

    @Test func itAnswersOnlyForItself() throws {
        let file = try scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let orchestrators = ClassicOrchestrators(store: ClassicOrchestratorStore(file: file))
        let web = orchestrators.open(root: "/tmp/web")
        #expect(web.orchestrator(web.id) == web.team)
        #expect(web.ensureTeam(web.id) != nil)
        #expect(web.orchestrator(UUID()) == nil)
        #expect(web.ensureTeam(UUID()) == nil)
        #expect(web.orchestratorPlace == .tabs)
        #expect(!web.isPaused(UUID()))
        // Nothing from a reply is typed anywhere when nothing is wired.
        #expect(web.performOrchestration(OrchestratorAction(type: "broadcast", text: "hello"), for: web.id, handles: [:]) == nil)
    }

    @Test func mentionsTakeTheLongestNameFirst() {
        let ada = UUID(), ada2 = UUID(), otto = UUID()
        let labels = [(pane: ada, label: "Ada"), (pane: ada2, label: "Ada 2"), (pane: otto, label: "Otto")]
        let one = ClassicOrchestrator.mentions(in: "@Ada 2 run the tests", labels: labels)
        #expect(one.panes == [ada2])
        #expect(one.rest == "run the tests")
        let two = ClassicOrchestrator.mentions(in: "@otto and @Ada stop", labels: labels)
        #expect(Set(two.panes) == [ada, otto])
        #expect(two.rest == "and  stop")
        let none = ClassicOrchestrator.mentions(in: "ship the form", labels: labels)
        #expect(none.panes.isEmpty)
        #expect(none.rest == "ship the form")
    }

    @Test func agentsAlreadyInTheProjectAreItsAgents() {
        let here = UUID(), shell = UUID(), elsewhere = UUID(), taken = UUID(), removed = UUID()
        let panes = [
            ClassicOrchestrators.AdoptablePane(id: here, root: "/work/app", isAgent: true),
            ClassicOrchestrators.AdoptablePane(id: shell, root: "/work/app", isAgent: false),
            ClassicOrchestrators.AdoptablePane(id: elsewhere, root: "/work/other", isAgent: true),
            ClassicOrchestrators.AdoptablePane(id: taken, root: "/work/app", isAgent: true),
            ClassicOrchestrators.AdoptablePane(id: removed, root: "/work/app", isAgent: true),
        ]
        let adopted = ClassicOrchestrators.adoptable(panes, root: "/work/app", wired: [taken], leftOut: [removed])
        // Not a plain terminal, another project's agent, one already wired, or one you took off.
        #expect(adopted == [here])
    }

    @Test func anAgentYouUnwiredStaysOutUntilYouWireItAgain() {
        let orchestrator = ClassicOrchestrator(root: "/work/app")
        let pane = UUID()
        orchestrator.wire([pane])
        #expect(orchestrator.leftOut.isEmpty)
        orchestrator.unwire(pane)
        #expect(orchestrator.leftOut == [pane])
        orchestrator.wire([pane])
        #expect(orchestrator.leftOut.isEmpty)
    }
}
