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

            Group {
                switch store.viewState {
                case .starting:
                    previewPlaceholder(title: "Starting capture…", subtitle: "Launching nettop and waiting for the first sample.")
                case .noTraffic:
                    previewPlaceholder(title: "No active traffic", subtitle: "No process reported network usage in the latest interval.")
                case let .failed(message):
                    previewPlaceholder(title: "Capture unavailable", subtitle: message)
                case .live:
                    if store.topFive.isEmpty {
                        previewPlaceholder(title: "No active traffic", subtitle: "No process reported network usage in the latest interval.")
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Top 5 Consumers")
                                .font(.subheadline.weight(.semibold))

                            ForEach(store.topFive) { usage in
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

            case .noTraffic(let date):
                statusPanel(
                    title: "No active traffic",
                    subtitle: date.map { "No process reported traffic in the sample captured at \(NetworkFormatting.snapshotTime($0))." }
                        ?? "No process reported traffic in the latest sample."
                )

            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    statusPanel(
                        title: "Capture unavailable",
                        subtitle: message
                    )

                    Button("Restart Capture", action: onRestart)
                }

            case .live:
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
                    Text("Updated \(snapshotTime)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.displayedProcesses.isEmpty {
                statusPanel(
                    title: "No matching processes",
                    subtitle: "Adjust the search term to see active network consumers."
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
