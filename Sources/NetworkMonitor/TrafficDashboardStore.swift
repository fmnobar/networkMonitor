import Combine
import Foundation

@MainActor
final class TrafficDashboardStore: ObservableObject {
    private struct StabilizedProcessState {
        let pid: Int
        var name: String
        var smoothedDownloadBytesPerSecond: Double
        var smoothedUploadBytesPerSecond: Double
        var lastActiveAt: Date
    }

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
    private let smoothingFactor: Double
    private let visibilityGracePeriod: TimeInterval
    private let previewMinimumBytesPerSecond: UInt64
    private var eventTask: Task<Void, Never>?
    private var stallMonitorTask: Task<Void, Never>?
    private var recoveryState: CaptureRecoveryState?
    private var stabilizedProcesses: [Int: StabilizedProcessState] = [:]
    private(set) var lastSuccessfulCaptureAt: Date?

    init(
        captureService: NettopCaptureService = NettopCaptureService(),
        stallThreshold: TimeInterval = 8,
        smoothingFactor: Double = 0.4,
        visibilityGracePeriod: TimeInterval = 5,
        previewMinimumBytesPerSecond: UInt64 = 1_024,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.captureService = captureService
        self.stallThreshold = stallThreshold
        self.smoothingFactor = min(max(smoothingFactor, 0), 1)
        self.visibilityGracePeriod = visibilityGracePeriod
        self.previewMinimumBytesPerSecond = previewMinimumBytesPerSecond
        self.now = now
    }

    deinit {
        eventTask?.cancel()
        stallMonitorTask?.cancel()
    }

    var topFive: [ProcessUsage] {
        Array((snapshot?.processes ?? [])
            .filter { $0.totalBytesPerSecond >= previewMinimumBytesPerSecond }
            .prefix(5))
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
            let stabilizedSnapshot = stabilizedSnapshot(from: snapshot)
            self.snapshot = stabilizedSnapshot
            recoveryState = nil
            lastSuccessfulCaptureAt = snapshot.capturedAt
            if stabilizedSnapshot.processes.isEmpty {
                viewState = .noTraffic(stabilizedSnapshot)
            } else {
                viewState = .live(stabilizedSnapshot)
            }
            statusLabelText = NetworkFormatting.statusLabel(for: stabilizedSnapshot)

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

    private func stabilizedSnapshot(from rawSnapshot: LiveSnapshot) -> LiveSnapshot {
        var nextStates: [Int: StabilizedProcessState] = [:]
        let activeProcessesByPID = Dictionary(uniqueKeysWithValues: rawSnapshot.processes.map { ($0.pid, $0) })

        for usage in rawSnapshot.processes {
            if let existing = stabilizedProcesses[usage.pid] {
                nextStates[usage.pid] = StabilizedProcessState(
                    pid: usage.pid,
                    name: usage.name,
                    smoothedDownloadBytesPerSecond: smooth(existing.smoothedDownloadBytesPerSecond, next: Double(usage.downloadBytesPerSecond)),
                    smoothedUploadBytesPerSecond: smooth(existing.smoothedUploadBytesPerSecond, next: Double(usage.uploadBytesPerSecond)),
                    lastActiveAt: rawSnapshot.capturedAt
                )
            } else {
                nextStates[usage.pid] = StabilizedProcessState(
                    pid: usage.pid,
                    name: usage.name,
                    smoothedDownloadBytesPerSecond: Double(usage.downloadBytesPerSecond),
                    smoothedUploadBytesPerSecond: Double(usage.uploadBytesPerSecond),
                    lastActiveAt: rawSnapshot.capturedAt
                )
            }
        }

        for (pid, existing) in stabilizedProcesses where activeProcessesByPID[pid] == nil {
            guard rawSnapshot.capturedAt.timeIntervalSince(existing.lastActiveAt) <= visibilityGracePeriod else {
                continue
            }

            let decayedDownload = smooth(existing.smoothedDownloadBytesPerSecond, next: 0)
            let decayedUpload = smooth(existing.smoothedUploadBytesPerSecond, next: 0)
            guard decayedDownload + decayedUpload >= 1 else {
                continue
            }

            nextStates[pid] = StabilizedProcessState(
                pid: pid,
                name: existing.name,
                smoothedDownloadBytesPerSecond: decayedDownload,
                smoothedUploadBytesPerSecond: decayedUpload,
                lastActiveAt: existing.lastActiveAt
            )
        }

        stabilizedProcesses = nextStates
        return makeSnapshot(from: nextStates.values, capturedAt: rawSnapshot.capturedAt)
    }

    private func makeSnapshot(
        from states: Dictionary<Int, StabilizedProcessState>.Values,
        capturedAt: Date
    ) -> LiveSnapshot {
        let roundedProcesses = states
            .map { state in
                (
                    pid: state.pid,
                    name: state.name,
                    download: UInt64(state.smoothedDownloadBytesPerSecond.rounded()),
                    upload: UInt64(state.smoothedUploadBytesPerSecond.rounded()),
                    lastActiveAt: state.lastActiveAt
                )
            }
            .filter { $0.download + $0.upload > 0 }

        let totalDownload = roundedProcesses.reduce(UInt64.zero) { $0 + $1.download }
        let totalUpload = roundedProcesses.reduce(UInt64.zero) { $0 + $1.upload }
        let totalBandwidth = totalDownload + totalUpload

        let processes = roundedProcesses
            .map { state in
                let total = state.download + state.upload
                let share = totalBandwidth > 0 ? Double(total) / Double(totalBandwidth) : 0
                return ProcessUsage(
                    pid: state.pid,
                    name: state.name,
                    downloadBytesPerSecond: state.download,
                    uploadBytesPerSecond: state.upload,
                    totalBytesPerSecond: total,
                    shareOfTotal: share,
                    lastSeen: state.lastActiveAt
                )
            }
            .sorted {
                if $0.totalBytesPerSecond != $1.totalBytesPerSecond {
                    return $0.totalBytesPerSecond > $1.totalBytesPerSecond
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return LiveSnapshot(
            capturedAt: capturedAt,
            totalDownloadBytesPerSecond: totalDownload,
            totalUploadBytesPerSecond: totalUpload,
            processes: processes
        )
    }

    private func smooth(_ previous: Double, next: Double) -> Double {
        guard smoothingFactor > 0 else {
            return next
        }

        return (smoothingFactor * next) + ((1 - smoothingFactor) * previous)
    }
}
