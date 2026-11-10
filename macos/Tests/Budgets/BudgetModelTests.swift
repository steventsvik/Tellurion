import Foundation
import Testing
@testable import Ghostty

/// Which budget covers a session, when its thresholds fire, and how it's raised and kept.
struct BudgetModelTests {
    private let pane = UUID()
    private let project = "/tmp/project"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func settings() -> BudgetSettings {
        var settings = BudgetSettings()
        settings.everywhere = AgentBudget(dollars: 10, since: start)
        settings.projects[project] = AgentBudget(dollars: 5, since: start)
        settings.setPane(AgentBudget(dollars: 2, action: .notify), for: pane, now: start)
        return settings
    }

    // MARK: Scope

    @Test func thePaneWinsOverTheProjectWhichWinsOverTheDefault() {
        let settings = settings()
        let later = start.addingTimeInterval(60)
        let own = settings.budget(pane: pane, project: project, sessionStart: later)
        #expect(own?.scope == .pane)
        #expect(own?.budget.dollars == 2)
        #expect(own?.budget.action == .notify)

        let other = UUID()
        let inProject = settings.budget(pane: other, project: project, sessionStart: later)
        #expect(inProject?.scope == .project)
        #expect(inProject?.budget.dollars == 5)

        let elsewhere = settings.budget(pane: other, project: "/tmp/other", sessionStart: later)
        #expect(elsewhere?.scope == .everywhere)
        #expect(elsewhere?.budget.dollars == 10)
        #expect(settings.budget(pane: other, project: nil, sessionStart: later)?.scope == .everywhere)
    }

    @Test func aDefaultOnlyCoversSessionsStartedAfterIt() {
        let settings = settings()
        let other = UUID()
        let earlier = start.addingTimeInterval(-60)
        #expect(settings.budget(pane: other, project: project, sessionStart: earlier) == nil)
        // Not known yet: not covered yet.
        #expect(settings.budget(pane: other, project: project, sessionStart: nil) == nil)
        #expect(settings.budget(pane: other, project: project, sessionStart: start)?.scope == .project)
        // The pane's own budget was set for the session that's there.
        #expect(settings.budget(pane: pane, project: project, sessionStart: earlier)?.scope == .pane)
        #expect(settings.budget(pane: pane, project: project, sessionStart: nil)?.scope == .pane)

        // A project default set later leaves an older session to the general one.
        var mixed = settings
        mixed.projects[project]?.since = start.addingTimeInterval(120)
        #expect(mixed.budget(pane: other, project: project, sessionStart: start.addingTimeInterval(60))?.scope == .everywhere)
    }

    @Test func noBudgetForAPaneBeatsTheDefaults() {
        var settings = settings()
        settings.setPane(AgentBudget(), for: pane)
        #expect(settings.budget(pane: pane, project: project, sessionStart: start.addingTimeInterval(60)) == nil)
        settings.setPane(nil, for: pane)
        #expect(settings.budget(pane: pane, project: project, sessionStart: start.addingTimeInterval(60))?.scope == .project)
    }

    @Test func nothingSetMeansNothingToMeasure() {
        var settings = BudgetSettings()
        #expect(settings.isEmpty)
        settings.setPane(AgentBudget(), for: pane)
        settings.projects[project] = AgentBudget(dollars: 0)
        #expect(settings.isEmpty)
        settings.everywhere = AgentBudget(tokens: 1000)
        #expect(!settings.isEmpty)
    }

    @Test func onlyTheNewestPaneBudgetsAreKept() {
        var settings = BudgetSettings()
        var ids: [UUID] = []
        for index in 0..<(BudgetSettings.panesKept + 5) {
            let id = UUID()
            ids.append(id)
            settings.setPane(AgentBudget(dollars: 1), for: id, now: start.addingTimeInterval(Double(index)))
        }
        #expect(settings.panes.count == BudgetSettings.panesKept)
        #expect(settings.panes[ids[0].uuidString] == nil)
        #expect(settings.panes[ids[4].uuidString] == nil)
        #expect(settings.panes[ids[5].uuidString] != nil)
        #expect(settings.panes[ids.last!.uuidString] != nil)
    }

    // MARK: Thresholds

