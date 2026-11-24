import Foundation
import Testing
@testable import Ghostty

/// The window as the glasses show it: every pane in the app's order with its project,
/// the screen's text, the few keys, and the Tools row.
struct GlassesWindowTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let shop = GlassesProject(id: "aaaa", name: "shop", path: "~/code/shop")
    private let site = GlassesProject(id: "bbbb", name: "site", path: "~/code/site")

    private func pane(_ name: String, _ activity: VerticalTabAgentActivity = .working, in group: GlassesProject? = nil,
                      agent: Bool = true) -> GlassesAgent {
        var pane = GlassesAgent(id: UUID(), name: name, kind: agent ? "claude" : "", activity: activity, since: start)
        pane.isAgent = agent
        pane.agentName = agent ? "Claude Code" : nil
        pane.group = group
        return pane
    }

    private func list(_ message: [String: Any]) -> [[String: Any]] { message["agents"] as? [[String: Any]] ?? [] }
    private func names(_ message: [String: Any]) -> [String] { list(message).compactMap { $0["name"] as? String } }

    // MARK: The list of panes

    @Test func versionTwoListsEveryPaneInTheAppsOrder() {
        let panes = [
            pane("ready", .ready, in: shop), pane("zsh", in: shop, agent: false), pane("permission", .needsPermission, in: shop),
            pane("working", in: shop),
        ]
        let message = GlassesAgents.message(panes, version: 2)
        // Not sorted by who needs you: a list that reorders itself under the cursor is no help.
        #expect(names(message) == ["ready", "zsh", "permission", "working"])
        #expect(message["v"] as? Int == 2)
        #expect(message["needs"] as? Int == 1)
        let shell = list(message)[1]
        #expect(shell["agent"] as? Bool == false)
        #expect(shell["act"] as? String == "none")
        #expect(shell["agentName"] == nil)
        #expect(shell["prompt"] == nil)
        let agent = list(message)[2]
        #expect(agent["agent"] as? Bool == true)
        #expect(agent["agentName"] as? String == "Claude Code")
        #expect(agent["prompt"] is String)
        #expect((agent["proj"] as? [String: String]) == ["id": "aaaa", "name": "shop", "path": "~/code/shop"])
    }

    @Test func versionOneStillGetsOnlyTheAgentsWithTheNeediestFirst() {
        let panes = [pane("working", in: shop), pane("zsh", in: shop, agent: false), pane("permission", .needsPermission, in: site)]
        let message = GlassesAgents.message(panes)
        #expect(names(message) == ["permission", "working"])
        #expect(message["v"] == nil)
        #expect(list(message).allSatisfy { $0["agent"] == nil && $0["proj"] == nil })
        #expect(message["needs"] as? Int == 1)
    }

    @Test func aPlainTerminalNeverCountsAsNeedingYouOrHasAPrompt() {
        // A shell's pane carries no agent state, whatever its fields say.
        let shell = pane("zsh", .needsPermission, in: shop, agent: false)
        #expect(GlassesAgents.promptIdentity(shell) == nil)
        #expect(GlassesAgents.message([shell], version: 2)["needs"] as? Int == 0)
        #expect(GlassesRules.answerRefusal(agent: shell, prompt: "anything") != nil)
    }

    @Test func panesAreGroupedByProjectInTheOrderTheirFirstTabComes() {
        let panes = [
            pane("a", in: site), pane("loose"), pane("b", in: shop), pane("c", in: site), pane("d", in: shop), pane("later"),
        ]
        #expect(GlassesAgents.grouped(panes).map(\.name) == ["a", "c", "b", "d", "loose", "later"])
        #expect(names(GlassesAgents.message(panes, version: 2)) == ["a", "c", "b", "d", "loose", "later"])
        #expect(list(GlassesAgents.message(panes, version: 2))[4]["proj"] == nil)
        #expect(GlassesAgents.grouped([]).isEmpty)
    }

    @Test func tabsKeepTheirOrderWithinEachWindow() {
        // Windows as the app lists them (front to back), tabs as each window orders them.
        let groups = ["b": ["a", "b", "c"], "a": ["a", "b", "c"], "c": ["a", "b", "c"]]
        #expect(GlassesOrder.tabOrder(["b", "x", "c", "a"]) { groups[$0] } == ["a", "b", "c", "x"])
        #expect(GlassesOrder.tabOrder(["x", "y"]) { _ in nil } == ["x", "y"])
        // A closed tab still in its group isn't listed, and nothing is listed twice.
        #expect(GlassesOrder.tabOrder(["b", "a"]) { _ in ["a", "gone", "b", "a"] } == ["a", "b"])
        #expect(GlassesOrder.tabOrder([String]()) { _ in nil }.isEmpty)
    }

    @Test func aProjectGoesByAHashAndAShortPathNeverItsRealOne() {
        let home = "/Users/someone"
        let project = GlassesProjects.project(root: home + "/code/shop", name: "shop", home: home)
        #expect(project.path == "~/code/shop")
        #expect(project.name == "shop")
        #expect(project.id == GlassesServer.projectID(home + "/code/shop"))
        #expect(project.id.count == 16)
        #expect(!project.id.contains("shop"))
        #expect(GlassesProjects.project(root: home, name: "someone", home: home) == GlassesProject(id: GlassesProjects.id(home), name: "Home", path: "~"))
        #expect(GlassesProjects.shortPath("/Users/someone-else/x", home: home) == "/Users/someone-else/x")
        #expect(GlassesProjects.shortPath("/private/tmp/x", home: home + "/") == "/private/tmp/x")
        let item = list(GlassesAgents.message([pane("a", in: project)], version: 2))[0]
        #expect(!GlassesRoutes.json(item).contains("/Users/"))
    }

    // MARK: The screen's text

    @Test func theScreenIsSentAsItIsWithoutTrailingSpaces() {
        let screen = "$ npm test   \n\n\n  FAIL login.test.ts\t \n\u{1b}[31mred\u{1b}[0m\n\n\n\n"
        let text = GlassesText.screen(screen, lines: 40)
        // Lines keep their indent; runs of empty ones become one; the empty end is dropped.
        #expect(text.text == "$ npm test\n\n  FAIL login.test.ts\n[31mred[0m")
        #expect(text.more == false)
        #expect(GlassesText.screen("", lines: 40).text.isEmpty)
        #expect(GlassesText.screen("\n\n  \n", lines: 40).text.isEmpty)
    }

    @Test func theScreenIsReadAFewLinesAtATimeFromItsEnd() {
        let screen = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let last = GlassesText.screen(screen, lines: 3)
        #expect(last.text == "line 98\nline 99\nline 100")
        #expect(last.more)
        let earlier = GlassesText.screen(screen, lines: 3, before: 3)
        #expect(earlier.text == "line 95\nline 96\nline 97")
        let first = GlassesText.screen(screen, lines: 40, before: 98)
        #expect(first.text == "line 1\nline 2")
        #expect(first.more == false)
        #expect(GlassesText.screen(screen, lines: 40, before: 100).text.isEmpty)
        #expect(GlassesText.screen(screen, lines: 40, before: 5000).text.isEmpty)
        #expect(GlassesText.screen(screen, lines: 0).text.isEmpty)
    }

    @Test func theScreenIsCutAtALineToFitTheLimit() {
        let screen = (1...200).map { "row \($0) " + String(repeating: "x", count: 60) }.joined(separator: "\n")
        let text = GlassesText.screen(screen, lines: 60)
        #expect(text.text.count <= GlassesText.tailLimit)
        #expect(text.text.hasPrefix("row "))
        #expect(text.text.hasSuffix(String(repeating: "x", count: 60)))
        #expect(text.text.split(separator: "\n").last?.hasPrefix("row 200 ") == true)
        #expect(text.more)
        // One line longer than the limit by itself: its end.
        let long = GlassesText.screen(String(repeating: "y", count: 5000), lines: 5)
        #expect(long.text.count == GlassesText.tailLimit)
    }

    // MARK: Messages

    @Test func theNewMessagesAreChecked() {
        let id = UUID()
        #expect(GlassesRequest.parse(["t": "tail", "id": id.uuidString, "lines": 40, "src": "screen"])
            == .request(.screen(id: id, lines: 40, before: 0)))
        #expect(GlassesRequest.parse(["t": "tail", "id": id.uuidString, "lines": 40, "src": "screen", "before": 80])
            == .request(.screen(id: id, lines: 40, before: 80)))
        // Without the source it's version 1's request: the agent's last answer.
        #expect(GlassesRequest.parse(["t": "tail", "id": id.uuidString, "lines": 30, "before": 80]) == .request(.tail(id: id, lines: 30)))
        #expect(GlassesRequest.parse(["t": "tools"]) == .request(.tools(true)))
        #expect(GlassesRequest.parse(["t": "untools"]) == .request(.tools(false)))
        #expect(GlassesRequest.parse(["t": "key", "id": id.uuidString, "key": "ctrl-c"]) == .request(.key(id: id, key: .interrupt)))
        for bad: [String: Any] in [
            ["t": "tail", "id": id.uuidString, "src": "screen", "before": -1],
            ["t": "tail", "id": id.uuidString, "src": "screen", "before": GlassesRequest.maxBefore + 1],
            ["t": "tail", "id": id.uuidString, "src": "screen", "lines": 500],
            ["t": "key", "key": "enter"],
            ["t": "key", "id": "nope", "key": "enter"],
            ["t": "key", "id": id.uuidString],
        ] {
            guard case .invalid = GlassesRequest.parse(bad) else {
                Issue.record("accepted \(bad)")
                continue
            }
        }
    }

    // MARK: Keys

    @Test func onlyAFewKeysCanBePressed() {
        #expect(Set(GlassesKey.allCases.map(\.rawValue)) == ["enter", "escape", "ctrl-c", "up", "down", "tab", "y", "n"])
        let id = UUID().uuidString
        for name in ["a", "backspace", "ctrl-d", "Enter", "ENTER", "enter ", "", "rm -rf", "ctrl-c\n", "1", "space", "arrowUp", "delete"] {
            guard case .invalid = GlassesRequest.parse(["t": "key", "id": id, "key": name]) else {
                Issue.record("accepted the key \(name)")
                continue
            }
        }
        // Not text, not a list, not a number.
        guard case .invalid = GlassesRequest.parse(["t": "key", "id": id, "key": ["enter"]]) else { Issue.record("accepted a list"); return }
        guard case .invalid = GlassesRequest.parse(["t": "key", "id": id, "key": 13]) else { Issue.record("accepted a number"); return }
    }

    @Test func noKeyIsPressedWhereNoAgentRuns() {
        for key in GlassesKey.allCases {
            #expect(GlassesRules.keyRefusal(hasAgent: false, waitingForPermission: false, key: key) != nil)
            #expect(GlassesRules.keyRefusal(hasAgent: false, waitingForPermission: true, key: key) != nil)
            #expect(GlassesRules.keyRefusal(hasAgent: true, waitingForPermission: false, key: key) == nil)
        }
    }

    @Test func noKeyAnswersAPermissionPrompt() {
        // Enter would allow it without saying which prompt; that takes an answer with its identity.
        for key in GlassesKey.allCases {
            #expect(GlassesRules.keyRefusal(hasAgent: true, waitingForPermission: true, key: key) != nil)
        }
    }

    // MARK: Tools

    @Test func theToolsRowIsBuiltFromPlainNumbers() throws {
        var tools = GlassesTools()
        tools.usage = [.init(name: "Claude", windows: [
            .init(label: "5h", percent: 41.6, resets: start.addingTimeInterval(7200)),
            .init(label: "Wk", percent: 61, resets: start.addingTimeInterval(-60)),
            .init(label: "Opus", percent: 12, resets: nil),
        ])]
        tools.servers = [.init(name: "shop", address: "localhost:5173", project: "aaaa"), .init(name: "docs", address: "localhost:4000/app", project: nil)]
        tools.review = 2
        tools.failedChecks = ["Cy"]
        tools.budgets = [.init(name: "Otto", fraction: 0.834), .init(name: "Ada", fraction: 0.5), .init(name: "Cy", fraction: 1.2)]
        tools.conflicts = 1
        let message = tools.message(now: start)
        #expect(message["t"] as? String == "tools")
        let windows = try #require(((message["usage"] as? [[String: Any]])?.first?["windows"]) as? [[String: Any]])
        #expect(windows.map { $0["label"] as? String } == ["5h", "Wk", "Opus"])
        #expect(windows[0]["pct"] as? Int == 42)
        #expect(windows[0]["resets"] as? Int == Int(start.timeIntervalSince1970) + 7200)
        // A window that has reset is unused until new numbers come.
        #expect(windows[1]["pct"] as? Int == 0)
        #expect(windows[1]["resets"] == nil)
        #expect(windows[2]["resets"] == nil)
        let servers = try #require(message["servers"] as? [[String: Any]])
        #expect(servers[0]["url"] as? String == "localhost:5173")
        #expect(servers[0]["proj"] as? String == "aaaa")
        #expect(servers[1]["proj"] == nil)
        #expect(message["review"] as? Int == 2)
        #expect(message["checks"] as? [String] == ["Cy"])
        // Only the budgets near their cap or past it.
        let budgets = try #require(message["budgets"] as? [[String: Any]])
        #expect(budgets.map { $0["name"] as? String } == ["Otto", "Cy"])
        #expect(budgets.map { $0["pct"] as? Int } == [83, 120])
        #expect(message["conflicts"] as? Int == 1)
    }

    @Test func anEmptyToolsRowStillSaysSo() {
        let message = GlassesTools().message(now: start)
        #expect((message["usage"] as? [Any])?.isEmpty == true)
        #expect((message["servers"] as? [Any])?.isEmpty == true)
        #expect(message["review"] as? Int == 0)
        #expect(message["conflicts"] as? Int == 0)
        // The same numbers give the same text, so it's only sent when something changed.
        #expect(GlassesRoutes.json(message) == GlassesRoutes.json(GlassesTools().message(now: start.addingTimeInterval(5))))
    }

    @Test func longNamesInTheToolsRowAreClipped() {
        var tools = GlassesTools()
        tools.servers = (0..<20).map { .init(name: String(repeating: "n", count: 90), address: "localhost:\(3000 + $0)", project: nil) }
        tools.failedChecks = (0..<20).map { "pane \($0)" }
        let message = tools.message(now: start)
        #expect((message["servers"] as? [[String: Any]])?.count == GlassesTools.most)
        #expect(((message["servers"] as? [[String: Any]])?.first?["name"] as? String)?.count == 24)
        #expect((message["checks"] as? [String])?.count == GlassesTools.most)
    }
}
