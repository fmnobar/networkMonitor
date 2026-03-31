import SwiftUI

struct PreviewPopoverView: View {
    @ObservedObject var store: TrafficDashboardStore
    let onOpen: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Network Usage")
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

                VStack(alignment: .trailing, spacing: 2) {
                    Text("↓ \(store.totalDownloadText)")
                    Text("↑ \(store.totalUploadText)")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Divider()

            if let stateMessage = store.stateMessage, !stateMessage.isEmpty {
                statusBanner(
                    title: bannerTitle,
                    message: stateMessage
                )
            }

            Group {
                switch store.viewState {
                case .starting:
                    previewPlaceholder(title: "Starting capture…", subtitle: "Launching nettop and waiting for the first sample.")
                case .stopped(nil), .failed(nil, _), .retrying(nil, _):
                    previewPlaceholder(title: emptyStateTitle, subtitle: store.stateMessage ?? "Capture has no live data yet.")
                case .live, .noTraffic, .retrying, .stalled, .failed, .stopped:
                    if let snapshot = store.activeSnapshot, !snapshot.processes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Top 5 Consumers")
                                .font(.subheadline.weight(.semibold))

                            ForEach(Array(snapshot.processes.prefix(5))) { usage in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(usage.name)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)
                                        Text("PID \(usage.pid)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("↓ \(NetworkFormatting.rate(usage.downloadBytesPerSecond))")
                                        Text("↑ \(NetworkFormatting.rate(usage.uploadBytesPerSecond))")
                                        Text("Σ \(NetworkFormatting.rate(usage.totalBytesPerSecond))")
                                            .foregroundStyle(.primary)
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        previewPlaceholder(title: emptyStateTitle, subtitle: store.stateMessage ?? "No process reported network usage in the latest interval.")
                    }
                }
            }

            Divider()

            HStack {
                Button("Open Dashboard", action: onOpen)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Restart Capture", action: onRestart)
            }
        }
        .padding(16)
        .frame(width: 360)
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

    private var emptyStateTitle: String {
        switch store.viewState {
        case .starting:
            return "Starting capture…"
        case .retrying:
            return "Retrying capture"
        case .failed:
            return "Capture unavailable"
        case .stopped:
            return "Capture stopped"
        case .stalled:
            return "Live data stalled"
        case .noTraffic, .live:
            return "No active traffic"
        }
    }

    @ViewBuilder
    private func previewPlaceholder(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Monitor")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Live per-process bandwidth from nettop")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    metricCard(title: "Download", value: store.totalDownloadText)
                    metricCard(title: "Upload", value: store.totalUploadText)
                }
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
                        Text(usage.name)
                            .lineLimit(1)
                    }
                    .width(min: 210, ideal: 260)

                    TableColumn("PID", value: \.pid) { usage in
                        Text("\(usage.pid)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Download", sortUsing: KeyPathComparator(\ProcessUsage.downloadBytesPerSecond, order: .reverse)) { usage in
                        Text(NetworkFormatting.rate(usage.downloadBytesPerSecond))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Upload", sortUsing: KeyPathComparator(\ProcessUsage.uploadBytesPerSecond, order: .reverse)) { usage in
                        Text(NetworkFormatting.rate(usage.uploadBytesPerSecond))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Total", sortUsing: KeyPathComparator(\ProcessUsage.totalBytesPerSecond, order: .reverse)) { usage in
                        Text(NetworkFormatting.rate(usage.totalBytesPerSecond))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 120, ideal: 140)

                    TableColumn("Share", sortUsing: KeyPathComparator(\ProcessUsage.shareOfTotal, order: .reverse)) { usage in
                        Text(NetworkFormatting.percentage(usage.shareOfTotal))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 80, ideal: 90)

                    TableColumn("Last Seen", sortUsing: KeyPathComparator(\ProcessUsage.lastSeen, order: .reverse)) { usage in
                        Text(NetworkFormatting.lastSeen(usage.lastSeen))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 90, ideal: 110)
                }
            }
        }
    }

    private var panelTitle: String {
        switch store.viewState {
        case .starting:
            return "Starting capture…"
        case .live:
            return "Live traffic"
        case .noTraffic:
            return "No active traffic"
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

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
