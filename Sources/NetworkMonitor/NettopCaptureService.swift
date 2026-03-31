import Foundation

protocol NettopStreamProducing: Sendable {
    func makeStream() throws -> NettopStreamHandle
}

struct NettopStreamHandle: Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let stop: @Sendable () -> Void
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

final class NettopProcessController: @unchecked Sendable {
    let process = Process()
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            throw NettopCaptureError.failedToStart(error.localizedDescription)
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    func waitForExit() {
        process.waitUntilExit()
    }

    func collectStandardError() -> String {
        let data = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ProcessNettopStreamProducer: NettopStreamProducing {
    var executableURL: URL = URL(fileURLWithPath: "/usr/bin/nettop")
    var arguments: [String] = ["-P", "-L", "0", "-d", "-x", "-n", "-s", "1"]

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

                    controller.waitForExit()
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
                controller.stop()
            }
        }

        return NettopStreamHandle(
            lines: stream,
            stop: {
                controller.stop()
            }
        )
    }
}

actor NettopCaptureService {
    typealias SleepFunction = @Sendable (UInt64) async -> Void

    nonisolated let events: AsyncStream<CaptureEvent>

    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let producer: any NettopStreamProducing
    private let restartDelayNanoseconds: UInt64
    private let sleep: SleepFunction

    private var runnerTask: Task<Void, Never>?
    private var currentStopHandler: (@Sendable () -> Void)?
    private var stopRequested = false

    init(
        producer: any NettopStreamProducing = ProcessNettopStreamProducer(),
        restartDelayNanoseconds: UInt64 = 2_000_000_000,
        sleep: @escaping SleepFunction = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        var streamContinuation: AsyncStream<CaptureEvent>.Continuation?
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            streamContinuation = continuation
        }
        self.continuation = streamContinuation!
        self.producer = producer
        self.restartDelayNanoseconds = restartDelayNanoseconds
        self.sleep = sleep
    }

    func start() {
        guard runnerTask == nil else {
            return
        }

        stopRequested = false
        continuation.yield(.starting)
        runnerTask = Task {
            await self.runLoop()
        }
    }

    func stop() {
        stopRequested = true
        currentStopHandler?()
        currentStopHandler = nil
        runnerTask?.cancel()
        runnerTask = nil
        continuation.yield(.stopped)
    }

    func restart() {
        stop()
        stopRequested = false
        continuation.yield(.starting)
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
                            continuation.yield(.snapshot(snapshot))
                        }
                    }
                } catch {
                    if let finalSnapshot = parser.finish() {
                        continuation.yield(.snapshot(finalSnapshot))
                    }
                    currentStopHandler = nil
                    throw error
                }

                if let finalSnapshot = parser.finish() {
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

                continuation.yield(.failed(error.localizedDescription))
                await sleep(restartDelayNanoseconds)

                guard !stopRequested && !Task.isCancelled else {
                    break
                }

                continuation.yield(.starting)
            }
        }
    }
}
