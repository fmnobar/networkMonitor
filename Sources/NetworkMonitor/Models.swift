import Combine
import Foundation

enum TrafficDisplayMode: String, CaseIterable, Identifiable {
    case live
    case average

    var id: Self { self }

    var title: String {
        switch self {
        case .live:
            return "Live"
        case .average:
            return "Average"
        }
    }
}

enum NetworkRateUnitStyle: String, CaseIterable, Identifiable, Sendable {
    case binary
    case decimal

    var id: Self { self }

    var title: String {
        switch self {
        case .binary:
            return "Binary"
        case .decimal:
            return "Decimal"
        }
    }

    var detail: String {
        switch self {
        case .binary:
            return "Base 1024"
        case .decimal:
            return "Base 1000"
        }
    }

    var byteCountStyle: ByteCountFormatter.CountStyle {
        switch self {
        case .binary:
            return .binary
        case .decimal:
            return .decimal
        }
    }

    var compactDivisor: Double {
        switch self {
        case .binary:
            return 1024
        case .decimal:
            return 1000
        }
    }
}

enum PreviewTrafficThreshold: UInt64, CaseIterable, Identifiable, Sendable {
    case disabled = 0
    case bytes512 = 512
    case oneKilobyte = 1_024
    case tenKilobytes = 10_240

    var id: Self { self }

    var bytesPerSecond: UInt64 {
        rawValue
    }

    var title: String {
        switch self {
        case .disabled:
            return "Show all"
        case .bytes512:
            return "512 B/s"
        case .oneKilobyte:
            return "1 KB/s"
        case .tenKilobytes:
            return "10 KB/s"
        }
    }
}

enum DashboardProcessVisibility: String, CaseIterable, Identifiable, Sendable {
    case allActive
    case abovePreviewThreshold

    var id: Self { self }

    var title: String {
        switch self {
        case .allActive:
            return "All active processes"
        case .abovePreviewThreshold:
            return "Above preview threshold"
        }
    }
}

enum AverageWindow: Int, CaseIterable, Identifiable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case oneMinute = 60

    var id: Self { self }

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    static var maximumDuration: TimeInterval {
        allCases.map(\.duration).max() ?? 0
    }

    var title: String {
        if rawValue < 60 {
            return "\(rawValue)s"
        }

        return "\(rawValue / 60) min"
    }

    var descriptiveTitle: String {
        if rawValue < 60 {
            return "\(rawValue)-second average"
        }

        return "\(rawValue / 60)-minute average"
    }
}

@MainActor
final class NetworkMonitorPreferences: ObservableObject {
    private enum Key {
        static let defaultDisplayMode = "defaultDisplayMode"
        static let defaultAverageWindow = "defaultAverageWindow"
        static let previewThreshold = "previewThreshold"
        static let rateUnitStyle = "rateUnitStyle"
        static let dashboardProcessVisibility = "dashboardProcessVisibility"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
    }

    private let userDefaults: UserDefaults

    @Published var defaultDisplayMode: TrafficDisplayMode {
        didSet {
            userDefaults.set(defaultDisplayMode.rawValue, forKey: Key.defaultDisplayMode)
        }
    }

    @Published var defaultAverageWindow: AverageWindow {
        didSet {
            userDefaults.set(defaultAverageWindow.rawValue, forKey: Key.defaultAverageWindow)
        }
    }

    @Published var previewThreshold: PreviewTrafficThreshold {
        didSet {
            userDefaults.set(Int(previewThreshold.rawValue), forKey: Key.previewThreshold)
        }
    }

    @Published var rateUnitStyle: NetworkRateUnitStyle {
        didSet {
            userDefaults.set(rateUnitStyle.rawValue, forKey: Key.rateUnitStyle)
        }
    }

    @Published var dashboardProcessVisibility: DashboardProcessVisibility {
        didSet {
            userDefaults.set(dashboardProcessVisibility.rawValue, forKey: Key.dashboardProcessVisibility)
        }
    }

    @Published var launchAtLoginEnabled: Bool {
        didSet {
            userDefaults.set(launchAtLoginEnabled, forKey: Key.launchAtLoginEnabled)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.defaultDisplayMode = TrafficDisplayMode(rawValue: userDefaults.string(forKey: Key.defaultDisplayMode) ?? "") ?? .live
        self.defaultAverageWindow = AverageWindow(rawValue: userDefaults.integer(forKey: Key.defaultAverageWindow)) ?? .fifteenSeconds
        if userDefaults.object(forKey: Key.previewThreshold) == nil {
            self.previewThreshold = .oneKilobyte
        } else {
            self.previewThreshold = PreviewTrafficThreshold(rawValue: UInt64(userDefaults.integer(forKey: Key.previewThreshold))) ?? .oneKilobyte
        }
        self.rateUnitStyle = NetworkRateUnitStyle(rawValue: userDefaults.string(forKey: Key.rateUnitStyle) ?? "") ?? .binary
        self.dashboardProcessVisibility = DashboardProcessVisibility(rawValue: userDefaults.string(forKey: Key.dashboardProcessVisibility) ?? "") ?? .allActive
        self.launchAtLoginEnabled = userDefaults.bool(forKey: Key.launchAtLoginEnabled)
    }

    var previewMinimumBytesPerSecond: UInt64 {
        previewThreshold.bytesPerSecond
    }
}

struct ProcessUsage: Identifiable, Equatable, Sendable {
    let pid: Int
    let name: String
    let downloadBytesPerSecond: UInt64
    let uploadBytesPerSecond: UInt64
    let totalBytesPerSecond: UInt64
    let shareOfTotal: Double
    let lastSeen: Date

