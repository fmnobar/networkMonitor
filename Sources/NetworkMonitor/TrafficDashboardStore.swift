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
    private var eventTask: Task<Void, Never>?

    init(captureService: NettopCaptureService = NettopCaptureService()) {
        self.captureService = captureService
    }

    deinit {
        eventTask?.cancel()
    }

    var topFive: [ProcessUsage] {
        Array((snapshot?.processes ?? []).prefix(5))
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
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        Task {
            await captureService.stop()
        }
    }

    func restartCapture() {
        viewState = .starting
        statusLabelText = "Starting…"
        Task {
            await captureService.restart()
        }
    }

    func consume(_ event: CaptureEvent) {
        switch event {
        case .starting:
            if snapshot == nil {
                viewState = .starting
            }
            statusLabelText = "Starting…"

        case let .snapshot(snapshot):
            self.snapshot = snapshot
            if snapshot.processes.isEmpty {
                viewState = .noTraffic(snapshot.capturedAt)
            } else {
                viewState = .live(snapshot)
            }
            statusLabelText = "↓ \(NetworkFormatting.rate(snapshot.totalDownloadBytesPerSecond)) ↑ \(NetworkFormatting.rate(snapshot.totalUploadBytesPerSecond))"

        case let .failed(message):
            viewState = .failed(message)
            statusLabelText = "Unavailable"

        case .stopped:
            if snapshot == nil {
                viewState = .starting
                statusLabelText = "Stopped"
            }
        }
    }
}
