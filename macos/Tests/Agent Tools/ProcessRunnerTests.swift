import Foundation
import Testing
@testable import Ghostty

/// Running a program to the end (ProcessRunner): large output on either pipe, large input,
/// and a program that never finishes.
struct ProcessRunnerTests {
    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    @Test func collectsOutputAndStatus() {
        let result = ProcessRunner.run(shell("printf out; printf err >&2; exit 3"), timeout: 10)
        #expect(result.status == 3)
        #expect(result.text == "out")
        #expect(result.errorText == "err")
        #expect(!result.timedOut)
        #expect(!result.ok)
    }

    /// More than a pipe holds on standard error before anything on standard output: reading
    /// one to the end and then the other would wait forever.
    @Test func aLotOfErrorOutputBeforeOutputDoesNotBlock() {
        let script = "head -c 300000 /dev/zero | tr '\\0' e >&2; head -c 300000 /dev/zero | tr '\\0' o"
        let result = ProcessRunner.run(shell(script), timeout: 30)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.stdout.count == 300_000)
        #expect(result.stderr.count == 300_000)
        #expect(result.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
        #expect(result.stderr.allSatisfy { $0 == UInt8(ascii: "e") })
    }

    /// Input larger than a pipe holds, echoed back: writing it all before reading would
    /// wait forever.
    @Test func aLotOfInputComesBackThroughCat() {
        let input = Data((0..<400_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let result = ProcessRunner.run(process, input: input, timeout: 30)
        #expect(result.status == 0)
        #expect(result.stdout == input)
    }

    @Test func aProgramThatIgnoresItsInputIsFine() {
        let input = Data(repeating: 0x61, count: 400_000)
        let result = ProcessRunner.run(shell("printf done"), input: input, timeout: 30)
        #expect(result.status == 0)
        #expect(result.text == "done")
    }

    @Test func aProgramThatNeverFinishesIsStopped() {
        let started = Date()
        let result = ProcessRunner.run(shell("printf before; exec sleep 60"), timeout: 0.5)
        #expect(result.timedOut)
        #expect(!result.ok)
        #expect(result.text == "before")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// A program that exits but leaves something running with its pipes open isn't waited for.
    @Test func whatAProgramLeavesRunningIsNotWaitedFor() {
        let started = Date()
        let result = ProcessRunner.run(shell("sleep 15 & printf started"), timeout: 20)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.text == "started")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aProgramThatIsNotThereSaysSo() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/tool-\(UUID().uuidString)")
        let result = ProcessRunner.run(process, timeout: 5)
        #expect(result.status == -1)
        #expect(result.launchError != nil)
    }

    @Test func theEventTokenIsNotPassedOn() {
        if ProcessInfo.processInfo.environment[EventToken.environmentKey] == nil { EventToken.install() }
        let result = ProcessRunner.run(shell("printf '%s' \"${\(EventToken.environmentKey):-none}\""), timeout: 10)
        #expect(result.text == "none")
    }

    @Test func standardErrorCanBeDiscarded() {
        let result = ProcessRunner.run(shell("printf err >&2; printf out"), timeout: 10, discardingError: true)
        #expect(result.text == "out")
        #expect(result.stderr.isEmpty)
    }
}
