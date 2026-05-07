import AppKit
import SwiftUI

enum StatusPreviewLayout {
    static let panelSize = CGSize(width: 392, height: 520)
    static let margin: CGFloat = 8
    static let statusItemReferenceText = "↓ 99.9T\n↑ 99.9T"
}

struct NetworkMonitorLaunchOptions: Equatable {
    let showPreviewOnLaunch: Bool
    let openDashboardOnLaunch: Bool

    init(arguments: [String] = CommandLine.arguments) {
        showPreviewOnLaunch = arguments.contains("--debug-show-preview")
        openDashboardOnLaunch = arguments.contains("--debug-open-dashboard")
    }
}

enum StatusPopoverPositioning {
    static func placementFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaInsets: NSEdgeInsets?
    ) -> CGRect {
        guard let safeAreaInsets else {
            return visibleFrame
        }

        let safeFrame = CGRect(
            x: screenFrame.minX + safeAreaInsets.left,
            y: screenFrame.minY + safeAreaInsets.bottom,
            width: screenFrame.width - safeAreaInsets.left - safeAreaInsets.right,
            height: screenFrame.height - safeAreaInsets.top - safeAreaInsets.bottom
        )
        let minX = Swift.max(visibleFrame.minX, safeFrame.minX)
        let minY = Swift.max(visibleFrame.minY, safeFrame.minY)
        let maxX = Swift.min(visibleFrame.maxX, safeFrame.maxX)
        let maxY = Swift.min(visibleFrame.maxY, safeFrame.maxY)

        guard maxX >= minX, maxY >= minY else {
            return visibleFrame
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func origin(
        anchorFrame: CGRect,
        popoverSize: CGSize,
        placementFrame: CGRect,
        margin: CGFloat = StatusPreviewLayout.margin
    ) -> CGPoint {
        let minimumX = placementFrame.minX + margin
        let maximumX = max(minimumX, placementFrame.maxX - popoverSize.width - margin)
        let idealX = anchorFrame.midX - (popoverSize.width / 2)
        let x = min(max(idealX, minimumX), maximumX)

        let minimumY = placementFrame.minY + margin
        let y = max(minimumY, placementFrame.maxY - popoverSize.height - margin)

        return CGPoint(x: x, y: y)
    }
}

enum StatusPreviewInteractionState: Equatable {
    case idle
    case hoverPending
    case previewVisible
    case dismissPending
    case contextMenuVisible
    case hoverSuppressed
}

enum StatusPreviewHoverRegion: Equatable {
    case statusItem
    case previewPanel
    case outside
}

enum StatusPreviewInteractionAction: Equatable {
    case scheduleHoverOpen
    case cancelHoverOpen
    case scheduleDismiss
    case cancelDismiss
    case showPreview
    case closePreview
    case showContextMenu
}

struct StatusPreviewInteractionModel {
    private(set) var state: StatusPreviewInteractionState = .idle

    mutating func observe(region: StatusPreviewHoverRegion) -> [StatusPreviewInteractionAction] {
        switch state {
        case .contextMenuVisible:
            return []

        case .hoverSuppressed:
            guard region != .statusItem else {
                return []
            }
            state = .idle
            return []

        case .idle:
            guard region == .statusItem else {
                return []
            }
            state = .hoverPending
            return [.scheduleHoverOpen]

        case .hoverPending:
            guard region == .outside else {
                return []
            }
            state = .idle
            return [.cancelHoverOpen]

        case .previewVisible:
            guard region == .outside else {
                return []
            }
            state = .dismissPending
            return [.scheduleDismiss]

        case .dismissPending:
            guard region != .outside else {
                return []
            }
            state = .previewVisible
            return [.cancelDismiss]
        }
    }

    mutating func hoverDelayElapsed(currentRegion: StatusPreviewHoverRegion) -> [StatusPreviewInteractionAction] {
        guard state == .hoverPending else {
            return []
        }

        guard currentRegion == .statusItem else {
            state = .idle
            return []
        }

        state = .previewVisible
        return [.showPreview]
    }

    mutating func dismissDelayElapsed(currentRegion: StatusPreviewHoverRegion) -> [StatusPreviewInteractionAction] {
        guard state == .dismissPending else {
            return []
        }

        guard currentRegion == .outside else {
            state = .previewVisible
            return []
        }

        state = .idle
        return [.closePreview]
    }

    mutating func leftClick() -> [StatusPreviewInteractionAction] {
        state = .previewVisible
        return [.cancelHoverOpen, .cancelDismiss, .showPreview]
    }

    mutating func rightClick() -> [StatusPreviewInteractionAction] {
        state = .contextMenuVisible
        return [.cancelHoverOpen, .cancelDismiss, .closePreview, .showContextMenu]
    }

    mutating func forceClose() {
        state = .idle
    }

    mutating func suppressHoverUntilStatusItemExit() {
        state = .hoverSuppressed
    }

    mutating func contextMenuDidClose() {
        state = .idle
    }
}

final class StatusPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusPreviewPanelController {
    private let panel: StatusPreviewPanel

    init(
        store: TrafficDashboardStore,
        onOpen: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) {
        let contentRect = NSRect(origin: .zero, size: StatusPreviewLayout.panelSize)
        let panel = StatusPreviewPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.worksWhenModal = true
        panel.animationBehavior = .utilityWindow
        panel.isRestorable = false

        panel.contentViewController = NSHostingController(
            rootView: PreviewPanelView(
                store: store,
                onOpen: onOpen,
                onRestart: onRestart
            )
        )
        panel.setContentSize(StatusPreviewLayout.panelSize)

        self.panel = panel
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var frame: NSRect? {
        panel.isVisible ? panel.frame : nil
    }

    func show(anchorFrame: NSRect, screen: NSScreen) {
        reposition(anchorFrame: anchorFrame, screen: screen)
        guard !panel.isVisible else {
            return
        }

        NetworkMonitorDiagnostics.menuBar("Opening preview panel.")
        panel.makeKeyAndOrderFront(nil)
    }

    func reposition(anchorFrame: NSRect, screen: NSScreen) {
        let placementFrame = StatusPopoverPositioning.placementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: {
                if #available(macOS 12.0, *) {
                    return screen.safeAreaInsets
                } else {
                    return nil
                }
            }()
        )

        let origin = StatusPopoverPositioning.origin(
            anchorFrame: anchorFrame,
            popoverSize: StatusPreviewLayout.panelSize,
            placementFrame: placementFrame
        )
        panel.setFrame(NSRect(origin: origin, size: StatusPreviewLayout.panelSize), display: panel.isVisible)
    }

    func close() {
        guard panel.isVisible else {
            return
        }

        NetworkMonitorDiagnostics.menuBar("Closing preview panel.")
        panel.orderOut(nil)
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
