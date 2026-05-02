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

    private enum CapturePhase {
        case starting
        case ready
        case retrying(CaptureRecoveryState)
        case stalled(String)
        case failed(String)
        case stopped
    }

    @Published private(set) var viewState: DashboardViewState = .starting
    @Published private(set) var snapshot: LiveSnapshot?
    @Published private(set) var statusLabelText = "Starting…"
    @Published var selectedDisplayMode: TrafficDisplayMode = .live {
        didSet {
            refreshPresentation()
        }
    }
    @Published var selectedAverageWindow: AverageWindow = .fifteenSeconds {
        didSet {
            refreshPresentation()
        }
    }
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
    private var capturePhase: CapturePhase = .starting
    private var stabilizedProcesses: [Int: StabilizedProcessState] = [:]
    private var liveSnapshot: LiveSnapshot?
    private var rawSnapshotHistory: [LiveSnapshot] = []
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

    var previewRows: [PreviewProcessRow] {
        guard let snapshot else {
            return emptyPreviewRows
        }

        let activeRows = snapshot.processes
            .filter { $0.totalBytesPerSecond >= previewMinimumBytesPerSecond }
            .prefix(5)
            .map(PreviewProcessRow.active)
        let remainingSlots = max(0, 5 - activeRows.count)
        let lowTrafficRows = snapshot.processes
            .filter { $0.totalBytesPerSecond > 0 && $0.totalBytesPerSecond < previewMinimumBytesPerSecond }
            .prefix(remainingSlots)
            .map(PreviewProcessRow.lowTraffic)
        let visibleRows = activeRows + lowTrafficRows

        return visibleRows + Array(repeating: .empty, count: max(0, 5 - visibleRows.count))
    }

    var previewFilteringMessage: String? {
        guard let snapshot else {
            return nil
        }

        let activeRowCount = snapshot.processes.filter { $0.totalBytesPerSecond >= previewMinimumBytesPerSecond }.count
        let shownLowTrafficRowCount = previewRows.filter { row in
            if case .lowTraffic = row {
                return true
            }
            return false
        }.count
        guard shownLowTrafficRowCount > 0 else {
            return nil
        }

        let thresholdText = NetworkFormatting.rate(previewMinimumBytesPerSecond)
        if activeRowCount == 0 {
            return "All visible traffic is below the \(thresholdText) preview threshold."
        }

        return "Dimmed rows are below the \(thresholdText) preview threshold."
    }

    var activeSnapshot: LiveSnapshot? {
        snapshot
    }

    private var emptyPreviewRows: [PreviewProcessRow] {
        Array(repeating: .empty, count: 5)
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

    var downloadTrend: TrafficTrendSeries {
        TrafficTrendSeries(
            snapshots: rawSnapshotHistory,
            value: \.totalDownloadBytesPerSecond
        )
    }

    var uploadTrend: TrafficTrendSeries {
        TrafficTrendSeries(
            snapshots: rawSnapshotHistory,
            value: \.totalUploadBytesPerSecond
        )
    }

    var displayModeSummaryText: String {
        switch selectedDisplayMode {
        case .live:
            return "Near real-time (~4s smoothing)"
        case .average:
            return "Averaged over the last \(selectedAverageWindow.title)"
        }
    }

    var dashboardSubtitleText: String {
        switch selectedDisplayMode {
        case .live:
            return "Near real-time per-process bandwidth from nettop"
        case .average:
            return "Per-process bandwidth averaged over the last \(selectedAverageWindow.title)"
        }
    }

    var previewTitleText: String {
        switch selectedDisplayMode {
        case .live:
            return "Live Network Usage"
        case .average:
            return "Average Network Usage"
        }
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
            switch selectedDisplayMode {
            case .live:
                return "No process reported network activity in the latest interval."
            case .average:
                return "No process reported network activity in the selected average window."
            }
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
        if snapshot != nil {
            capturePhase = .retrying(restartStatus)
            refreshPresentation()
        } else {
            capturePhase = .starting
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
                capturePhase = .starting
                viewState = .starting
                statusLabelText = "Starting…"
            }

        case let .snapshot(rawSnapshot):
            appendToSnapshotHistory(rawSnapshot)
            let stabilizedSnapshot = stabilizedSnapshot(from: rawSnapshot)
            liveSnapshot = stabilizedSnapshot
            recoveryState = nil
            lastSuccessfulCaptureAt = rawSnapshot.capturedAt
            capturePhase = .ready
            refreshPresentation()

        case let .retrying(status):
            recoveryState = status
            capturePhase = .retrying(status)
            if snapshot != nil {
                refreshPresentation()
            } else {
                viewState = .retrying(snapshot: nil, status: status)
                statusLabelText = "Retrying…"
            }

        case let .failed(message):
            recoveryState = nil
            capturePhase = .failed(message)
            if snapshot != nil {
                refreshPresentation()
            } else {
                viewState = .failed(snapshot: nil, message: message)
                statusLabelText = "Unavailable"
            }

        case .stopped:
            recoveryState = nil
            capturePhase = .stopped
            if snapshot != nil {
                refreshPresentation()
            } else {
                viewState = .stopped(snapshot: nil)
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
        capturePhase = .stalled(message)
        refreshPresentation()
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

    private func appendToSnapshotHistory(_ rawSnapshot: LiveSnapshot) {
        rawSnapshotHistory.append(rawSnapshot)

        let oldestAllowedDate = rawSnapshot.capturedAt.addingTimeInterval(-AverageWindow.maximumDuration)
        rawSnapshotHistory.removeAll { $0.capturedAt < oldestAllowedDate }
    }

    private func refreshPresentation() {
        let presentedSnapshot = currentPresentedSnapshot()
        snapshot = presentedSnapshot

        switch capturePhase {
        case .starting:
            if presentedSnapshot == nil {
                viewState = .starting
                statusLabelText = "Starting…"
            } else {
                applyReadyState(for: presentedSnapshot)
            }

        case .ready:
            applyReadyState(for: presentedSnapshot)

        case let .retrying(status):
            viewState = .retrying(snapshot: presentedSnapshot, status: status)
            if let presentedSnapshot {
                statusLabelText = NetworkFormatting.statusLabel(for: presentedSnapshot)
            } else {
                statusLabelText = "Retrying…"
            }

        case let .stalled(message):
            guard let presentedSnapshot else {
                viewState = .starting
                statusLabelText = "Starting…"
                return
            }
            viewState = .stalled(snapshot: presentedSnapshot, message: message)
            statusLabelText = NetworkFormatting.statusLabel(for: presentedSnapshot)

        case let .failed(message):
            viewState = .failed(snapshot: presentedSnapshot, message: message)
            if let presentedSnapshot {
                statusLabelText = NetworkFormatting.statusLabel(for: presentedSnapshot)
            } else {
                statusLabelText = "Unavailable"
            }

        case .stopped:
            viewState = .stopped(snapshot: presentedSnapshot)
            if let presentedSnapshot {
                statusLabelText = NetworkFormatting.statusLabel(for: presentedSnapshot)
            } else {
                statusLabelText = "Stopped"
            }
        }
    }

    private func applyReadyState(for presentedSnapshot: LiveSnapshot?) {
        guard let presentedSnapshot else {
            viewState = .starting
            statusLabelText = "Starting…"
            return
        }

        if presentedSnapshot.processes.isEmpty {
            viewState = .noTraffic(presentedSnapshot)
        } else {
            viewState = .live(presentedSnapshot)
        }
        statusLabelText = NetworkFormatting.statusLabel(for: presentedSnapshot)
    }

    private func currentPresentedSnapshot() -> LiveSnapshot? {
        switch selectedDisplayMode {
        case .live:
            return liveSnapshot
        case .average:
            return averagedSnapshot(for: selectedAverageWindow)
        }
    }

    private func averagedSnapshot(for window: AverageWindow) -> LiveSnapshot? {
        guard let latestSnapshot = rawSnapshotHistory.last else {
            return nil
        }

        let cutoff = latestSnapshot.capturedAt.addingTimeInterval(-window.duration)
        let snapshotsInWindow = rawSnapshotHistory.filter { $0.capturedAt >= cutoff }
        guard !snapshotsInWindow.isEmpty else {
            return nil
        }

        struct AggregateState {
            var name: String
            var downloadSum: UInt64
            var uploadSum: UInt64
            var lastSeen: Date
        }

        var aggregateByPID: [Int: AggregateState] = [:]
        for snapshot in snapshotsInWindow {
            for process in snapshot.processes {
                if let existing = aggregateByPID[process.pid] {
                    aggregateByPID[process.pid] = AggregateState(
                        name: process.name,
                        downloadSum: existing.downloadSum + process.downloadBytesPerSecond,
                        uploadSum: existing.uploadSum + process.uploadBytesPerSecond,
                        lastSeen: max(existing.lastSeen, process.lastSeen)
                    )
                } else {
                    aggregateByPID[process.pid] = AggregateState(
                        name: process.name,
                        downloadSum: process.downloadBytesPerSecond,
                        uploadSum: process.uploadBytesPerSecond,
                        lastSeen: process.lastSeen
                    )
                }
            }
        }

        let sampleCount = UInt64(snapshotsInWindow.count)
        let averagedProcesses = aggregateByPID.map { pid, aggregate -> ProcessUsage in
            let averageDownload = UInt64((Double(aggregate.downloadSum) / Double(sampleCount)).rounded())
            let averageUpload = UInt64((Double(aggregate.uploadSum) / Double(sampleCount)).rounded())
            let total = averageDownload + averageUpload
            return ProcessUsage(
                pid: pid,
                name: aggregate.name,
                downloadBytesPerSecond: averageDownload,
                uploadBytesPerSecond: averageUpload,
                totalBytesPerSecond: total,
                shareOfTotal: 0,
                lastSeen: aggregate.lastSeen
            )
        }
        .filter { $0.totalBytesPerSecond > 0 }

        let totalDownload = averagedProcesses.reduce(UInt64.zero) { $0 + $1.downloadBytesPerSecond }
        let totalUpload = averagedProcesses.reduce(UInt64.zero) { $0 + $1.uploadBytesPerSecond }
        let totalBandwidth = totalDownload + totalUpload

        let rankedProcesses = averagedProcesses
            .map { process in
                let share = totalBandwidth > 0 ? Double(process.totalBytesPerSecond) / Double(totalBandwidth) : 0
                return ProcessUsage(
                    pid: process.pid,
                    name: process.name,
                    downloadBytesPerSecond: process.downloadBytesPerSecond,
                    uploadBytesPerSecond: process.uploadBytesPerSecond,
                    totalBytesPerSecond: process.totalBytesPerSecond,
                    shareOfTotal: share,
                    lastSeen: process.lastSeen
                )
            }
            .sorted {
                if $0.totalBytesPerSecond != $1.totalBytesPerSecond {
                    return $0.totalBytesPerSecond > $1.totalBytesPerSecond
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return LiveSnapshot(
            capturedAt: latestSnapshot.capturedAt,
            totalDownloadBytesPerSecond: totalDownload,
            totalUploadBytesPerSecond: totalUpload,
            processes: rankedProcesses
        )
    }
}
