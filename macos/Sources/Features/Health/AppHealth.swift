#if os(macOS)
import AppKit
import MetricKit
import UserNotifications
import os

/// Watches the app itself: how much memory it holds and whether its main thread answers.
/// Before this, a part of the app that ran away (a loop that never ended, a list that only
/// grew) went unnoticed until macOS ran out of memory, and left nothing behind to find it by.
///
/// It samples on its own queue, so it keeps working while the main thread is stuck, and it
/// writes a report to `~/.ghostty-extreme/health` when something is wrong. A report holds
/// numbers about the app and the names of its own steps; nothing from terminals, files or
/// folders, and it never leaves the Mac unless the user attaches it to an issue.
final class AppHealth: NSObject, MXMetricManagerSubscriber {
    static let shared = AppHealth()
    static let folder = AgentTools.root.appendingPathComponent("health", isDirectory: true)

    /// What the rest of the app may know about its health, safe to read from any thread.
    struct Snapshot: Equatable {
        var verdict = HealthVerdict.fine
        var footprint: UInt64 = 0
        var stalls = 0
        var longestStall: Double = 0
        var longestStallDuring: String?
    }

    /// How many samples and stalls are kept: an hour of memory, the last fifty stalls.
    static let sampleLimit = 360
    static let stallLimit = 50
    /// Seconds between memory samples, and between looks at the caches' sizes.
    private static let sampleEvery = 10
    private static let cachesEvery = 60
    /// A stall this long gets a report while it's still going, in case the app is force quit.
    private static let reportStallAfter: TimeInterval = 10

    private static let log = StoredFile.logger("health")
    private static let sharedState = OSAllocatedUnfairLock(initialState: Snapshot())
    private static let crumb = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let gauges = OSAllocatedUnfairLock(uncheckedState: [String: () -> Int]())

    private let queue = DispatchQueue(label: "com.steventsvik.ghostty-extreme.health", qos: .utility)
    private let judge = HealthJudge(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    private let started = Date()
    private var timer: DispatchSourceTimer?
    // Everything below is only touched on `queue`.
    private var samples: [HealthSample] = []
    private var stalls: [HealthStall] = []
    private var caches: [String: Int] = [:]
    private var watch = StallWatch()
    private var ticks = 0
    private var reportedSeverity = 0
    private var notified = false
    private var stallReported = false

    // MARK: For the rest of the app

    static var snapshot: Snapshot { sharedState.withLock { $0 } }

    /// Says which of the app's own steps is starting, so a stall can be put down to it.
    static func breadcrumb(_ what: StaticString) {
        crumb.withLock { $0 = "\(what)" }
    }

    /// Lists a cache in the reports by how many entries it holds. `count` is asked on the
    /// main thread, where the caches live.
    static func gauge(_ name: String, _ count: @escaping () -> Int) {
        gauges.withLockUnchecked { $0[name] = count }
    }

    /// Starts watching. Once, when the first window is up.
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            MXMetricManager.shared.add(self)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
        Self.simulateIfAsked()
    }

    /// Writes a report now and hands back where it went, on the main thread.
    func saveReport(reason: String, then: @escaping (URL?) -> Void) {
        queue.async {
            let url = self.save(reason: reason)
            DispatchQueue.main.async { then(url) }
        }
    }

