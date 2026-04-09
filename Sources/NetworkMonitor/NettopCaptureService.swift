import Darwin
import Foundation

protocol NettopStreamProducing: Sendable {
    func makeStream() throws -> NettopStreamHandle
}

struct NettopStreamHandle: Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let stop: @Sendable () async -> Void
}

enum NettopCaptureError: LocalizedError {
    case failedToStart(String)
    case exited(Int32, String)
    case streamEndedUnexpectedly

    var errorDescription: String? {
        switch self {
        case let .failedToStart(reason):
            return "Failed to start nettop: \(reason)"
        case let .exited(code, output) where !output.isEmpty:
            return "nettop exited (\(code)): \(output)"
        case let .exited(code, _):
            return "nettop exited (\(code))."
        case .streamEndedUnexpectedly:
            return "nettop stopped unexpectedly."
        }
    }
}

enum ProcessTerminationPlan {
    static let gracefulShutdownNanoseconds: UInt64 = 500_000_000

    static func stop(
        terminate: @escaping @Sendable () -> Void,
        interrupt: @escaping @Sendable () -> Void,
        forceKill: @escaping @Sendable () -> Void,
        waitForExitWithin: @escaping @Sendable (UInt64) async -> Bool,
        waitForExit: @escaping @Sendable () async -> Void
    ) async {
        terminate()
        if await waitForExitWithin(gracefulShutdownNanoseconds) {
            return
        }

        NetworkMonitorDiagnostics.captureError("Capture process ignored terminate(); sending interrupt.")
        interrupt()
        if await waitForExitWithin(gracefulShutdownNanoseconds) {
            return
        }

        forceKill()
        if await waitForExitWithin(gracefulShutdownNanoseconds) {
            return
        }

        await waitForExit()
    }
}

final class NettopProcessController: @unchecked Sendable {
    let process = Process()
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()

