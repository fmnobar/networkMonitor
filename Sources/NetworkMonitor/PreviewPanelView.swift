import AppKit
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

                VStack(alignment: .trailing, spacing: 4) {
                    previewMetricTrend(
                        symbol: "↓",
                        value: store.totalDownloadText,
                        trend: store.downloadTrend,
                        tint: .blue
                    )
                    previewMetricTrend(
                        symbol: "↑",
                        value: store.totalUploadText,
                        trend: store.uploadTrend,
                        tint: .green
                    )
                }
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

    private func previewMetricTrend(
        symbol: String,
        value: String,
        trend: TrafficTrendSeries,
        tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            TrafficSparklineView(series: trend, tint: tint, height: 18)
                .frame(width: 78)

            Text("\(symbol) \(value)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(symbol == "↓" ? "Download" : "Upload") \(value)")
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
                Text("↓ \(NetworkFormatting.rate(usage.downloadBytesPerSecond, unitStyle: store.rateUnitStyle))")
                Text("↑ \(NetworkFormatting.rate(usage.uploadBytesPerSecond, unitStyle: store.rateUnitStyle))")
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
