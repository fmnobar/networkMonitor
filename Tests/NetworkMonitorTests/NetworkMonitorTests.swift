import Testing
@testable import NetworkMonitor
import Foundation

@Test
func parserFlushesOnRepeatedHeadersAndHandlesDottedNames() {
    var parser = NettopCSVStreamParser(now: { Date(timeIntervalSince1970: 1_000) })

    let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
    let lines = [
        header,
        "18:04:43.912151,com.apple.WebKit.Networking.1398,,,1024,2048,0,0,0,,,,,,,,,,,",
        "18:04:43.912385,malformed-row,,,oops,12",
        "18:04:43.912538,Helper.2000,,,0,0,0,0,0,,,,,,,,,,,",
        header
    ]

    let snapshots = lines.flatMap { parser.consume(line: $0) }

    #expect(snapshots.count == 1)
    #expect(snapshots[0].processes.count == 1)
    #expect(snapshots[0].processes[0].name == "com.apple.WebKit.Networking")
    #expect(snapshots[0].processes[0].pid == 1398)
    #expect(snapshots[0].processes[0].downloadBytesPerSecond == 1024)
    #expect(snapshots[0].processes[0].uploadBytesPerSecond == 2048)
    #expect(snapshots[0].processes[0].shareOfTotal == 1)
}

@Test
func parserAggregatesDuplicateProcessesAndComputesShares() {
    var parser = NettopCSVStreamParser(now: { Date(timeIntervalSince1970: 2_000) })

    let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
    _ = parser.consume(line: header)
    _ = parser.consume(line: "18:04:43.912151,Safari.1288,,,1000,500,0,0,0,,,,,,,,,,,")
    _ = parser.consume(line: "18:04:43.912385,Safari.1288,,,500,500,0,0,0,,,,,,,,,,,")
    _ = parser.consume(line: "18:04:43.912538,ChatGPT.35185,,,100,100,0,0,0,,,,,,,,,,,")

    let snapshot = parser.finish()

    #expect(snapshot != nil)
    #expect(snapshot?.totalDownloadBytesPerSecond == 1600)
    #expect(snapshot?.totalUploadBytesPerSecond == 1100)
    #expect(snapshot?.processes.count == 2)
    #expect(snapshot?.processes.first?.name == "Safari")
    #expect(snapshot?.processes.first?.totalBytesPerSecond == 2500)
    #expect(snapshot?.processes.first?.shareOfTotal == Double(2500) / Double(2700))
}

@MainActor
@Test
func storeFiltersAndSortsDisplayedProcesses() {
    let store = TrafficDashboardStore(captureService: NettopCaptureService(producer: MockProducer(scripts: [])))
    let snapshot = LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 3_000),
        totalDownloadBytesPerSecond: 900,
        totalUploadBytesPerSecond: 600,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 600, uploadBytesPerSecond: 200, totalBytesPerSecond: 800, shareOfTotal: 0.53, lastSeen: Date(timeIntervalSince1970: 3_000)),
            ProcessUsage(pid: 2, name: "Codex", downloadBytesPerSecond: 300, uploadBytesPerSecond: 400, totalBytesPerSecond: 700, shareOfTotal: 0.47, lastSeen: Date(timeIntervalSince1970: 3_000))
        ]
    )

    store.consume(.snapshot(snapshot))
    #expect(store.displayedProcesses.map(\.name) == ["Safari", "Codex"])

    store.searchText = "2"
    #expect(store.displayedProcesses.map(\.name) == ["Codex"])

    store.searchText = ""
    store.sortOrder = [KeyPathComparator(\ProcessUsage.name, order: .forward)]
    #expect(store.displayedProcesses.map(\.name) == ["Codex", "Safari"])
}

@Test
func captureServiceRestartsAfterFailure() async throws {
    let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
    let producer = MockProducer(
        scripts: [
            .failure([], MockError.boom),
            .failure(
                [
                    header,
                    "18:04:43.912151,Safari.1288,,,100,50,0,0,0,,,,,,,,,,,"
                ],
                MockError.stopAfterSnapshot
            )
        ]
    )

    let service = NettopCaptureService(
        producer: producer,
        restartDelayNanoseconds: 0,
        sleep: { _ in }
    )

    let recorder = EventRecorder()
    let eventTask = Task {
        for await event in service.events {
            await recorder.record(event)
            if await recorder.hasRecoveredSnapshot {
                await service.stop()
                break
            }
        }
    }

    await service.start()
    try await Task.sleep(nanoseconds: 200_000_000)
    eventTask.cancel()

    let events = await recorder.events
    #expect(events.contains(where: { if case .failed = $0 { return true } else { return false } }))
    #expect(events.filter { if case .starting = $0 { return true } else { return false } }.count >= 2)
    #expect(events.contains(where: { if case .snapshot = $0 { return true } else { return false } }))
}

private enum MockError: Error {
    case boom
    case stopAfterSnapshot
}

private final class MockProducer: NettopStreamProducing, @unchecked Sendable {
    enum Script {
        case finish([String])
        case failure([String], Error)
    }

    private let lock = NSLock()
    private var scripts: [Script]

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func makeStream() throws -> NettopStreamHandle {
        lock.lock()
        defer { lock.unlock() }

        let script = scripts.isEmpty ? .failure([], MockError.boom) : scripts.removeFirst()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task.detached {
                switch script {
                case let .finish(lines):
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()

                case let .failure(lines, error):
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return NettopStreamHandle(lines: stream, stop: {})
    }
}

private actor EventRecorder {
    private(set) var events: [CaptureEvent] = []

    var hasRecoveredSnapshot: Bool {
        let failed = events.contains { if case .failed = $0 { return true } else { return false } }
        let restarted = events.filter { if case .starting = $0 { return true } else { return false } }.count >= 2
        let snapshotted = events.contains { if case .snapshot = $0 { return true } else { return false } }
        return failed && restarted && snapshotted
    }

    func record(_ event: CaptureEvent) {
        events.append(event)
    }
}