    var id: Int { pid }
}

struct LiveSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let totalDownloadBytesPerSecond: UInt64
    let totalUploadBytesPerSecond: UInt64
    let processes: [ProcessUsage]
}

enum TrafficTrendDirection: Equatable, Sendable {
    case rising
    case falling
    case flat

    var title: String {
        switch self {
        case .rising:
            return "Rising"
        case .falling:
            return "Falling"
        case .flat:
            return "Flat"
        }
    }

    var systemImageName: String {
        switch self {
        case .rising:
            return "arrow.up.right"
        case .falling:
            return "arrow.down.right"
        case .flat:
            return "arrow.right"
        }
    }
}

struct TrafficTrendSample: Identifiable, Equatable, Sendable {
    let capturedAt: Date
    let bytesPerSecond: UInt64
    let normalizedValue: Double

    var id: Date { capturedAt }
}

struct TrafficTrendSeries: Equatable, Sendable {
    let samples: [TrafficTrendSample]
    let direction: TrafficTrendDirection

    init(
        snapshots: [LiveSnapshot],
        value: (LiveSnapshot) -> UInt64,
        duration: TimeInterval = AverageWindow.maximumDuration
    ) {
        guard let latestSnapshot = snapshots.max(by: { $0.capturedAt < $1.capturedAt }) else {
            samples = []
            direction = .flat
            return
        }

        let cutoff = latestSnapshot.capturedAt.addingTimeInterval(-duration)
        let snapshotsInWindow = snapshots
            .filter { $0.capturedAt >= cutoff }
            .sorted { $0.capturedAt < $1.capturedAt }
        let maximumRate = snapshotsInWindow
            .map { Double(value($0)) }
            .max() ?? 0

        samples = snapshotsInWindow.map { snapshot in
            let rate = value(snapshot)
            return TrafficTrendSample(
                capturedAt: snapshot.capturedAt,
                bytesPerSecond: rate,
                normalizedValue: Self.normalizedValue(Double(rate), maximum: maximumRate)
            )
        }
        direction = Self.direction(for: samples.map { Double($0.bytesPerSecond) })
    }

    static func normalizedValue(_ value: Double, maximum: Double) -> Double {
        guard value.isFinite, maximum.isFinite, value > 0, maximum > 0 else {
            return 0
        }

        return min(value / maximum, 1)
    }

    static func direction(for values: [Double]) -> TrafficTrendDirection {
        guard values.count >= 2, let first = values.first, let last = values.last else {
            return .flat
        }

        let maximum = values.max() ?? 0
        guard maximum > 0 else {
            return .flat
        }

        let relativeDelta = (last - first) / maximum
        guard abs(relativeDelta) >= 0.05 else {
            return .flat
        }

        return relativeDelta > 0 ? .rising : .falling
    }
}

struct CaptureRecoveryState: Equatable, Sendable {
    let message: String
    let attempt: Int
    let nextRetryDate: Date?
    let lastSuccessfulCaptureAt: Date?
}

enum DashboardViewState: Equatable {
    case starting
    case live(LiveSnapshot)
    case noTraffic(LiveSnapshot)
    case retrying(snapshot: LiveSnapshot?, status: CaptureRecoveryState)
    case stalled(snapshot: LiveSnapshot, message: String)
    case failed(snapshot: LiveSnapshot?, message: String)
    case stopped(snapshot: LiveSnapshot?)

    var allowsManualRestart: Bool {
        switch self {
        case .starting, .retrying:
            return false
        case .live, .noTraffic, .stalled, .failed, .stopped:
            return true
        }
    }
}

enum PreviewProcessRow: Equatable {
    case active(ProcessUsage)
    case lowTraffic(ProcessUsage)
    case empty
}

enum CaptureEvent: Equatable, Sendable {
    case starting
    case snapshot(LiveSnapshot)
    case retrying(CaptureRecoveryState)
    case failed(String)
    case stopped
}

