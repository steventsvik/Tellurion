import Foundation
import Testing
@testable import Ghostty

/// The app's view of its own health: what its memory samples amount to (HealthJudge), when
/// the main thread counts as stalled (StallWatch), and how Check Setup words it.
struct HealthJudgeTests {
    private let gigabyte = HealthJudge.gigabyte
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// One sample every ten seconds, as the app takes them.
    private func samples(_ footprints: [UInt64]) -> [HealthSample] {
        footprints.enumerated().map { HealthSample(time: start.addingTimeInterval(Double($0.offset) * 10), footprint: $0.element) }
    }

    @Test func theLimitsFollowTheMac() {
        let big = HealthJudge(physicalMemory: 64 * gigabyte)
        #expect(big.warning == 16 * gigabyte)
        #expect(big.critical == 32 * gigabyte)
        // A small Mac still gets room for a terminal with many tabs.
        let small = HealthJudge(physicalMemory: 8 * gigabyte)
        #expect(small.warning == 4 * gigabyte)
        #expect(small.critical == 8 * gigabyte)
    }

    @Test func steadyMemoryIsFine() {
        let judge = HealthJudge(physicalMemory: 36 * gigabyte)
        #expect(judge.verdict([]) == .fine)
        #expect(judge.verdict(samples(Array(repeating: gigabyte / 2, count: 60))) == .fine)
    }

    @Test func highAndCriticalGoByTheLatestSample() {
        let judge = HealthJudge(physicalMemory: 36 * gigabyte)
        #expect(judge.verdict(samples([gigabyte, 10 * gigabyte])) == .high(10 * gigabyte))
        #expect(judge.verdict(samples([gigabyte, 20 * gigabyte])) == .critical(20 * gigabyte))
        // Back down again: fine again.
        #expect(judge.verdict(samples([20 * gigabyte, gigabyte])) == .fine)
    }

    @Test func growthThroughTheWholeStretchIsClimbingLongBeforeItIsHigh() {
        let judge = HealthJudge(physicalMemory: 36 * gigabyte)
        // 50 MB every ten seconds for five minutes: 1.5 GB, from 1 GB to 2.5 GB.
        let rising = (0...30).map { gigabyte + UInt64($0) * 50 * 1_048_576 }
        #expect(judge.verdict(samples(rising)) == .climbing(by: 30 * 50 * 1_048_576, over: 300))
    }

    @Test func aBurstAtLaunchIsNotClimbing() {
        let judge = HealthJudge(physicalMemory: 36 * gigabyte)
        // Two gigabytes in the first minute, then level: loading, not a leak.
        let burst = (0...6).map { UInt64($0) * gigabyte / 3 } + Array(repeating: 2 * gigabyte, count: 30)
        #expect(judge.verdict(samples(burst)) == .fine)
        // And too little history says nothing yet, however steep.
        #expect(judge.verdict(samples([gigabyte, 2 * gigabyte, 3 * gigabyte])) == .fine)
    }

    @Test func growthThatStopsOrDipsIsNotClimbing() {
        let judge = HealthJudge(physicalMemory: 36 * gigabyte)
        // Up 1.5 GB, but the last two minutes are level.
        let levelled = (0...18).map { gigabyte + UInt64($0) * 80 * 1_048_576 } + Array(repeating: gigabyte + 18 * 80 * 1_048_576, count: 12)
        #expect(judge.verdict(samples(levelled)) == .fine)
        // Slow growth under the amount that counts.
        let slow = (0...30).map { gigabyte + UInt64($0) * 10 * 1_048_576 }
        #expect(judge.verdict(samples(slow)) == .fine)
    }

    @Test func sizesReadTheWayPeopleSayThem() {
        #expect(HealthJudge.size(412 * 1_048_576) == "412 MB")
        #expect(HealthJudge.size(77 * gigabyte + gigabyte * 4 / 10) == "77.4 GB")
        #expect(HealthJudge.size(0) == "0 MB")
    }

