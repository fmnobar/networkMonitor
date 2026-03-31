import Combine
import Foundation

@MainActor
final class TrafficDashboardStore: ObservableObject {
    @Published private(set) var viewState: DashboardViewState = .starting
    @Published private(set) var snapshot: LiveSnapshot?
    @Published private(set) var statusLabelText = "Starting…"
    @Published var searchText = ""
    @Published var sortOrder: [KeyPathComparator<ProcessUsage>] = [
        KeyPathComparator(\ProcessUsage.totalBytesPerSecond, order: .reverse)
    ]

    private let captureService: NettopCaptureService
    private let now: @Sendable () -> Date
    private let stallThreshold: TimeInterval
    private var eventTask: Task<Void, Never>?
    private var stallMonitorTask: Task<Void, Never>?
    private var recoveryState: CaptureRecoveryState?
    private(set) var lastSuccessfulCaptureAt: Date?

    init(
        captureService: NettopCaptureService = NettopCaptureService(),
        stallThreshold: TimeInterval = 4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.captureService = captureService
        self.stallThreshold = stallThreshold
        self.now = now
    }

    deinit {
        eventTask?.cancel()
        stallMonitorTask?.cancel()
    }

    var topFive: [ProcessUsage] {
        Array((snapshot?.processes ?? []).prefix(5))
    }

    var activeSnapshot: LiveSnapshot? {
        snapshot
    }

    var displayedProcesses: [ProcessUsage] {
        let filtered: [ProcessUsage]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = snapshot?.processes ?? []
        } else {
            let query = searchText.lowercased()
            filtered = (snapshot?.processes ?? []).filter { usage in
                usage.name.lowercased().contains(query) || String(usage.pid).contains(query)
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    var totalDownloadText: String {
        NetworkFormatting.rate(snapshot?.totalDownloadBytesPerSecond ?? 0)
    }

    var totalUploadText: String {
        NetworkFormatting.rate(snapshot?.totalUploadBytesPerSecond ?? 0)
    }

    var snapshotTimeText: String? {
        guard let snapshot else {
            return nil
        }
        return NetworkFormatting.snapshotTime(snapshot.capturedAt)
    }

    var lastSuccessfulCaptureText: String? {
        guard let lastSuccessfulCaptureAt else {
            return nil
        }
        return NetworkFormatting.snapshotTime(lastSuccessfulCaptureAt)
    }

    var stateMessage: String? {
        switch viewState {
        case .starting:
            return "Launching nettop and waiting for the first sample."
        case .live:
            return nil
        case .noTraffic:
            return "No process reported network activity in the latest interval."
        case let .retrying(_, status):
            return NetworkFormatting.retryDescription(status)
        case let .stalled(_, message):
            return message
        case let .failed(_, message):
            return message
        case .stopped:
            return "Capture is stopped."
        }
    }

    func start() {
        guard eventTask == nil else {
            return
        }

        let events = captureService.events
        let captureService = self.captureService

        eventTask = Task { [weak self] in
            guard let self else {
                return
            }

            await captureService.start()

            for await event in events {
                if Task.isCancelled {
                    break
                }
                await MainActor.run {
                    self.consume(event)
                }
            }
        }

        stallMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled {
                    break
                }

                await MainActor.run {
                    self.evaluateStaleness(now: self.now())
                }
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        stallMonitorTask?.cancel()
        stallMonitorTask = nil
        Task {
            await captureService.stop()
        }
    }

    func restartCapture() {
        let restartStatus = CaptureRecoveryState(
            message: "Restarting capture.",
            attempt: 0,
            nextRetryDate: nil,
            lastSuccessfulCaptureAt: lastSuccessfulCaptureAt
        )
        recoveryState = restartStatus
        if let snapshot {
            viewState = .retrying(snapshot: snapshot, status: restartStatus)
            statusLabelText = NetworkFormatting.statusLabel(for: snapshot, suffix: "retry")
        } else {
            viewState = .starting
            statusLabelText = "Starting…"
        }
        Task {
            await captureService.restart()
        }
    }

    func consume(_ event: CaptureEvent) {
        switch event {
        case .starting:
            if snapshot == nil && recoveryState == nil {
                viewState = .starting
                statusLabelText = "Starting…"
            }

        case let .snapshot(snapshot):
            self.snapshot = snapshot
            recoveryState = nil
            lastSuccessfulCaptureAt = snapshot.capturedAt
            if snapshot.processes.isEmpty {
                viewState = .noTraffic(snapshot)
            } else {
                viewState = .live(snapshot)
            }
            statusLabelText = NetworkFormatting.statusLabel(for: snapshot)

        case let .retrying(status):
            recoveryState = status
            if let snapshot {
                viewState = .retrying(snapshot: snapshot, status: status)
                statusLabelText = NetworkFormatting.statusLabel(for: snapshot, suffix: "retry")
            } else {
                viewState = .retrying(snapshot: nil, status: status)
                statusLabelText = "Retrying…"
            }

        case let .failed(message):
            recoveryState = nil
            viewState = .failed(snapshot: snapshot, message: message)
            if let snapshot {
                statusLabelText = NetworkFormatting.statusLabel(for: snapshot, suffix: "failed")
            } else {
                statusLabelText = "Unavailable"
            }

        case .stopped:
            recoveryState = nil
            viewState = .stopped(snapshot: snapshot)
            if let snapshot {
                statusLabelText = NetworkFormatting.statusLabel(for: snapshot, suffix: "stopped")
            } else {
                statusLabelText = "Stopped"
            }
        }
    }

    func evaluateStaleness(now: Date) {
        guard let snapshot else {
            return
        }

        guard recoveryState == nil else {
            return
        }

        guard now.timeIntervalSince(snapshot.capturedAt) >= stallThreshold else {
            return
        }

        switch viewState {
        case .live, .noTraffic:
            break
        default:
            return
        }

        let message = "No new sample arrived after \(Int(stallThreshold)) seconds. Last good sample was at \(NetworkFormatting.snapshotTime(snapshot.capturedAt))."
        viewState = .stalled(snapshot: snapshot, message: message)
        statusLabelText = NetworkFormatting.statusLabel(for: snapshot, suffix: "stalled")
    }
}
