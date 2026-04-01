import AppKit
import Combine
import SwiftUI

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
        let minX: CGFloat = Swift.max(visibleFrame.minX, safeFrame.minX)
        let minY: CGFloat = Swift.max(visibleFrame.minY, safeFrame.minY)
        let maxX: CGFloat = Swift.min(visibleFrame.maxX, safeFrame.maxX)
        let maxY: CGFloat = Swift.min(visibleFrame.maxY, safeFrame.maxY)

        guard maxX >= minX, maxY >= minY else {
            return visibleFrame
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func origin(
        anchorFrame: CGRect,
        popoverSize: CGSize,
        placementFrame: CGRect,
        margin: CGFloat = 8
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TrafficDashboardStore()
    private var statusItemController: StatusItemController?
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindowController = MainWindowController(
            store: store,
            onRestart: { [weak self] in
                self?.store.restartCapture()
            }
        )

        statusItemController = StatusItemController(
            store: store,
            onOpen: { [weak self] in
                self?.openDashboard()
            },
            onRestart: { [weak self] in
                self?.store.restartCapture()
            },
            onQuit: { [weak self] in
                self?.terminateApplication()
            }
        )

        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    private func openDashboard() {
        mainWindowController?.showDashboard()
    }

    private func terminateApplication() {
        store.stop()
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    init(store: TrafficDashboardStore, onRestart: @escaping () -> Void) {
        let rootView = DashboardView(store: store, onRestart: onRestart)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Network Monitor"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NetworkMonitorMainWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showDashboard() {
        guard let window else {
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private enum InteractionState: Equatable {
        case idle
        case hoverPending
        case popoverVisible
        case dismissPending
        case contextMenuVisible
        case openingWindow
    }

    private enum HoverRegion {
        case statusItem
        case popover
        case outside
    }

    private let store: TrafficDashboardStore
    private let onOpen: () -> Void
    private let onRestart: () -> Void
    private let onQuit: () -> Void
    private let statusItemWidth: CGFloat

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    private var statusLabelCancellable: AnyCancellable?
    private var popoverLayoutCancellable: AnyCancellable?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var hoverObservationTimer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var interactionState: InteractionState = .idle

    init(
        store: TrafficDashboardStore,
        onOpen: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onOpen = onOpen
        self.onRestart = onRestart
        self.onQuit = onQuit
        self.statusItemWidth = Self.measureStatusItemWidth()
        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        cancelPendingTasks()
        guard let event = NSApp.currentEvent else {
            openDashboard()
            return
        }

        switch event.type {
        case .rightMouseUp:
            transition(to: .contextMenuVisible)
            showContextMenu(with: event)
        case .leftMouseUp:
            transition(to: .openingWindow)
            openDashboard()
        default:
            break
        }
    }

    @objc
    private func openDashboard() {
        closePopover()
        onOpen()
        transition(to: .idle)
    }

    @objc
    private func restartCapture() {
        closePopover()
        onRestart()
        transition(to: .idle)
    }

    @objc
    private func quitApplication() {
        onQuit()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        statusItem.length = statusItemWidth
        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.lineBreakMode = .byClipping
        updateButtonTitle(with: store.statusLabelText)
        startHoverObservation()
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PreviewPopoverView(
                store: store,
                onOpen: { [weak self] in
                    self?.openDashboard()
                },
                onRestart: { [weak self] in
                    self?.restartCapture()
                }
            )
        )
    }

    private func bindStore() {
        statusLabelCancellable = store.$statusLabelText
            .receive(on: RunLoop.main)
            .sink { [weak self] statusText in
                self?.updateButtonTitle(with: statusText)
            }

        popoverLayoutCancellable = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    self?.positionPopoverWindow()
                }
            }
    }

    private func updateButtonTitle(with text: String) {
        guard let button = statusItem.button else {
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    private static func measureStatusItemWidth() -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ]
        let reference = NSAttributedString(
            string: "↓ 999.9 MB/s ↑ 999.9 MB/s",
            attributes: attributes
        )
        return ceil(reference.size().width) + 16
    }

    private func startHoverObservation() {
        hoverObservationTimer?.invalidate()

        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.observeHoverState()
            }
        }
        hoverObservationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeHoverState() {
        switch interactionState {
        case .contextMenuVisible, .openingWindow:
            return
        case .idle, .hoverPending, .popoverVisible, .dismissPending:
            break
        }

        switch currentHoverRegion() {
        case .statusItem:
            cancelDismissTask()
            if popover.isShown {
                transition(to: .popoverVisible)
            } else if interactionState == .idle {
                transition(to: .hoverPending)
                scheduleHoverPopover()
            }

        case .popover:
            guard popover.isShown else {
                return
            }
            cancelDismissTask()
            transition(to: .popoverVisible)

        case .outside:
            if popover.isShown {
                if interactionState != .dismissPending {
                    scheduleDismissCheck()
                }
            } else if interactionState == .hoverPending {
                cancelHoverTask()
                transition(to: .idle)
            }
        }
    }

    private func scheduleHoverPopover() {
        cancelHoverTask()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, self.interactionState == .hoverPending else {
                return
            }
            guard self.currentHoverRegion() == .statusItem else {
                self.transition(to: .idle)
                return
            }
            self.showHoverPopover()
        }
    }

    private func showHoverPopover() {
        guard let button = statusItem.button else {
            return
        }

        cancelDismissTask()

        guard !popover.isShown else {
            transition(to: .popoverVisible)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        positionPopoverWindow()
        DispatchQueue.main.async { [weak self] in
            self?.positionPopoverWindow()
        }
        transition(to: .popoverVisible)
        installEventMonitors()
    }

    private func positionPopoverWindow() {
        guard
            let popoverWindow = popover.contentViewController?.view.window,
            let buttonFrame = statusItemButtonFrame()
        else {
            return
        }

        let screen = popoverWindow.screen
            ?? statusItem.button?.window?.screen
            ?? NSScreen.main
        guard let screen else {
            return
        }

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
            anchorFrame: buttonFrame,
            popoverSize: popoverWindow.frame.size,
            placementFrame: placementFrame
        )
        popoverWindow.setFrameOrigin(origin)
    }

    private func showContextMenu(with event: NSEvent) {
        closePopover()

        guard let button = statusItem.button else {
            return
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart Capture", action: #selector(restartCapture), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        NSMenu.popUpContextMenu(menu, with: event, for: button)
        transition(to: .idle)
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else {
            return
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(event, forceDismiss: event.type == .leftMouseDown || event.type == .rightMouseDown)
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(event, forceDismiss: event.type == .leftMouseDown || event.type == .rightMouseDown)
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func handlePointerEvent(_ event: NSEvent, forceDismiss: Bool) {
        guard popover.isShown else {
            return
        }

        let hoverRegion = currentHoverRegion()
        switch hoverRegion {
        case .statusItem, .popover:
            cancelDismissTask()
            transition(to: .popoverVisible)
        case .outside:
            if forceDismiss {
                closePopover()
            } else {
                scheduleDismissCheck()
            }
        }
    }

    private func closePopover() {
        cancelPendingTasks()
        if popover.isShown {
            popover.performClose(nil)
        }
        removeEventMonitors()
    }

    private func scheduleDismissCheck() {
        guard popover.isShown else {
            transition(to: .idle)
            return
        }

        transition(to: .dismissPending)
        cancelDismissTask()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.interactionState == .dismissPending else {
                return
            }

            if self.currentHoverRegion() == .outside {
                self.closePopover()
                self.transition(to: .idle)
            } else {
                self.transition(to: .popoverVisible)
            }
        }
    }

    private func currentHoverRegion(for screenLocation: NSPoint = NSEvent.mouseLocation) -> HoverRegion {
        if let buttonFrame = statusItemButtonFrame(), buttonFrame.contains(screenLocation) {
            return .statusItem
        }

        if let popoverFrame = popover.contentViewController?.view.window?.frame, popoverFrame.contains(screenLocation) {
            return .popover
        }

        return .outside
    }

    private func statusItemButtonFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else {
            return nil
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func cancelPendingTasks() {
        cancelHoverTask()
        cancelDismissTask()
    }

    private func cancelHoverTask() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func cancelDismissTask() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func transition(to state: InteractionState) {
        guard interactionState != state else {
            return
        }
        interactionState = state
        NetworkMonitorDiagnostics.debug("Status item interaction state -> \(String(describing: state))")
    }

    func popoverDidClose(_ notification: Notification) {
        cancelDismissTask()
        removeEventMonitors()
        transition(to: .idle)
    }
}