    @Test func eachThresholdFiresOnce() {
        var progress = BudgetProgress()
        var event: BudgetProgress.Event?
        event = progress.update(fraction: 0.2)
        #expect(event == nil)
        #expect(progress.state(fraction: 0.2) == .ok)
        event = progress.update(fraction: 0.8)
        #expect(event == .warning)
        event = progress.update(fraction: 0.85)
        #expect(event == nil)
        #expect(progress.state(fraction: 0.85) == .warning)
        event = progress.update(fraction: 1.0)
        #expect(event == .reached)
        event = progress.update(fraction: 1.4)
        #expect(event == nil)
        #expect(progress.state(fraction: 1.4) == .reached)
    }

    @Test func jumpingStraightPastTheCapOnlyReportsTheCap() {
        var progress = BudgetProgress()
        var event: BudgetProgress.Event?
        event = progress.update(fraction: 1.2)
        #expect(event == .reached)
        event = progress.update(fraction: 1.2)
        #expect(event == nil)
        // Back between the two (a small raise): the warning was already given.
        event = progress.update(fraction: 0.9)
        #expect(event == nil)
        event = progress.update(fraction: 1.0)
        #expect(event == .reached)
    }

    @Test func raisingTheCapArmsTheThresholdsAgain() {
        var progress = BudgetProgress()
        var event: BudgetProgress.Event?
        _ = progress.update(fraction: 1.1)
        event = progress.update(fraction: 0.5)
        #expect(event == nil)
        #expect(progress.state(fraction: 0.5) == .ok)
        event = progress.update(fraction: 0.8)
        #expect(event == .warning)
        event = progress.update(fraction: 1)
        #expect(event == .reached)
    }

    @Test func theAgentIsPausedOncePerCrossing() {
        var progress = BudgetProgress()
        var froze = false
        _ = progress.update(fraction: 1.1)
        froze = progress.shouldPause(fraction: 1.1, action: .notify)
        #expect(!froze)
        #expect(progress.state(fraction: 1.1) == .reached)
        // Changing to "Pause the agent" while over the cap pauses it.
        froze = progress.shouldPause(fraction: 1.1, action: .pause)
        #expect(froze)
        #expect(progress.state(fraction: 1.1) == .paused)
        froze = progress.shouldPause(fraction: 1.2, action: .pause)
        #expect(!froze)

        // Resumed some other way without more room: it isn't frozen again.
        progress.paused = false
        _ = progress.update(fraction: 1.3)
        froze = progress.shouldPause(fraction: 1.3, action: .pause)
        #expect(!froze)
        #expect(progress.state(fraction: 1.3) == .reached)

        // With more room, the next crossing pauses again.
        _ = progress.update(fraction: 0.7)
        froze = progress.shouldPause(fraction: 0.7, action: .pause)
        #expect(!froze)
        _ = progress.update(fraction: 1)
        froze = progress.shouldPause(fraction: 1, action: .pause)
        #expect(froze)
    }

    @Test func theFractionIsTheLargerOfTheTwoCaps() {
        let both = AgentBudget(dollars: 10, tokens: 1_000_000)
        #expect(both.fraction(spent: 2, tokens: 500_000) == 0.5)
        #expect(both.fraction(spent: 9, tokens: 500_000) == 0.9)
        // A cost that isn't known can't fill a dollar cap; the tokens still count.
        #expect(both.fraction(spent: nil, tokens: 250_000) == 0.25)
        #expect(AgentBudget(dollars: 10).fraction(spent: nil, tokens: 9_000_000) == 0)
        #expect(AgentBudget().fraction(spent: 50, tokens: 9_000_000) == 0)
    }

    // MARK: Raising

    @Test func resumingRaisesTheCapThatWasReached() {
        let budget = AgentBudget(dollars: 5, tokens: 2_000_000)
        let fixed = budget.raised(.fixed, spent: 5.02, tokens: 400_000)
        // From what's been spent, so there's a full step of room.
        #expect(abs((fixed.dollars ?? 0) - 10.02) < 1e-9)
        #expect(fixed.tokens == 2_000_000)
        #expect(fixed.fraction(spent: 5.02, tokens: 400_000) < 1)

        let half = budget.raised(.half, spent: 5.02, tokens: 400_000)
        #expect(abs((half.dollars ?? 0) - 7.52) < 1e-9)
        #expect(half.tokens == 2_000_000)

        let tokens = budget.raised(.fixed, spent: 1, tokens: 2_100_000)
        #expect(tokens.dollars == 5)
        #expect(tokens.tokens == 3_100_000)
        #expect(budget.raised(.half, spent: 1, tokens: 2_100_000).tokens == 3_100_000)
    }

