import Testing
@testable import NetworkMonitor
import AppKit
import CoreGraphics
import Foundation

@Test
func parserFlushesOnRepeatedHeadersAndHandlesDottedNames() {
    var parser = NettopCSVStreamParser(now: { Date(timeIntervalSince1970: 1_000) })

    let header = "\u{04}\u{08}\u{08}time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
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

@Test
func compactStatusLabelUsesBoundedRateFormatting() {
    let snapshot = LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 2_500),
        totalDownloadBytesPerSecond: 125_829_120,
        totalUploadBytesPerSecond: 1_536,
        processes: []
    )

    let label = NetworkFormatting.statusLabel(for: snapshot)

    #expect(label == "↓ 120M ↑ 1.5K")
    #expect(!label.contains("/s"))
    #expect(label.count <= StatusPreviewLayout.statusItemReferenceText.count)
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

@MainActor
@Test
func storePreservesSnapshotWhileRetryingAndMarksStalled() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        stallThreshold: 3,
        now: { Date(timeIntervalSince1970: 4_000) }
    )
    let snapshot = LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 3_995),
        totalDownloadBytesPerSecond: 900,
        totalUploadBytesPerSecond: 600,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 600, uploadBytesPerSecond: 200, totalBytesPerSecond: 800, shareOfTotal: 0.53, lastSeen: Date(timeIntervalSince1970: 3_995))
        ]
    )

    store.consume(.snapshot(snapshot))
    store.consume(.retrying(CaptureRecoveryState(
        message: "nettop exited unexpectedly.",
        attempt: 1,
        nextRetryDate: Date(timeIntervalSince1970: 4_001),
        lastSuccessfulCaptureAt: snapshot.capturedAt
    )))

    let stabilizedSnapshot = store.snapshot
    if case let .retrying(retrySnapshot, status) = store.viewState {
        #expect(retrySnapshot == stabilizedSnapshot)
        #expect(status.attempt == 1)
    } else {
        Issue.record("Expected retrying state")
    }
    #expect(store.displayedProcesses.map(\.name) == ["Safari"])

    store.consume(.snapshot(snapshot))
    store.evaluateStaleness(now: Date(timeIntervalSince1970: 4_000))
    if case let .stalled(stalledSnapshot, _) = store.viewState {
        #expect(stalledSnapshot == store.snapshot)
    } else {
        Issue.record("Expected stalled state")
    }
}

@MainActor
@Test
func storeSmoothsBurstTrafficAndRetainsProcessesBriefly() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        smoothingFactor: 0.5,
        visibilityGracePeriod: 5,
        previewMinimumBytesPerSecond: 1_024
    )
    let firstCaptureTime = Date(timeIntervalSince1970: 5_000)
    let secondCaptureTime = Date(timeIntervalSince1970: 5_001)
    let thirdCaptureTime = Date(timeIntervalSince1970: 5_006)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: firstCaptureTime,
            totalDownloadBytesPerSecond: 2_000,
            totalUploadBytesPerSecond: 0,
            processes: [
                ProcessUsage(pid: 41, name: "Safari", downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 2_000, shareOfTotal: 1, lastSeen: firstCaptureTime)
            ]
        )
    ))

    #expect(store.displayedProcesses.map(\.name) == ["Safari"])
    #expect(store.topFive.map(\.name) == ["Safari"])
    #expect(store.displayedProcesses.first?.totalBytesPerSecond == 2_000)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: secondCaptureTime,
            totalDownloadBytesPerSecond: 0,
            totalUploadBytesPerSecond: 0,
            processes: []
        )
    ))

    #expect(store.displayedProcesses.map(\.name) == ["Safari"])
    #expect(store.displayedProcesses.first?.totalBytesPerSecond == 1_000)
    #expect(store.displayedProcesses.first?.lastSeen == firstCaptureTime)
    #expect(store.topFive.isEmpty)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: thirdCaptureTime,
            totalDownloadBytesPerSecond: 0,
            totalUploadBytesPerSecond: 0,
            processes: []
        )
    ))

    #expect(store.displayedProcesses.isEmpty)
}

@Test
func previewInteractionStaysVisibleAcrossHoverTransitions() {
    var model = StatusPreviewInteractionModel()

    #expect(model.observe(region: .statusItem) == [.scheduleHoverOpen])
    #expect(model.state == .hoverPending)
    #expect(model.hoverDelayElapsed(currentRegion: .statusItem) == [.showPreview])
    #expect(model.state == .previewVisible)
    #expect(model.observe(region: .outside) == [.scheduleDismiss])
    #expect(model.state == .dismissPending)
    #expect(model.observe(region: .previewPanel) == [.cancelDismiss])
    #expect(model.state == .previewVisible)
    #expect(model.observe(region: .outside) == [.scheduleDismiss])
    #expect(model.dismissDelayElapsed(currentRegion: .outside) == [.closePreview])
    #expect(model.state == .idle)
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
    #expect(events.contains(where: { if case .retrying = $0 { return true } else { return false } }))
    #expect(events.filter { if case .starting = $0 { return true } else { return false } }.count >= 2)
    #expect(events.contains(where: { if case .snapshot = $0 { return true } else { return false } }))
}

