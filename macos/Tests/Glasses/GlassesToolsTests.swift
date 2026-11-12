import Foundation
import Testing
@testable import Ghostty

/// The Mac's tools and the orchestrator as the glasses reach them: which there are, what
/// may be asked of each, and what their messages carry.
struct GlassesToolsTests {
    private func invalid(_ message: [String: Any]) -> Bool {
        if case .invalid = GlassesRequest.parse(message) { return true }
        return false
    }

    // MARK: The list

    @Test func theToolsComeInTheToolsPanelsOrderAndSections() {
        let tools = GlassesTool.listed { _ in true }
        #expect(tools.map(\.title) == [
            "Code editor", "Visual Fix", "Command history",
            "Mission Control", "Orchestrator", "Agent races", "Race scoreboard", "Review changes", "Checks", "Agent activity",
            "Search sessions", "Budgets", "Conflicts", "Worktrees",
            "Localhost", "Ports", "Skills", "Project memory", "Environment",
            "Usage", "Background processes", "Phone", "Local models",
            "Layout", "Design", "Settings",
            "Display check",
        ])
        var sections: [String] = []
        for tool in tools where sections.last != tool.section { sections.append(tool.section) }
        #expect(sections == ["This tab", "Agents", "Project", "This Mac", "View", "Glasses"])
        #expect(tools == GlassesTool.allCases)
    }

    @Test func aToolThatIsOffInSettingsIsNotListed() {
        let off: Set<TellurionFeature> = [.review, .races, .localhost]
        let tools = GlassesTool.listed { !off.contains($0) }
        #expect(!tools.contains(.review) && !tools.contains(.races) && !tools.contains(.scoreboard) && !tools.contains(.localhost))
        #expect(tools.contains(.checks) && tools.contains(.settings) && tools.contains(.ruler))
        // The ones with no switch are always there.
        #expect(GlassesTool.listed { _ in false } == [.layout, .design, .settings, .ruler])
    }

    @Test func everyToolCanBeReachedOneWayOrTheOther() {
        for tool in GlassesTool.allCases {
            #expect(tool.hasPage || tool.opensOnMac, "\(tool.rawValue) has neither a page nor a window")
            #expect(!tool.title.isEmpty && !tool.section.isEmpty)
        }
        let withoutPage = GlassesTool.allCases.filter { !$0.hasPage }
        #expect(withoutPage.filter { !$0.opensOnMac }.isEmpty)
        // Only a few pages can change anything.
        #expect(Set(GlassesTool.allCases.filter { !$0.actions.isEmpty }) == [.review, .checks, .budgets, .localhost, .search])
        #expect(!GlassesTool.review.actions.contains(.add))
    }

    @Test func theListSaysWhichHaveAPageAndAFewWordsAboutEach() {
        let items = GlassesToolList.items([.review, .skills], summaries: [.review: String(repeating: "w", count: 200)], bright: [.review])
        #expect(items[0]["id"] as? String == "review")
        #expect(items[0]["name"] as? String == "Review changes")
        #expect(items[0]["section"] as? String == "Agents")
        #expect(items[0]["page"] as? Bool == true)
        #expect((items[0]["sum"] as? String)?.count == 80)
        #expect(items[0]["hi"] as? Bool == true)
        #expect(items[1]["page"] as? Bool == false)
        #expect(items[1]["sum"] == nil && items[1]["hi"] == nil)
    }

    // MARK: Requests

    @Test func onlyAToolFromTheListCanBeOpened() {
        #expect(GlassesRequest.parse(["t": "tool", "id": "skills"]) == .request(.tool(.skills)))
        #expect(GlassesRequest.parse(["t": "tool", "id": "review"]) == .request(.tool(.review)))
        #expect(GlassesRequest.parse(["t": "toolpage", "id": "review"]) == .request(.toolPage(.review)))
        #expect(GlassesRequest.parse(["t": "untoolpage"]) == .request(.toolPage(nil)))
        for name in ["Skills", "skills ", "", "terminal", "NSApp.terminate:", "open -a Calculator", "../settings", "showSetup(from:)"] {
            #expect(invalid(["t": "tool", "id": name]), "opened \(name)")
            #expect(invalid(["t": "toolpage", "id": name]))
        }
        #expect(invalid(["t": "tool"]))
        #expect(invalid(["t": "tool", "id": 3]))
        #expect(invalid(["t": "tool", "id": ["skills"]]))
        // A tool with no window isn't opened; one with no page has no page to ask for.
        #expect(invalid(["t": "tool", "id": "ports"]))
        #expect(invalid(["t": "tool", "id": "ruler"]))
        #expect(invalid(["t": "toolpage", "id": "skills"]))
    }

    @Test func aToolsPageIsOnlyAskedWhatThatToolMayDo() {
        #expect(GlassesRequest.parse(["t": "toolact", "tool": "checks", "row": "abcd", "action": "run"])
            == .request(.toolAction(tool: .checks, row: "abcd", action: .run, text: nil)))
        #expect(GlassesRequest.parse(["t": "toolact", "tool": "budgets", "row": "x", "action": "add"])
            == .request(.toolAction(tool: .budgets, row: "x", action: .add, text: nil)))
        #expect(GlassesRequest.parse(["t": "toolact", "tool": "review", "row": "r", "action": "feedback", "text": "  use the helper "])
            == .request(.toolAction(tool: .review, row: "r", action: .feedback, text: "use the helper")))
        #expect(GlassesRequest.parse(["t": "toolact", "tool": "search", "action": "query", "text": "login"])
            == .request(.toolAction(tool: .search, row: "", action: .query, text: "login")))
        // Another tool's action, one nobody has, or a tool that only shows things.
        #expect(invalid(["t": "toolact", "tool": "review", "row": "r", "action": "add"]))
        #expect(invalid(["t": "toolact", "tool": "review", "row": "r", "action": "acceptAll"]))
        #expect(invalid(["t": "toolact", "tool": "review", "row": "r", "action": "commit"]))
        #expect(invalid(["t": "toolact", "tool": "ports", "row": "r", "action": "stop"]))
        #expect(invalid(["t": "toolact", "tool": "mission", "row": "r", "action": "open"]))
        #expect(invalid(["t": "toolact", "tool": "nothing", "row": "r", "action": "run"]))
        #expect(invalid(["t": "toolact", "row": "r", "action": "run"]))
        // What's said has to be there, and not too long; a row's name is short and plain.
        #expect(invalid(["t": "toolact", "tool": "review", "row": "r", "action": "feedback"]))
        #expect(invalid(["t": "toolact", "tool": "review", "row": "r", "action": "feedback", "text": "   "]))
        #expect(invalid(["t": "toolact", "tool": "search", "action": "query", "text": String(repeating: "x", count: 2001)]))
        #expect(invalid(["t": "toolact", "tool": "checks", "row": String(repeating: "r", count: 81), "action": "run"]))
        #expect(invalid(["t": "toolact", "tool": "checks", "row": "a\nb", "action": "run"]))
        #expect(Set(GlassesToolAction.allCases.filter(\.takesText)) == [.feedback, .query])
    }

    @Test func theOrchestratorsButtonsAreChecked() {
        #expect(GlassesRequest.parse(["t": "orchstop", "id": "0123abcd"]) == .request(.orchestratorAction(id: "0123abcd", action: .stop)))
        #expect(GlassesRequest.parse(["t": "orchgo", "id": "0123abcd"]) == .request(.orchestratorAction(id: "0123abcd", action: .carryOn)))
        #expect(GlassesRequest.parse(["t": "orchwire", "id": "0123abcd"]) == .request(.orchestratorAction(id: "0123abcd", action: .wireAll)))
        #expect(GlassesRequest.parse(["t": "orchclear", "id": "0123abcd"]) == .request(.orchestratorAction(id: "0123abcd", action: .clear)))
        #expect(invalid(["t": "orchstop"]))
        #expect(invalid(["t": "orchwire", "id": ""]))
        #expect(invalid(["t": "orchclear", "id": String(repeating: "a", count: 65)]))
        #expect(GlassesRequest.parse(["t": "orchdelete", "id": "0123abcd"]) == .unknown)
        #expect(GlassesOrchestratorAction.allCases.count == 4)
    }

    // MARK: Pages

    @Test func aPageCarriesItsRowsAndOnlyTheActionsItsToolMayDo() throws {
        var page = GlassesToolPage(tool: .review)
        page.rows = [
            .init(id: "r1", text: String(repeating: "t", count: 300), sub: String(repeating: "s", count: 400), bright: true, actions: [
                .init(action: .feedback, label: "Say feedback", ask: "", name: "Codex"),
                .init(action: .open, label: "Open on Mac", ask: "Open this review on your Mac?"),
                // Not something Review may be asked from the glasses: left out.
                .init(action: .remove, label: "Discard", ask: "Discard?"),
            ]),
            .init(id: "r2", text: "plain", open: "p:abc"),
        ]
        let message = page.message()
        #expect(message["t"] as? String == "toolpage")
        #expect(message["id"] as? String == "review")
        #expect(message["title"] as? String == "Review changes")
        #expect(message["voice"] == nil && message["note"] == nil)
        let rows = try #require(message["rows"] as? [[String: Any]])
        #expect((rows[0]["text"] as? String)?.count == GlassesToolPage.textLength)
        #expect((rows[0]["sub"] as? String)?.count == GlassesToolPage.subLength)
        #expect(rows[0]["hi"] as? Bool == true)
        let actions = try #require(rows[0]["actions"] as? [[String: Any]])
        #expect(actions.map { $0["id"] as? String } == ["feedback", "open"])
        #expect(actions[0]["voice"] as? Bool == true)
        #expect(actions[0]["name"] as? String == "Codex")
        #expect(actions[1]["voice"] == nil)
        #expect(actions[1]["ask"] as? String == "Open this review on your Mac?")
        #expect(rows[1]["open"] as? String == "p:abc")
        #expect(rows[1]["actions"] == nil && rows[1]["sub"] == nil && rows[1]["hi"] == nil)
    }

    @Test func aPageIsShortAndOnlyTakesSpeechWhereItsToolDoes() {
        var search = GlassesToolPage(tool: .search, note: "Hold and say what to look for.")
        search.voice = (.query, "search")
        search.rows = (0..<60).map { .init(id: "s\($0)", text: "hit \($0)") }
        let message = search.message()
        #expect((message["rows"] as? [[String: Any]])?.count == GlassesToolPage.mostRows)
        #expect((message["voice"] as? [String: String]) == ["action": "query", "name": "Search sessions", "hint": "search"])
        #expect(message["note"] as? String == "Hold and say what to look for.")
        // A page whose tool takes no speech doesn't offer it, whatever it's given.
        var ports = GlassesToolPage(tool: .ports)
        ports.voice = (.query, "search")
        ports.rows = [.init(id: "p", text: ":5173", actions: [.init(action: .stop, label: "Stop", ask: "Stop it?")])]
        #expect(ports.message()["voice"] == nil)
        #expect((ports.message()["rows"] as? [[String: Any]])?.first?["actions"] == nil)
        // The same page gives the same text, so it's only sent when it changed.
        #expect(GlassesRoutes.json(search.message()) == GlassesRoutes.json(search.message()))
    }

    // MARK: The orchestrator

    @Test func theOrchestratorCarriesItsTeamAndWhatItLastSaidAndDid() throws {
        let ada = UUID()
        var project = GlassesOrchestrator(id: "0123abcd", name: "shop", status: "Turn 3 of 12 · 2 working")
        project.goal = "Ship the login flow"
        project.running = true
        project.members = [
            .init(id: ada, name: "Ada", role: "Coder", activity: "permission", detail: "Bash: rm -rf build"),
            .init(id: UUID(), name: "Terminal", role: nil, activity: nil, detail: nil),
        ]
        project.log = (1...30).map { "entry \($0)" }
        project.says = "Otto is on the tests."
        project.last = "Asked Otto to write the tests"
        let item = project.item()
        #expect(item["id"] as? String == "0123abcd")
        #expect(item["status"] as? String == "Turn 3 of 12 · 2 working")
        #expect(item["running"] as? Bool == true)
        #expect(item["goal"] as? String == "Ship the login flow")
        #expect(item["says"] as? String == "Otto is on the tests.")
        #expect(item["last"] as? String == "Asked Otto to write the tests")
        // The end of the log, oldest first.
        #expect((item["log"] as? [String])?.first == "entry 19")
        #expect((item["log"] as? [String])?.last == "entry 30")
        let members = try #require(item["members"] as? [[String: Any]])
        #expect(members[0]["id"] as? String == ada.uuidString)
        #expect(members[0]["role"] as? String == "Coder")
        #expect(members[0]["act"] as? String == "permission")
        #expect(members[0]["detail"] as? String == "Bash: rm -rf build")
        // A wired pane with no agent in it now says only who it is.
        #expect(members[1]["act"] == nil && members[1]["role"] == nil && members[1]["detail"] == nil)
    }

    @Test func anOrchestratorNotStartedYetSaysLittle() {
        let item = GlassesOrchestrator(id: "0123abcd", name: String(repeating: "n", count: 90), status: "Not started").item()
        #expect((item["name"] as? String)?.count == GlassesAgents.nameLength)
        #expect(item["running"] as? Bool == false)
        #expect((item["members"] as? [Any])?.isEmpty == true)
        #expect((item["log"] as? [Any])?.isEmpty == true)
        #expect(item["goal"] == nil && item["says"] == nil && item["last"] == nil)
        var crowded = GlassesOrchestrator(id: "x", name: "shop", status: "Idle")
        crowded.members = (0..<40).map { .init(id: UUID(), name: "Agent \($0)", role: String(repeating: "r", count: 90), activity: "working", detail: String(repeating: "d", count: 300)) }
        crowded.says = String(repeating: "s", count: 900)
        let members = crowded.item()["members"] as? [[String: Any]]
        #expect(members?.count == GlassesOrchestrator.mostMembers)
        #expect((members?.first?["role"] as? String)?.count == 24)
        #expect((members?.first?["detail"] as? String)?.count == 80)
        #expect((crowded.item()["says"] as? String)?.count == 240)
    }
}