    @Test func aFarOvershotCapStillGetsRoom() {
        let budget = AgentBudget(dollars: 5)
        let raised = budget.raised(.fixed, spent: 11, tokens: 0)
        #expect(raised.dollars == 16)
        #expect(raised.fraction(spent: 11, tokens: 0) < 1)
        let half = budget.raised(.half, spent: 11, tokens: 0)
        #expect(half.dollars == 13.5)
        #expect(half.fraction(spent: 11, tokens: 0) < 1)
    }

    @Test func raisingBeforeTheCapRaisesEveryCap() {
        let budget = AgentBudget(dollars: 5, tokens: 1_000_000, action: .notify)
        let raised = budget.raised(.half, spent: 4.5, tokens: 100_000)
        #expect(raised.dollars == 7.5)
        #expect(raised.tokens == 1_500_000)
        #expect(raised.action == .notify)
        #expect(BudgetFormat.fixedStep(budget, spent: 4.5, tokens: 100_000) == "Add $5")
        #expect(BudgetFormat.fixedStep(budget, spent: 1, tokens: 1_000_000) == "Add 1M tokens")
        #expect(BudgetFormat.fixedStep(AgentBudget(tokens: 1000), spent: nil, tokens: 0) == "Add 1M tokens")
    }

    // MARK: Storage

    @Test func budgetsComeBackAsTheyWereSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("budgets.json")
        // No file yet: nothing set.
        #expect(AgentBudgets.load(from: file) == BudgetSettings())

        var saved = settings()
        saved.projects["/tmp/other"] = AgentBudget(tokens: 3_000_000, action: .notify, since: start)
        #expect(StoredFile.write(json: saved, to: file, what: "the budgets", log: StoredFile.logger("Tests")))
        #expect(AgentBudgets.load(from: file) == saved)

        // A file that can't be read is set aside, and the app starts with nothing set.
        try Data("{ not json".utf8).write(to: file)
        #expect(AgentBudgets.load(from: file) == BudgetSettings())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Text

    @Test func figuresReadPlainly() {
        #expect(BudgetFormat.money(1.2) == "$1.20")
        #expect(BudgetFormat.money(5) == "$5")
        #expect(BudgetFormat.money(120.4) == "$120")
        #expect(BudgetFormat.count(950) == "950")
        #expect(BudgetFormat.count(12_500) == "12.5K")
        #expect(BudgetFormat.count(5_000_000) == "5M")
        let status = BudgetStatus(spent: 1.2, tokens: 1_200_000, capDollars: 5, capTokens: 5_000_000, fraction: 0.24, state: .ok)
        #expect(BudgetFormat.progress(status) == "$1.20 of $5 · 1.2M of 5M tokens")
        var unknown = status
        unknown.spent = nil
        unknown.capTokens = nil
        #expect(BudgetFormat.progress(unknown) == "cost unknown of $5")
        #expect(BudgetFormat.caps(AgentBudget(dollars: 5, tokens: 2_000_000)) == "$5 or 2M tokens")
        #expect(BudgetFormat.caps(AgentBudget()) == "No budget")
    }

    @Test func whatIsTypedBecomesABudget() {
        #expect(BudgetDraft.parseDollars("$7.50") == 7.5)
        #expect(BudgetDraft.parseDollars(" 1,200 ") == 1200)
        #expect(BudgetDraft.parseDollars("0") == nil)
        #expect(BudgetDraft.parseDollars("-3") == nil)
        #expect(BudgetDraft.parseDollars("five") == nil)
        #expect(BudgetDraft.parseTokens("2M") == 2_000_000)
        #expect(BudgetDraft.parseTokens("500k") == 500_000)
        #expect(BudgetDraft.parseTokens("1.5 M tokens") == 1_500_000)
        #expect(BudgetDraft.parseTokens("1,500,000") == 1_500_000)
        #expect(BudgetDraft.parseTokens("lots") == nil)
        #expect(BudgetDraft.parseTokens("m") == nil)

        var draft = BudgetDraft()
        #expect(draft.budget == nil)
        draft.dollars = "5"
        draft.action = .notify
        #expect(draft.budget == AgentBudget(dollars: 5, tokens: nil, action: .notify))
        // One cap that can't be read isn't quietly dropped.
        draft.tokens = "abc"
        #expect(draft.budget == nil)
        draft.tokens = "2M"
        #expect(draft.budget == AgentBudget(dollars: 5, tokens: 2_000_000, action: .notify))
        #expect(BudgetDraft(draft.budget) == draft)
        #expect(BudgetDraft(AgentBudget(dollars: 7.5)).dollars == "7.50")
    }
}
