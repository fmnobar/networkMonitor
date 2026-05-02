import AppKit
import SwiftUI

fileprivate enum ProcessIcon {
    case image(NSImage)
    case symbol(String)
}

@MainActor
final class ProcessIconResolver: ObservableObject {
    private var cachedIcons: [Int: ProcessIcon] = [:]

    fileprivate func icon(for usage: ProcessUsage) -> ProcessIcon {
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

struct ProcessNameCell: View {
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

struct DirectionRateCell: View {
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

struct ShareBarCell: View {
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