    private let stateLock = NSLock()
    private var exitContinuations: [CheckedContinuation<Void, Never>] = []
    private var didExit = false
    private var stopTask: Task<Void, Never>?

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        process.terminationHandler = { [weak self] _ in
            self?.markExited()
        }
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            throw NettopCaptureError.failedToStart(error.localizedDescription)
        }
    }

    func stop() async {
        let task = withStateLock { () -> Task<Void, Never> in
            if let stopTask {
                return stopTask
            }

            let newTask = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.performStopSequence()
            }
            stopTask = newTask
            return newTask
        }
        await task.value
    }

    func collectStandardError() -> String {
        let data = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func waitForExit() async {
        if !process.isRunning {
            return
        }

        await withCheckedContinuation { continuation in
            stateLock.lock()
            if didExit || !process.isRunning {
                stateLock.unlock()
                continuation.resume()
                return
            }

            exitContinuations.append(continuation)
            stateLock.unlock()
        }
    }

    private func performStopSequence() async {
        defer {
            withStateLock {
                stopTask = nil
            }
        }

        guard process.processIdentifier != 0 || process.isRunning else {
            return
        }

        await ProcessTerminationPlan.stop(
            terminate: { [weak self] in
                guard let self, self.process.isRunning else {
                    return
                }
                self.process.terminate()
            },
            interrupt: { [weak self] in
                guard let self, self.process.isRunning else {
                    return
                }
                self.process.interrupt()
            },
            forceKill: { [weak self] in
                guard let self else {
                    return
                }

                let pid = self.process.processIdentifier
                guard pid > 0 else {
                    return
                }

                NetworkMonitorDiagnostics.captureError("Capture process ignored interrupt(); force killing pid \(pid).")
                Darwin.kill(pid, SIGKILL)
            },
            waitForExitWithin: { [weak self] timeoutNanoseconds in
                guard let self else {
                    return true
                }
                return await self.waitForExit(within: timeoutNanoseconds)
            },
            waitForExit: { [weak self] in
                await self?.waitForExit()
            }
        )
    }

    private func waitForExit(within timeoutNanoseconds: UInt64) async -> Bool {
        if !process.isRunning {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    return true
                }
                await self.waitForExit()
                return true
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let didExit = await group.next() ?? true
            group.cancelAll()
            return didExit
        }
    }

    private func markExited() {
        let continuations = withStateLock { () -> [CheckedContinuation<Void, Never>] in
            didExit = true
            let continuations = exitContinuations
            exitContinuations.removeAll(keepingCapacity: false)
            return continuations
        }

        for continuation in continuations {
            continuation.resume()
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

struct ProcessNettopStreamProducer: NettopStreamProducing {
    var executableURL: URL = URL(fileURLWithPath: "/usr/bin/script")
    var arguments: [String] = ["-q", "-F", "/dev/null", "/usr/bin/nettop", "-P", "-L", "0", "-d", "-x", "-n", "-s", "1"]

    func makeStream() throws -> NettopStreamHandle {
        let controller = NettopProcessController(executableURL: executableURL, arguments: arguments)
        try controller.start()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let readerTask = Task.detached(priority: .utility) {
                do {
                    for try await line in controller.standardOutputPipe.fileHandleForReading.bytes.lines {
                        if Task.isCancelled {
                            break
                        }
                        continuation.yield(line)
                    }

                    await controller.waitForExit()
                    let errorOutput = controller.collectStandardError()

                    if Task.isCancelled || controller.process.terminationStatus == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: NettopCaptureError.exited(controller.process.terminationStatus, errorOutput))
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                readerTask.cancel()
                Task {
                    await controller.stop()
                }
            }
        }

        return NettopStreamHandle(
            lines: stream,
            stop: {
                await controller.stop()
            }
        )
    }
}

actor NettopCaptureService {
    typealias SleepFunction = @Sendable (UInt64) async -> Void
    typealias NowFunction = @Sendable () -> Date

    nonisolated let events: AsyncStream<CaptureEvent>

    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let producer: any NettopStreamProducing
    private let restartDelayNanoseconds: UInt64
    private let terminalStartupFailureThreshold: Int
    private let sleep: SleepFunction
    private let now: NowFunction

    private var runnerTask: Task<Void, Never>?
    private var currentStopHandler: (@Sendable () async -> Void)?
    private var stopRequested = false
    private var consecutiveFailureCount = 0
    private var lastSuccessfulCaptureAt: Date?

    init(
        producer: any NettopStreamProducing = ProcessNettopStreamProducer(),
        restartDelayNanoseconds: UInt64 = 2_000_000_000,
        terminalStartupFailureThreshold: Int = 3,
        sleep: @escaping SleepFunction = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping NowFunction = Date.init
    ) {
        var streamContinuation: AsyncStream<CaptureEvent>.Continuation?
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation!
        self.producer = producer
        self.restartDelayNanoseconds = restartDelayNanoseconds
        self.terminalStartupFailureThreshold = terminalStartupFailureThreshold
        self.sleep = sleep
        self.now = now
    }

    func start() {
        guard runnerTask == nil else {
            return
        }

        stopRequested = false
        consecutiveFailureCount = 0
        continuation.yield(.starting)
        NetworkMonitorDiagnostics.capture("Starting capture loop.")
        runnerTask = Task {
            await self.runLoop()
        }
    }

    func stop() async {
        await requestStop(emitStopped: true)
    }

    func restart() async {
        NetworkMonitorDiagnostics.capture("Restart requested.")
        await requestStop(emitStopped: false)
        stopRequested = false
        consecutiveFailureCount = 0
        continuation.yield(.starting)
        NetworkMonitorDiagnostics.capture("Restarting capture loop.")
        runnerTask = Task {
            await self.runLoop()
        }
    }

    private func runLoop() async {
        defer {
            runnerTask = nil
            currentStopHandler = nil
        }

        while !Task.isCancelled && !stopRequested {
            var emittedSnapshotThisAttempt = false
            do {
                let handle = try producer.makeStream()
                currentStopHandler = handle.stop

                var parser = NettopCSVStreamParser()
                do {
                    for try await line in handle.lines {
                        if Task.isCancelled || stopRequested {
                            break
                        }

                        for snapshot in parser.consume(line: line) {
                            emittedSnapshotThisAttempt = true
                            consecutiveFailureCount = 0
                            lastSuccessfulCaptureAt = snapshot.capturedAt
                            NetworkMonitorDiagnostics.capture("Received snapshot with \(snapshot.processes.count) active processes.")
                            continuation.yield(.snapshot(snapshot))
                        }
                    }
                } catch {
                    if let finalSnapshot = parser.finish() {
                        emittedSnapshotThisAttempt = true
                        consecutiveFailureCount = 0
                        lastSuccessfulCaptureAt = finalSnapshot.capturedAt
                        continuation.yield(.snapshot(finalSnapshot))
                    }
                    currentStopHandler = nil
                    throw error
                }

                if let finalSnapshot = parser.finish() {
                    emittedSnapshotThisAttempt = true
                    consecutiveFailureCount = 0
                    lastSuccessfulCaptureAt = finalSnapshot.capturedAt
                    continuation.yield(.snapshot(finalSnapshot))
                }

                currentStopHandler = nil
                guard !stopRequested && !Task.isCancelled else {
                    break
                }

                throw NettopCaptureError.streamEndedUnexpectedly
            } catch is CancellationError {
                break
            } catch {
                guard !stopRequested && !Task.isCancelled else {
                    break
                }

                consecutiveFailureCount = emittedSnapshotThisAttempt ? 1 : consecutiveFailureCount + 1
                let recovery = CaptureRecoveryState(
                    message: error.localizedDescription,
                    attempt: consecutiveFailureCount,
                    nextRetryDate: now().addingTimeInterval(TimeInterval(restartDelayNanoseconds) / 1_000_000_000),
                    lastSuccessfulCaptureAt: lastSuccessfulCaptureAt
                )

                if shouldStopAfter(error: error, emittedSnapshotThisAttempt: emittedSnapshotThisAttempt) {
                    NetworkMonitorDiagnostics.captureError("Capture failed permanently: \(error.localizedDescription)")
                    continuation.yield(.failed(error.localizedDescription))
                    break
                }

                NetworkMonitorDiagnostics.captureError("Capture will retry after error: \(error.localizedDescription)")
                continuation.yield(.retrying(recovery))
                await sleep(restartDelayNanoseconds)

                guard !stopRequested && !Task.isCancelled else {
                    break
                }

                continuation.yield(.starting)
            }
        }
    }

    private func requestStop(emitStopped: Bool) async {
        stopRequested = true

        let stopHandler = currentStopHandler
        currentStopHandler = nil

        let runner = runnerTask
        runnerTask = nil
        runner?.cancel()

        if let stopHandler {
            await stopHandler()
        }

        if let runner {
            await runner.value
        }

        if emitStopped {
            NetworkMonitorDiagnostics.capture("Capture stopped.")
            continuation.yield(.stopped)
        }
    }

    private func shouldStopAfter(error: Error, emittedSnapshotThisAttempt: Bool) -> Bool {
        guard !emittedSnapshotThisAttempt, lastSuccessfulCaptureAt == nil else {
            return false
        }

        guard consecutiveFailureCount >= terminalStartupFailureThreshold else {
            return false
        }

        if case NettopCaptureError.failedToStart = error {
            return true
        }

        return false
    }
}
