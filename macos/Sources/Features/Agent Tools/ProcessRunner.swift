#if os(macOS)
import Foundation

/// Runs a program the app starts by itself (git, gh, a provider's CLI) to the end and
/// collects what it wrote.
///
/// Both of its outputs are read as they arrive, so a program that writes a lot to one before
/// the other can't fill a pipe and wait forever, and neither can one whose input is larger
/// than a pipe holds. It never runs longer than `timeout`: it's asked to stop, then killed.
/// A program that has exited but left something behind holding its pipes isn't waited for.
enum ProcessRunner {
    struct Output {
        /// The exit status; -1 when the program couldn't be started.
        let status: Int32
        let stdout: Data
        let stderr: Data
        /// It ran out of time and was stopped.
        var timedOut = false
        /// Why it couldn't be started.
        var launchError: String?

        var ok: Bool { status == 0 && !timedOut && launchError == nil }
        var text: String { String(decoding: stdout, as: UTF8.self) }
        var errorText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// How long a stopped program gets to exit before it's killed.
    static let stopGrace: TimeInterval = 2

    /// Runs `process` (configured, not yet started) and waits for it. `input` is fed to its
    /// standard input; without one it reads nothing. With no environment set, it gets the
    /// app's own without the event token. `discardingError` sends its standard error nowhere.
    /// Blocks the calling thread: call off the main thread for anything that can be slow.
    static func run(_ process: Process, input: Data? = nil, timeout: TimeInterval, discardingError: Bool = false) -> Output {
        if process.environment == nil {
            process.environment = EventToken.scrubbed(ProcessInfo.processInfo.environment)
        }
        let out = Pipe()
        let err: Pipe? = discardingError ? nil : Pipe()
        let feed: Pipe? = input == nil ? nil : Pipe()
        process.standardOutput = out
        if let err { process.standardError = err } else { process.standardError = FileHandle.nullDevice }
        if let feed { process.standardInput = feed } else { process.standardInput = FileHandle.nullDevice }
        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: Data(), stderr: Data(), launchError: "\(error)")
        }

        if let feed, let input {
            let handle = feed.fileHandleForWriting
            // If the program exits without reading it all, the write fails instead of
            // raising SIGPIPE in the app.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            // Its own thread, not a shared queue: when every queue thread is busy (many of
            // these running at once), the input would never be written and the program
            // would wait for it until the timeout.
            Thread.detachNewThread {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }

        var streams = [Captured(fd: out.fileHandleForReading.fileDescriptor)]
        if let err { streams.append(Captured(fd: err.fileHandleForReading.fileDescriptor)) }
        var deadline = Date().addingTimeInterval(max(timeout, 0))
        var stage = Stage.running
        var timedOut = false
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while streams.contains(where: \.open) {
            var polled = streams.filter(\.open).map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&polled, nfds_t(polled.count), 100)
            if ready > 0 {
                for item in polled where item.revents != 0 {
                    guard let index = streams.firstIndex(where: { $0.fd == item.fd }) else { continue }
                    let count = buffer.withUnsafeMutableBytes { read(item.fd, $0.baseAddress, $0.count) }
                    if count > 0 {
                        streams[index].data.append(contentsOf: buffer[0..<count])
                    } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                        streams[index].open = false
                    }
                }
            } else if ready == 0, !process.isRunning {
                // It has exited and nothing more is coming: whatever still holds a pipe open
                // (something it left running) isn't waited for.
                break
            }
            guard Date() >= deadline else { continue }
            switch stage {
            case .running:
                timedOut = true
                if process.isRunning { process.terminate() }
                stage = .stopping
                deadline = Date().addingTimeInterval(stopGrace)
            case .stopping:
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                stage = .killed
                deadline = Date().addingTimeInterval(stopGrace)
            case .killed:
                for index in streams.indices { streams[index].open = false }
            }
        }

        // Its pipes are closed; it may still be running (it closed them itself).
        while process.isRunning {
            if Date() >= deadline {
                if stage == .running {
                    timedOut = true
                    process.terminate()
                    stage = .stopping
                    deadline = Date().addingTimeInterval(stopGrace)
                } else {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    break
                }
            }
            usleep(20_000)
        }
        return Output(status: process.terminationStatus, stdout: streams[0].data,
                      stderr: streams.count > 1 ? streams[1].data : Data(), timedOut: timedOut)
    }

    private enum Stage { case running, stopping, killed }

    private struct Captured {
        let fd: Int32
        var data = Data()
        var open = true
    }
}
#endif
