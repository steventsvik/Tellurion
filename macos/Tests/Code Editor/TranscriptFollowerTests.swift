import Foundation
import Testing
@testable import Ghostty

/// Finding an agent's transcript from the main thread (AgentTranscriptFollower): the last
/// answer comes back at once, and the look on disk happens on a queue.
@MainActor struct TranscriptFollowerTests {
    private func info(_ kind: VerticalTabAgentKind, transcript: String?, session: String? = nil) -> VerticalTabAgentInfo {
        var info = VerticalTabAgentInfo(kind: kind, activity: .ready, task: nil, detail: nil, unseen: false, transcriptPath: transcript)
        info.codexSessionID = session
        return info
    }

    @Test func whatTheHooksReportedIsTheAnswerAtOnce() {
        let follower = AgentTranscriptFollower()
        let path = follower.transcript(for: info(.claude, transcript: "/tmp/reported.jsonl"), in: "/tmp") {}
        #expect(path == "/tmp/reported.jsonl")
        // A different report: a different answer, not the old one.
        let next = follower.transcript(for: info(.claude, transcript: "/tmp/other.jsonl"), in: "/tmp") {}
        #expect(next == "/tmp/other.jsonl")
    }

    @Test func aCodexSessionKnownByItsIdWaitsForTheLook() {
        let follower = AgentTranscriptFollower()
        let session = UUID().uuidString
        // The report may be another session's, so it isn't believed until it's checked.
        let path = follower.transcript(for: info(.codex, transcript: "/tmp/someone-elses.jsonl", session: session), in: "/tmp") {}
        #expect(path == nil)
    }

    @Test func nothingReportedAndNothingOnDiskIsNoAnswerAndNoNews() async {
        let follower = AgentTranscriptFollower()
        var news = 0
        let folder = "/tmp/no-such-project-\(UUID().uuidString)"
        let path = follower.transcript(for: info(.claude, transcript: nil), in: folder) { news += 1 }
        #expect(path == nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(news == 0)
        follower.reset()
        #expect(follower.transcript(for: info(.claude, transcript: nil), in: folder) {} == nil)
    }
}
