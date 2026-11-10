import Foundation
import Testing
@testable import Ghostty

/// Which changes in an agent's status its orchestrators hear about, and how a burst of them
/// becomes one update.
struct OrchestratorRelayTests {
    @Test func aTurnThatEndedIsNews() {
        #expect(OrchestratorRelay.reports(from: .working, to: .done))
        #expect(OrchestratorRelay.reports(from: .working, to: .ready))
        #expect(OrchestratorRelay.reports(from: .needsPermission, to: .done))
        #expect(OrchestratorRelay.reports(from: .needsPermission, to: .ready))
    }

    @Test func sittingReadyWithoutHavingWorkedIsNot() {
        #expect(!OrchestratorRelay.reports(from: nil, to: .ready))
        #expect(!OrchestratorRelay.reports(from: nil, to: .done))
        #expect(!OrchestratorRelay.reports(from: .done, to: .ready))
        #expect(!OrchestratorRelay.reports(from: .needsInput, to: .ready))
        #expect(!OrchestratorRelay.reports(from: .failed, to: .done))
    }

    @Test func questionsPermissionPromptsAndErrorsAreNewsFromAnywhere() {
        for before: VerticalTabAgentActivity? in [nil, .ready, .working, .done] {
            #expect(OrchestratorRelay.reports(from: before, to: .needsInput))
            #expect(OrchestratorRelay.reports(from: before, to: .needsPermission))
            #expect(OrchestratorRelay.reports(from: before, to: .failed))
        }
    }

    @Test func startingWorkAndStayingPutAreNot() {
        #expect(!OrchestratorRelay.reports(from: .ready, to: .working))
        #expect(!OrchestratorRelay.reports(from: .needsPermission, to: .working))
        #expect(!OrchestratorRelay.reports(from: .done, to: .done))
        #expect(!OrchestratorRelay.reports(from: .needsPermission, to: .needsPermission))
        #expect(!OrchestratorRelay.reports(from: .failed, to: .failed))
    }

    @Test func aBurstKeepsTheLatestPerPaneInTheOrderTheyHappened() {
        let a = UUID(), b = UUID(), c = UUID()
        let events: [OrchestratorRelay.Event] = [
            .init(pane: a, activity: .needsPermission, detail: "Bash"),
            .init(pane: b, activity: .done, detail: nil),
            .init(pane: a, activity: .done, detail: nil),
            .init(pane: c, activity: .failed, detail: nil),
            .init(pane: b, activity: .needsInput, detail: "Which?"),
        ]
        #expect(OrchestratorRelay.latest(events) == [
            .init(pane: a, activity: .done, detail: nil),
            .init(pane: c, activity: .failed, detail: nil),
            .init(pane: b, activity: .needsInput, detail: "Which?"),
        ])
        #expect(OrchestratorRelay.latest([]).isEmpty)
    }

    @Test func theRelayRemembersEachPanesStatus() {
        let relay = OrchestratorRelay()
        let pane = UUID()
        func info(_ activity: VerticalTabAgentActivity, detail: String? = nil) -> VerticalTabAgentInfo {
            VerticalTabAgentInfo(kind: .claude, activity: activity, task: nil, detail: detail, unseen: false)
        }
        #expect(relay.note(pane, info: info(.ready)) == nil)
        #expect(relay.note(pane, info: info(.working)) == nil)
        #expect(relay.note(pane, info: info(.needsPermission, detail: "Bash: ls")) == .init(pane: pane, activity: .needsPermission, detail: "Bash: ls"))
        #expect(relay.note(pane, info: info(.working)) == nil)
        #expect(relay.note(pane, info: info(.done)) == .init(pane: pane, activity: .done, detail: nil))
        // The same status again says nothing new.
        #expect(relay.note(pane, info: info(.done)) == nil)
        // The agent quit: nothing to report, and the next one starts from nothing.
        #expect(relay.note(pane, info: nil) == nil)
        #expect(relay.last[pane] == nil)
        #expect(relay.note(pane, info: info(.done)) == nil)
    }

    @Test func eventsGatherPerOrchestratorUntilTheyAreSent() {
        let relay = OrchestratorRelay()
        let first = UUID(), second = UUID(), pane = UUID()
        relay.schedule(.init(pane: pane, activity: .done, detail: nil), for: first) { _ in }
        relay.schedule(.init(pane: pane, activity: .needsInput, detail: nil), for: first) { _ in }
        relay.schedule(.init(pane: pane, activity: .done, detail: nil), for: second) { _ in }
        #expect(relay.pending[first]?.count == 2)
        #expect(relay.pending[second]?.count == 1)
        #expect(relay.flush[first] != nil)
        relay.forget(orchestrator: first)
        #expect(relay.pending[first] == nil)
        #expect(relay.flush[first] == nil)
        #expect(relay.pending[second]?.count == 1)
        relay.forget(orchestrator: second)
    }
}
