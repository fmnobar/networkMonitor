import AppKit
import SwiftUI

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
        .frame(minWidth: 1_360, minHeight: 620)
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
                .labelsHidden()
                .frame(width: 220)

                if store.selectedDisplayMode == .average {
                    Picker("Average Window", selection: $store.selectedAverageWindow) {
                        ForEach(AverageWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }

                Text(store.displayModeSummaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack {
                DashboardSearchField(text: $store.searchText)

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
                            value: NetworkFormatting.rate(usage.downloadBytesPerSecond, unitStyle: store.rateUnitStyle)
                        )
                    }
                    .width(min: 125, ideal: 135, max: 150)

                    TableColumn("Upload", sortUsing: KeyPathComparator(\ProcessUsage.uploadBytesPerSecond, order: .reverse)) { usage in
                        DirectionRateCell(
                            symbolName: "arrow.up",
                            tint: .green,
                            value: NetworkFormatting.rate(usage.uploadBytesPerSecond, unitStyle: store.rateUnitStyle)
                        )
                    }
                    .width(min: 125, ideal: 135, max: 150)

                    TableColumn("Total", sortUsing: KeyPathComparator(\ProcessUsage.totalBytesPerSecond, order: .reverse)) { usage in
                        Text(NetworkFormatting.rate(usage.totalBytesPerSecond, unitStyle: store.rateUnitStyle))
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

private struct DashboardSearchField: View {
    @Binding var text: String

    var body: some View {
        TextField("Search by process name or PID", text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: 320, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
            )
            .accessibilityLabel("Search by process name or PID")
    }
}