@Test
func captureServiceStopsAfterRepeatedStartupFailure() async throws {
    let service = NettopCaptureService(
        producer: MockProducer(
            scripts: [
                .throwing(NettopCaptureError.failedToStart("missing nettop")),
                .throwing(NettopCaptureError.failedToStart("missing nettop"))
            ]
        ),
        restartDelayNanoseconds: 0,
        terminalStartupFailureThreshold: 2,
        sleep: { _ in }
    )

    let recorder = EventRecorder()
    let eventTask = Task {
        for await event in service.events {
            await recorder.record(event)
            if await recorder.hasTerminalFailure {
                break
            }
        }
    }

    await service.start()
    try await Task.sleep(nanoseconds: 150_000_000)
    eventTask.cancel()

    let events = await recorder.events
    #expect(events.contains(where: { if case .retrying = $0 { return true } else { return false } }))
    #expect(events.contains(where: { if case .failed(let message) = $0 { return message.contains("missing nettop") } else { return false } }))
}

@Test
func captureServiceRestartWaitsForPreviousStopToFinish() async throws {
    let recorder = LockedRecorder()
    let producer = RestartSerializationProducer(recorder: recorder)
    let service = NettopCaptureService(
        producer: producer,
        restartDelayNanoseconds: 0,
        sleep: { _ in }
    )

    await service.start()
    try await Task.sleep(nanoseconds: 80_000_000)
    await service.restart()
    try await Task.sleep(nanoseconds: 80_000_000)

    let calls = recorder.snapshot()
    #expect(Array(calls.prefix(4)) == ["start1", "stop1-start", "stop1-end", "start2"])

    await service.stop()
}

@Test
func processTerminationPlanEscalatesWhenGracefulShutdownFails() async {
    let recorder = LockedRecorder()
    let waitPlan = WaitPlan([false, false, false])

    await ProcessTerminationPlan.stop(
        terminate: {
            recorder.record("terminate")
        },
        interrupt: {
            recorder.record("interrupt")
        },
        forceKill: {
            recorder.record("kill")
        },
        waitForExitWithin: { _ in
            await waitPlan.next()
        },
        waitForExit: {
            recorder.record("wait")
        }
    )

    #expect(recorder.snapshot() == ["terminate", "interrupt", "kill", "wait"])
}

@Test
func statusPopoverPositioningStaysBelowMenuBarAndInsideScreen() {
    let origin = StatusPopoverPositioning.origin(
        anchorFrame: CGRect(x: 800, y: 1180, width: 24, height: 22),
        popoverSize: CGSize(width: 360, height: 280),
        placementFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
    )

    #expect(origin.y == 657)
    #expect(origin.x == 632)
}

@Test
func statusPopoverPositioningClampsHorizontallyNearScreenEdge() {
    let origin = StatusPopoverPositioning.origin(
        anchorFrame: CGRect(x: 1490, y: 1180, width: 24, height: 22),
        popoverSize: CGSize(width: 360, height: 280),
        placementFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
    )

    #expect(origin.x == 1144)
    #expect(origin.y == 657)
}

@Test
func statusPopoverPlacementFrameHonorsSafeAreaInsets() {
    let frame = StatusPopoverPositioning.placementFrame(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 954),
        safeAreaInsets: NSEdgeInsets(top: 74, left: 0, bottom: 0, right: 0)
    )

    #expect(frame == CGRect(x: 0, y: 0, width: 1512, height: 908))
}

private enum MockError: Error {
    case boom
    case stopAfterSnapshot
}

private actor WaitPlan {
    private var responses: [Bool]

    init(_ responses: [Bool]) {
        self.responses = responses
    }

    func next() -> Bool {
        if responses.isEmpty {
            return true
        }
        return responses.removeFirst()
    }
}

private final class LockedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func record(_ value: String) {
        lock.lock()
        calls.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class StreamContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func set(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.finish()
    }
}

private final class RestartSerializationProducer: NettopStreamProducing, @unchecked Sendable {
    private let recorder: LockedRecorder
    private let lock = NSLock()
    private var attempt = 0

    init(recorder: LockedRecorder) {
        self.recorder = recorder
    }

    func makeStream() throws -> NettopStreamHandle {
        lock.lock()
        attempt += 1
        let currentAttempt = attempt
        lock.unlock()

        recorder.record("start\(currentAttempt)")
        let continuationBox = StreamContinuationBox()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuationBox.set(continuation)
        }

        return NettopStreamHandle(
            lines: stream,
            stop: { [recorder] in
                recorder.record("stop\(currentAttempt)-start")
                try? await Task.sleep(nanoseconds: 50_000_000)
                continuationBox.finish()
                recorder.record("stop\(currentAttempt)-end")
            }
        )
    }
}

private final class MockProducer: NettopStreamProducing, @unchecked Sendable {
    enum Script {
        case finish([String])
        case failure([String], Error)
        case throwing(Error)
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

                case let .throwing(error):
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
        let restarted = events.filter { event in
            if case .starting = event { return true }
            return false
        }.count >= 2
        let snapshotted = events.contains { if case .snapshot = $0 { return true } else { return false } }
        let retrying = events.contains { if case .retrying = $0 { return true } else { return false } }
        return retrying && restarted && snapshotted
    }

    var hasTerminalFailure: Bool {
        events.contains { if case .failed = $0 { return true } else { return false } }
    }

    func record(_ event: CaptureEvent) {
        events.append(event)
    }
}