    @Test func aShortWaitIsNotAStall() {
        var watch = StallWatch()
        let sent = watch.tick(now: start)
        #expect(sent)
        #expect(watch.waiting(now: start.addingTimeInterval(1)) == nil)
        let stall = watch.answered(now: start.addingTimeInterval(1.5))
        #expect(stall == nil)
    }

    @Test func aLongWaitIsAStallOfThatLength() {
        var watch = StallWatch()
        let first = watch.tick(now: start)
        // No second ping while the first is unanswered.
        let second = watch.tick(now: start.addingTimeInterval(1))
        #expect(first && !second)
        #expect(watch.waiting(now: start.addingTimeInterval(12)) == 12)
        let stall = watch.answered(now: start.addingTimeInterval(113))
        #expect(stall == 113)
        // Answered: watching starts over.
        #expect(watch.waiting(now: start.addingTimeInterval(114)) == nil)
        let again = watch.tick(now: start.addingTimeInterval(114))
        let quick = watch.answered(now: start.addingTimeInterval(114.1))
        #expect(again)
        #expect(quick == nil)
    }

    @Test func anAnswerWithNoPingMeansNothing() {
        var watch = StallWatch()
        let stall = watch.answered(now: start)
        #expect(stall == nil)
    }

    @Test func checkSetupSaysHowTheAppIsDoing() {
        let healthy = SetupChecks.healthCheck(.init(verdict: .fine, footprint: 400 * 1_048_576))
        #expect(healthy.status == .ok)
        #expect(healthy.title == "Tellurion is healthy")
        #expect(healthy.detail == "Using 400 MB; it hasn't frozen this launch")
        #expect(healthy.fix == .saveHealthReport)
        #expect(healthy.alternative == nil)

        let froze = SetupChecks.healthCheck(.init(verdict: .fine, footprint: gigabyte, stalls: 2, longestStall: 113,
                                                  longestStallDuring: "running a program"))
        #expect(froze.status == .warning)
        #expect(froze.detail == "Using 1.0 GB; it froze 2 times this launch, at longest for 113 s, during running a program")

        let blip = SetupChecks.healthCheck(.init(verdict: .fine, footprint: gigabyte, stalls: 1, longestStall: 3))
        #expect(blip.status == .info)

        let climbing = SetupChecks.healthCheck(.init(verdict: .climbing(by: 3 * gigabyte / 2, over: 300), footprint: 3 * gigabyte))
        #expect(climbing.status == .warning)
        #expect(climbing.title == "Tellurion's memory keeps growing")
        #expect(climbing.detail.hasPrefix("Up 1.5 GB in 5 minutes, now 3.0 GB."))
        #expect(climbing.alternative == .restart)

        let critical = SetupChecks.healthCheck(.init(verdict: .critical(77 * gigabyte), footprint: 77 * gigabyte))
        #expect(critical.status == .problem)
        #expect(critical.title == "Tellurion is using 77.0 GB of memory")
        #expect(critical.fix == .saveHealthReport)
        #expect(critical.alternative == .restart)
    }

    @Test func aReportIsReadableJSONWithItsTimesWrittenOut() throws {
        let report = HealthReport(written: start, reason: "memory is climbing", version: "2.0.0", macOS: "15.1.1", model: "Mac16,6",
                                  physicalMemory: 36 * gigabyte, uptime: 1800, verdict: "climbing", footprint: 3 * gigabyte,
                                  samples: samples([gigabyte, 3 * gigabyte]),
                                  stalls: [HealthStall(time: start, seconds: 113, during: "running a program")],
                                  caches: ["git roots": 12], mainThreadWork: ["running a program (Ghostty/X.swift:1)": 4])
        let text = String(decoding: try AppHealth.encoder.encode(report), as: UTF8.self)
        #expect(text.contains("\"written\" : \"2027-01-15T08:00:00Z\""))
        #expect(text.contains("\"git roots\" : 12"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(HealthReport.self, from: Data(text.utf8))
        #expect(back.stalls == report.stalls)
        #expect(back.samples == report.samples)
    }

    @Test func theAppCanMeasureItself() {
        // Any running app holds some memory; zero would mean the reading failed.
        #expect(AppHealth.footprint() > 1_048_576)
    }
}
