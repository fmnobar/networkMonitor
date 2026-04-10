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

enum AverageWindow: Int, CaseIterable, Identifiable {
    case fifteenSeconds = 15
    case thirtySeconds = 30

    var id: Self { self }

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    var title: String {
        "\(rawValue)s"
    }

    var descriptiveTitle: String {
        "\(rawValue)-second average"
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
}

enum CaptureEvent: Equatable, Sendable {
    case starting
    case snapshot(LiveSnapshot)
    case retrying(CaptureRecoveryState)
    case failed(String)
    case stopped
}

enum NetworkFormatting {
    static func rate(_ bytesPerSecond: UInt64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary))/s"
    }

    static func compactRate(_ bytesPerSecond: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytesPerSecond)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
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

    static func snapshotTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func lastSeen(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func statusLabel(for snapshot: LiveSnapshot) -> String {
        "↓ \(compactRate(snapshot.totalDownloadBytesPerSecond)) ↑ \(compactRate(snapshot.totalUploadBytesPerSecond))"
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