enum NetworkFormatting {
    static func rate(
        _ bytesPerSecond: UInt64,
        unitStyle: NetworkRateUnitStyle = .binary
    ) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: unitStyle.byteCountStyle))/s"
    }

    static func compactRate(
        _ bytesPerSecond: UInt64,
        unitStyle: NetworkRateUnitStyle = .binary
    ) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytesPerSecond)
        var unitIndex = 0

        while value >= unitStyle.compactDivisor, unitIndex < units.count - 1 {
            value /= unitStyle.compactDivisor
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value.rounded()))\(units[unitIndex])"
        }

        if value >= 100 {
            return "\(Int(value.rounded()))\(units[unitIndex])"
        }

        return String(format: "%.1f%@", value, units[unitIndex])
    }

    static func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func normalizedShare(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else {
            return 0
        }
        return min(value, 1)
    }

    static func snapshotTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func lastSeen(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func statusLabel(
        for snapshot: LiveSnapshot,
        unitStyle: NetworkRateUnitStyle = .binary
    ) -> String {
        "↓ \(compactRate(snapshot.totalDownloadBytesPerSecond, unitStyle: unitStyle))\n↑ \(compactRate(snapshot.totalUploadBytesPerSecond, unitStyle: unitStyle))"
    }

    static func retryDescription(_ status: CaptureRecoveryState) -> String {
        let retryText: String
        if let nextRetryDate = status.nextRetryDate {
            retryText = "Retry \(status.attempt) scheduled for \(snapshotTime(nextRetryDate))."
        } else if status.attempt > 0 {
            retryText = "Retry \(status.attempt) in progress."
        } else {
            retryText = "Restarting capture."
        }

        if let lastSuccessfulCaptureAt = status.lastSuccessfulCaptureAt {
            return "\(retryText) Last good sample at \(snapshotTime(lastSuccessfulCaptureAt))."
        }

        return retryText
    }
}

struct NettopCSVStreamParser {
    private struct RawUsage {
        let pid: Int
        let name: String
        let downloadBytesPerSecond: UInt64
        let uploadBytesPerSecond: UInt64
    }

    private let now: @Sendable () -> Date
    private var currentRows: [RawUsage] = []
    private var observedRows = false

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    mutating func consume(line: String) -> [LiveSnapshot] {
        let trimmed = Self.sanitize(line)
        guard !trimmed.isEmpty else {
            return []
        }

        if Self.isHeader(trimmed) {
            if observedRows {
                return flushCurrentSnapshot()
            }
            return []
        }

        observedRows = true
        if let parsed = Self.parseUsage(from: trimmed) {
            currentRows.append(parsed)
        }
        return []
    }

    mutating func finish() -> LiveSnapshot? {
        flushCurrentSnapshot().first
    }

    private mutating func flushCurrentSnapshot() -> [LiveSnapshot] {
        guard observedRows else {
            return []
        }

        defer {
            currentRows.removeAll(keepingCapacity: true)
            observedRows = false
        }

        let capturedAt = now()
        var aggregates: [Int: RawUsage] = [:]
        for usage in currentRows {
            if let existing = aggregates[usage.pid] {
                aggregates[usage.pid] = RawUsage(
                    pid: usage.pid,
                    name: usage.name,
                    downloadBytesPerSecond: existing.downloadBytesPerSecond + usage.downloadBytesPerSecond,
                    uploadBytesPerSecond: existing.uploadBytesPerSecond + usage.uploadBytesPerSecond
                )
            } else {
                aggregates[usage.pid] = usage
            }
        }

        let totalDownload = aggregates.values.reduce(UInt64.zero) { $0 + $1.downloadBytesPerSecond }
        let totalUpload = aggregates.values.reduce(UInt64.zero) { $0 + $1.uploadBytesPerSecond }
        let grandTotal = totalDownload + totalUpload

        let processes = aggregates.values
            .compactMap { usage -> ProcessUsage? in
                let total = usage.downloadBytesPerSecond + usage.uploadBytesPerSecond
                guard total > 0 else {
                    return nil
                }
                let share = grandTotal > 0 ? Double(total) / Double(grandTotal) : 0
                return ProcessUsage(
                    pid: usage.pid,
                    name: usage.name,
                    downloadBytesPerSecond: usage.downloadBytesPerSecond,
                    uploadBytesPerSecond: usage.uploadBytesPerSecond,
                    totalBytesPerSecond: total,
                    shareOfTotal: share,
                    lastSeen: capturedAt
                )
            }
            .sorted {
                if $0.totalBytesPerSecond != $1.totalBytesPerSecond {
                    return $0.totalBytesPerSecond > $1.totalBytesPerSecond
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return [
            LiveSnapshot(
                capturedAt: capturedAt,
                totalDownloadBytesPerSecond: totalDownload,
                totalUploadBytesPerSecond: totalUpload,
                processes: processes
            )
        ]
    }

    private static func isHeader(_ line: String) -> Bool {
        line.hasPrefix("time,")
    }

    private static func sanitize(_ line: String) -> String {
        let scalars = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseUsage(from line: String) -> RawUsage? {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard columns.count > 5 else {
            return nil
        }

        guard
            let identity = parseIdentity(columns[1]),
            let download = UInt64(columns[4]),
            let upload = UInt64(columns[5])
        else {
            return nil
        }

        return RawUsage(
            pid: identity.pid,
            name: identity.name,
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload
        )
    }

    private static func parseIdentity(_ rawValue: String) -> (name: String, pid: Int)? {
        guard let separatorIndex = rawValue.lastIndex(of: ".") else {
            return nil
        }

        let name = String(rawValue[..<separatorIndex])
        let pidString = String(rawValue[rawValue.index(after: separatorIndex)...])

        guard !name.isEmpty, let pid = Int(pidString) else {
            return nil
        }

        return (name, pid)
    }
}