    /// Writes a report and packs the whole health folder into one file to attach to an
    /// issue, then shows it in the Finder.
    func exportForIssue(then: @escaping (URL?) -> Void) {
        queue.async {
            self.save(reason: "saved for an issue")
            let destination = AgentTools.root.appendingPathComponent("Tellurion-health-\(StoredFile.stamp()).zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", Self.folder.path, destination.path]
            let result = ProcessRunner.run(ditto, timeout: 60)
            let made = result.status == 0 && FileManager.default.fileExists(atPath: destination.path)
            if made {
                StoredFile.prune(in: AgentTools.root, prefix: "Tellurion-health-", keep: 3)
            } else {
                Self.log.error("Couldn't pack the health reports (ditto ended with \(result.status, privacy: .public))")
            }
            DispatchQueue.main.async {
                if made { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                then(made ? destination : nil)
            }
        }
    }

    /// Quits and opens the app again. Quitting goes the usual way, so the question about
    /// running programs is still asked; if the user says no there, nothing reopens.
    static func restart() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", """
            i=0
            while kill -0 "$1" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done
            kill -0 "$1" 2>/dev/null || /usr/bin/open "$2"
            """, "sh", String(pid), Bundle.main.bundlePath]
        relaunch.environment = EventToken.scrubbed(ProcessInfo.processInfo.environment)
        do {
            try relaunch.run()
        } catch {
            log.error("Couldn't arrange to reopen: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Watching (on the queue)

    private func tick() {
        let now = Date()
        ticks += 1
        if watch.tick(now: now) {
            stallReported = false
            DispatchQueue.main.async {
                let answered = Date()
                self.queue.async { self.mainThreadAnswered(answered) }
            }
        } else if let waited = watch.waiting(now: now), waited >= Self.reportStallAfter, !stallReported {
            stallReported = true
            save(reason: "the main thread has not answered for \(Int(waited)) s")
        }
        if ticks % Self.sampleEvery == 1 { sample(now) }
        if ticks % Self.cachesEvery == 1 {
            DispatchQueue.main.async {
                let counts = Self.gauges.withLockUnchecked { $0 }.mapValues { $0() }
                self.queue.async { self.caches = counts }
            }
        }
    }

    private func mainThreadAnswered(_ time: Date) {
        guard let seconds = watch.answered(now: time) else { return }
        let stall = HealthStall(time: time.addingTimeInterval(-seconds), seconds: (seconds * 10).rounded() / 10,
                                during: Self.crumb.withLock { $0 })
        stalls.append(stall)
        if stalls.count > Self.stallLimit { stalls.removeFirst(stalls.count - Self.stallLimit) }
        Self.log.error("The main thread didn't answer for \(stall.seconds, privacy: .public) s (last step: \(stall.during ?? "unknown", privacy: .public))")
        publish()
        if seconds >= 5 { save(reason: "the main thread did not answer for \(Int(seconds)) s") }
        DispatchQueue.main.async { SetupChecks.shared.refresh() }
    }

    private func sample(_ now: Date) {
        samples.append(HealthSample(time: now, footprint: Self.simulated ?? Self.footprint()))
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
        let verdict = judge.verdict(samples)
        let changed = Self.snapshot.verdict.name != verdict.name
        publish()
        if verdict.severity > reportedSeverity {
            let size = HealthJudge.size(samples.last?.footprint ?? 0)
            Self.log.error("Memory is \(verdict.name, privacy: .public): \(size, privacy: .public)")
            save(reason: "memory is \(verdict.name)")
        }
        reportedSeverity = verdict.severity
        if case .critical(let bytes) = verdict, !notified {
            notified = true
            Self.notify(bytes)
        }
        if changed { DispatchQueue.main.async { SetupChecks.shared.refresh() } }
    }

    private func publish() {
        let longest = stalls.max { $0.seconds < $1.seconds }
        let snapshot = Snapshot(verdict: judge.verdict(samples), footprint: samples.last?.footprint ?? 0, stalls: stalls.count,
                                longestStall: longest?.seconds ?? 0, longestStallDuring: longest?.during)
        Self.sharedState.withLock { $0 = snapshot }
    }

    // MARK: Reports

    @discardableResult
    private func save(reason: String) -> URL? {
        let report = HealthReport(
            written: Date(), reason: reason,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString, model: Self.model,
            physicalMemory: ProcessInfo.processInfo.physicalMemory, uptime: Date().timeIntervalSince(started).rounded(),
            verdict: judge.verdict(samples).name, footprint: samples.last?.footprint ?? Self.footprint(),
            samples: samples, stalls: stalls, caches: caches, mainThreadWork: OffMain.counts)
        let url = Self.folder.appendingPathComponent("report-\(StoredFile.stamp()).json")
        guard StoredFile.write(json: report, to: url, what: "the health report", log: Self.log, encoder: Self.encoder) else { return nil }
        StoredFile.prune(in: Self.folder, prefix: "report-", keep: 20)
        TestHooks.note("health report: \(reason)")
        return url
    }

    static var encoder: JSONEncoder {
        let encoder = StoredFile.encoder
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Apple's own hang and crash diagnostics for the app, delivered some time after they
    /// happen (often at the next launch). Kept beside the reports.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async {
            for (index, payload) in payloads.enumerated() {
                let url = Self.folder.appendingPathComponent("diagnostic-\(StoredFile.stamp())-\(index + 1).json")
                StoredFile.write(payload.jsonRepresentation(), to: url, what: "a diagnostic from macOS", log: Self.log)
            }
            StoredFile.prune(in: Self.folder, prefix: "diagnostic-", keep: 10)
        }
    }

    private static func notify(_ bytes: UInt64) {
        let content = UNMutableNotificationContent()
        content.title = "Tellurion is using \(HealthJudge.size(bytes)) of memory"
        content.body = "That's far more than it should. Open Check Setup to save a report and restart Tellurion."
        let request = UNNotificationRequest(identifier: "tellurion-health", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("Couldn't post the memory warning: \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Measuring

    /// The memory the app is charged for, as Activity Monitor shows it.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(cString: value)
    }()

    // MARK: Test copies

    /// `TELLURION_TEST_HEALTH=critical`: every sample reads as half the Mac's memory.
    private static let simulated: UInt64? = TestHooks.health == "critical" ? ProcessInfo.processInfo.physicalMemory / 2 : nil

    /// `TELLURION_TEST_HEALTH=stall`: the main thread is held for 6 s, once, shortly after launch.
    private static func simulateIfAsked() {
        guard TestHooks.health == "stall" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            AppHealth.breadcrumb("a stall made for a test")
            Thread.sleep(forTimeInterval: 6)
        }
    }
}
#endif
