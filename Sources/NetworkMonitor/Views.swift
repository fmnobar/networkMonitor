import AppKit
import Charts
import SwiftUI

struct PreviewPanelView: View {
    @ObservedObject var store: TrafficDashboardStore
    let onOpen: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.previewTitleText)
                        .font(.headline)
                    Text(store.displayModeSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let snapshotTime = store.snapshotTimeText {
                        Text("Updated \(snapshotTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lastSuccessfulCaptureText = store.lastSuccessfulCaptureText, lastSuccessfulCaptureText != store.snapshotTimeText {
                        Text("Last good sample \(lastSuccessfulCaptureText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("↓ \(store.totalDownloadText)")
                    Text("↑ \(store.totalUploadText)")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            previewModeControls

            Divider()

            if let stateMessage = store.stateMessage, !stateMessage.isEmpty {
                statusBanner(
                    title: bannerTitle,
                    message: stateMessage
                )
            } else if let filteringMessage = store.previewFilteringMessage, !filteringMessage.isEmpty {
                statusBanner(
                    title: "Filtered",
                    message: filteringMessage
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(store.previewRows.enumerated()), id: \.offset) { _, row in
                    previewRow(row)
                }
            }

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 10) {
                Button("Open Dashboard", action: onOpen)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)

                Button("Restart Capture", action: onRestart)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(
            width: StatusPreviewLayout.panelSize.width,
            height: StatusPreviewLayout.panelSize.height,
            alignment: .topLeading
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.2), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var previewModeControls: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Mode", selection: $store.selectedDisplayMode) {
                ForEach(TrafficDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 170)

            if store.selectedDisplayMode == .average {
                Picker("Average Window", selection: $store.selectedAverageWindow) {
                    ForEach(AverageWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 136)
                .padding(.leading, 10)
            }

            Spacer(minLength: 0)
        }
    }

    private var bannerTitle: String {
        switch store.viewState {
        case .starting:
            return "Starting"
        case .live:
            return "Live"
        case .noTraffic:
            return "Idle"
        case .retrying:
            return "Retrying"
        case .stalled:
            return "Stalled"
        case .failed:
            return "Unavailable"
        case .stopped:
            return "Stopped"
        }
    }

    @ViewBuilder
    private func previewRow(_ row: PreviewProcessRow) -> some View {
        switch row {
        case let .active(usage):
            previewUsageRow(usage: usage, isLowTraffic: false)

        case let .lowTraffic(usage):
            previewUsageRow(usage: usage, isLowTraffic: true)

        case .empty:
            previewEmptyRow
        }
    }

    private func previewUsageRow(usage: ProcessUsage, isLowTraffic: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(usage.name)
                .font(.body.weight(.medium))
                .foregroundStyle(isLowTraffic ? .secondary : .primary)
                .lineLimit(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ \(NetworkFormatting.rate(usage.downloadBytesPerSecond))")
                Text("↑ \(NetworkFormatting.rate(usage.uploadBytesPerSecond))")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(isLowTraffic ? .tertiary : .secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var previewEmptyRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(" ")
                .font(.body.weight(.medium))
                .lineLimit(1)
                .hidden()

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(" ")
                    .hidden()
                Text(" ")
                    .hidden()
            }
            .font(.system(.caption, design: .monospaced))
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private func statusBanner(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct DashboardView: View {
    @ObservedObject var store: TrafficDashboardStore
    @StateObject private var processIconResolver = ProcessIconResolver()
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch store.viewState {
            case .starting:
                statusPanel(
                    title: "Starting capture…",
                    subtitle: "Launching nettop and waiting for the first 1-second sample."
                )

            case .noTraffic:
                content

            case .retrying, .stalled, .failed, .stopped, .live:
                content
            }
        }
        .padding(24)
        .frame(minWidth: 920, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRestart) {
                    Label("Restart Capture", systemImage: "arrow.clockwise")
                }
                .disabled(!store.viewState.allowsManualRestart)
                .help("Restart Capture")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Monitor")
                        .font(.system(size: 28, weight: .semibold))
                    Text(store.dashboardSubtitleText)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    metricCard(
                        title: "Download",
                        value: store.totalDownloadText,
                        trend: store.downloadTrend,
                        tint: .blue
                    )
                    metricCard(
                        title: "Upload",
                        value: store.totalUploadText,
                        trend: store.uploadTrend,
                        tint: .green
                    )
                }
            }

            HStack(spacing: 12) {
                Picker("Mode", selection: $store.selectedDisplayMode) {
                    ForEach(TrafficDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if store.selectedDisplayMode == .average {
                    Picker("Average Window", selection: $store.selectedAverageWindow) {
                        ForEach(AverageWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                Text(store.displayModeSummaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack {
                TextField("Search by process name or PID", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                Spacer()

                if let snapshotTime = store.snapshotTimeText {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Updated \(snapshotTime)")
                        if let lastSuccessfulCaptureText = store.lastSuccessfulCaptureText, lastSuccessfulCaptureText != snapshotTime {
                            Text("Last good sample \(lastSuccessfulCaptureText)")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let stateMessage = store.stateMessage, !stateMessage.isEmpty {
                statusPanel(
                    title: panelTitle,
                    subtitle: stateMessage
                )
            }

            if store.displayedProcesses.isEmpty {
                statusPanel(
                    title: store.snapshot == nil ? "No captured processes" : "No matching processes",
                    subtitle: store.snapshot == nil ? "The capture pipeline does not have a live snapshot to display." : "Adjust the search term to see active network consumers."
                )
            } else {
                Table(store.displayedProcesses, sortOrder: $store.sortOrder) {
                    TableColumn("Process", value: \.name) { usage in
                        ProcessNameCell(usage: usage, iconResolver: processIconResolver)
                    }
                    .width(min: 220, ideal: 260, max: 360)

                    TableColumn("PID", value: \.pid) { usage in
                        Text("\(usage.pid)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 70, ideal: 80, max: 90)

                    TableColumn("Download", sortUsing: KeyPathComparator(\ProcessUsage.downloadBytesPerSecond, order: .reverse)) { usage in
                        DirectionRateCell(
                            symbolName: "arrow.down",
                            tint: .blue,
                            value: NetworkFormatting.rate(usage.downloadBytesPerSecond)
                        )
                    }
                    .width(min: 125, ideal: 135, max: 150)

                    TableColumn("Upload", sortUsing: KeyPathComparator(\ProcessUsage.uploadBytesPerSecond, order: .reverse)) { usage in
                        DirectionRateCell(
                            symbolName: "arrow.up",
                            tint: .green,
                            value: NetworkFormatting.rate(usage.uploadBytesPerSecond)
                        )
                    }
                    .width(min: 125, ideal: 135, max: 150)

                    TableColumn("Total", sortUsing: KeyPathComparator(\ProcessUsage.totalBytesPerSecond, order: .reverse)) { usage in
                        Text(NetworkFormatting.rate(usage.totalBytesPerSecond))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 120, ideal: 130, max: 145)

                    TableColumn("Share", sortUsing: KeyPathComparator(\ProcessUsage.shareOfTotal, order: .reverse)) { usage in
                        ShareBarCell(share: usage.shareOfTotal)
                    }
                    .width(min: 105, ideal: 120, max: 130)

                    TableColumn("Last Seen", sortUsing: KeyPathComparator(\ProcessUsage.lastSeen, order: .reverse)) { usage in
                        Text(NetworkFormatting.lastSeen(usage.lastSeen))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 90, ideal: 100, max: 120)
                }
            }
        }
    }

    private var panelTitle: String {
        switch store.viewState {
        case .starting:
            return "Starting capture…"
        case .live:
            return store.selectedDisplayMode == .live ? "Live traffic" : "Average traffic"
        case .noTraffic:
            return store.selectedDisplayMode == .live ? "No active traffic" : "No traffic in selected average"
        case .retrying:
            return "Retrying capture"
        case .stalled:
            return "Live data stalled"
        case .failed:
            return "Capture unavailable"
        case .stopped:
            return "Capture stopped"
        }
    }

    private func metricCard(
        title: String,
        value: String,
        trend: TrafficTrendSeries,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: trendIconName(for: trend))
                        .font(.caption2.weight(.semibold))
                    Text(trendTitle(for: trend))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))

            TrafficSparklineView(series: trend, tint: tint)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(width: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func trendTitle(for trend: TrafficTrendSeries) -> String {
        trend.samples.count < 2 ? "Waiting" : trend.direction.title
    }

    private func trendIconName(for trend: TrafficTrendSeries) -> String {
        trend.samples.count < 2 ? "clock" : trend.direction.systemImageName
    }

    private func statusPanel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct TrafficSparklineView: View {
    let series: TrafficTrendSeries
    let tint: Color

    var body: some View {
        Group {
            if series.samples.isEmpty {
                emptySparkline
            } else {
                Chart {
                    ForEach(series.samples) { sample in
                        LineMark(
                            x: .value("Time", sample.capturedAt),
                            y: .value("Rate", sample.normalizedValue)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(tint)

                        if series.samples.count == 1 {
                            PointMark(
                                x: .value("Time", sample.capturedAt),
                                y: .value("Rate", sample.normalizedValue)
                            )
                            .foregroundStyle(tint)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: -0.05...1)
            }
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.25))
                .frame(height: 1)
        }
        .accessibilityLabel("Traffic trend \(series.direction.title)")
    }

    private var emptySparkline: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum ProcessIcon {
    case image(NSImage)
    case symbol(String)
}

@MainActor
private final class ProcessIconResolver: ObservableObject {
    private var cachedIcons: [Int: ProcessIcon] = [:]

    func icon(for usage: ProcessUsage) -> ProcessIcon {
        if let cachedIcon = cachedIcons[usage.pid] {
            return cachedIcon
        }

        let resolvedIcon = resolveIcon(for: usage)
        cachedIcons[usage.pid] = resolvedIcon
        return resolvedIcon
    }

    private func resolveIcon(for usage: ProcessUsage) -> ProcessIcon {
        guard usage.pid > 0,
              let runningApplication = NSRunningApplication(processIdentifier: pid_t(usage.pid)),
              let icon = runningApplication.icon else {
            return .symbol("gearshape")
        }

        return .image(icon)
    }
}

private struct ProcessNameCell: View {
    let usage: ProcessUsage
    let iconResolver: ProcessIconResolver

    var body: some View {
        HStack(spacing: 8) {
            ProcessIconView(icon: iconResolver.icon(for: usage))

            Text(usage.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
}

private struct ProcessIconView: View {
    let icon: ProcessIcon

    var body: some View {
        Group {
            switch icon {
            case let .image(image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            case let .symbol(symbolName):
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct DirectionRateCell: View {
    let symbolName: String
    let tint: Color
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 12)

            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .trailing)
        .accessibilityLabel("\(symbolName == "arrow.down" ? "Download" : "Upload") \(value)")
    }
}

private struct ShareBarCell: View {
    let share: Double

    private var normalizedShare: Double {
        NetworkFormatting.normalizedShare(share)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NetworkFormatting.percentage(normalizedShare))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.25))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: proxy.size.width * normalizedShare)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
        .accessibilityLabel("\(NetworkFormatting.percentage(normalizedShare)) share")
    }
}
