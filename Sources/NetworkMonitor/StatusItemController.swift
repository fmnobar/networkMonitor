import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject {
    private let store: TrafficDashboardStore
    private let onOpen: () -> Void
    private let onRestart: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    private let statusItemWidth: CGFloat

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var previewPanelController = StatusPreviewPanelController(
        store: store,
        onOpen: { [weak self] in
            self?.openDashboard()
        },
        onRestart: { [weak self] in
            self?.restartCapture()
        }
    )

    private var statusLabelCancellable: AnyCancellable?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var hoverObservationTimer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var screenParametersObserver: Any?
    private var debugPreviewTask: Task<Void, Never>?
    private var interactionModel = StatusPreviewInteractionModel()
    private var lastPreviewAnchorFrame: NSRect?

    init(
        store: TrafficDashboardStore,
        onOpen: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onOpen = onOpen
        self.onRestart = onRestart
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.statusItemWidth = Self.measureStatusItemWidth()
        super.init()

        configureStatusItem()
        bindStore()
        startHoverObservation()
        observeScreenChanges()
    }

    func showPreviewWhenReadyForDebug() {
        debugPreviewTask?.cancel()
        debugPreviewTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let maxAttempts = 30
            let retryDelayNanoseconds: UInt64 = 100_000_000
            NetworkMonitorDiagnostics.menuBar("Debug preview requested; waiting for status item frame.")

            for attempt in 1...maxAttempts {
                if Task.isCancelled {
                    return
                }

                if let context = self.previewPlacementContext() {
                    NetworkMonitorDiagnostics.menuBar("Opening debug preview after \(attempt) attempt(s).")
                    self.showPreviewPanel(using: context, installDismissMonitors: false)
                    return
                }

                if attempt == 1 || attempt == maxAttempts {
                    NetworkMonitorDiagnostics.menuBar("Debug preview attempt \(attempt) unavailable: \(self.previewPlacementFailureReason()).")
                }

                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            execute(interactionModel.leftClick())
            return
        }

        switch event.type {
        case .rightMouseUp:
            execute(interactionModel.rightClick(), contextMenuEvent: event)
        case .leftMouseUp:
            execute(interactionModel.leftClick())
        default:
            break
        }
    }

    @objc
    private func openDashboard() {
        interactionModel.forceClose()
        closePreviewPanel()
        onOpen()
    }

    @objc
    private func restartCapture() {
        interactionModel.forceClose()
        closePreviewPanel()
        onRestart()
    }

    @objc
    private func openSettings() {
        interactionModel.forceClose()
        closePreviewPanel()
        onSettings()
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
    }

    private func bindStore() {
        statusLabelCancellable = store.$statusLabelText
            .receive(on: RunLoop.main)
            .sink { [weak self] statusText in
                self?.updateButtonTitle(with: statusText)
            }
    }

    private func observeScreenChanges() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPreviewIfNeeded(force: true)
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
            string: StatusPreviewLayout.statusItemReferenceText,
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
        if previewPanelController.isVisible {
            repositionPreviewIfNeeded()
        }

        let actions = interactionModel.observe(region: currentHoverRegion())
        execute(actions)
    }

    private func execute(_ actions: [StatusPreviewInteractionAction], contextMenuEvent: NSEvent? = nil) {
        for action in actions {
            switch action {
            case .scheduleHoverOpen:
                scheduleHoverOpen()

            case .cancelHoverOpen:
                cancelHoverTask()

            case .scheduleDismiss:
                scheduleDismissCheck()

            case .cancelDismiss:
                cancelDismissTask()

            case .showPreview:
                showPreviewPanel()

            case .closePreview:
                closePreviewPanel()

            case .openDashboard:
                openDashboard()

            case .showContextMenu:
                guard let contextMenuEvent else {
                    continue
                }
                showContextMenu(with: contextMenuEvent)
            }
        }
    }

    private func scheduleHoverOpen() {
        cancelHoverTask()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self else {
                return
            }

            let actions = self.interactionModel.hoverDelayElapsed(currentRegion: self.currentHoverRegion())
            self.execute(actions)
        }
    }

    private func scheduleDismissCheck() {
        cancelDismissTask()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else {
                return
            }

            let actions = self.interactionModel.dismissDelayElapsed(currentRegion: self.currentHoverRegion())
            self.execute(actions)
        }
    }

    private func showPreviewPanel() {
        guard let context = previewPlacementContext() else {
            NetworkMonitorDiagnostics.menuBar("Unable to open preview panel: \(previewPlacementFailureReason()).")
            interactionModel.forceClose()
            return
        }

        showPreviewPanel(using: context)
    }

    private func showPreviewPanel(
        using context: (buttonFrame: NSRect, screen: NSScreen),
        installDismissMonitors: Bool = true
    ) {
        cancelDismissTask()
        previewPanelController.show(anchorFrame: context.buttonFrame, screen: context.screen)
        if installDismissMonitors {
            installEventMonitors()
        }
        lastPreviewAnchorFrame = context.buttonFrame
    }

    private func previewPlacementContext() -> (buttonFrame: NSRect, screen: NSScreen)? {
        guard
            let buttonFrame = statusItemButtonFrame(),
            let screen = screenForAnchorFrame(buttonFrame)
        else {
            return nil
        }

        return (buttonFrame, screen)
    }

    private func previewPlacementFailureReason() -> String {
        guard let button = statusItem.button else {
            return "status item button unavailable"
        }

        guard button.window != nil else {
            return "status item button window unavailable"
        }

        guard let buttonFrame = statusItemButtonFrame() else {
            return "status item frame unavailable"
        }

        guard screenForAnchorFrame(buttonFrame) != nil else {
            return "screen unavailable for status item frame \(buttonFrame)"
        }

        return "unknown preview placement failure"
    }

    private func repositionPreviewIfNeeded(force: Bool = false) {
        guard
            previewPanelController.isVisible,
            let buttonFrame = statusItemButtonFrame(),
            let screen = screenForAnchorFrame(buttonFrame)
        else {
            return
        }

        guard force || lastPreviewAnchorFrame != buttonFrame else {
            return
        }

        previewPanelController.reposition(anchorFrame: buttonFrame, screen: screen)
        lastPreviewAnchorFrame = buttonFrame
    }

    private func showContextMenu(with event: NSEvent) {
        closePreviewPanel()

        guard let button = statusItem.button else {
            interactionModel.contextMenuDidClose()
            return
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open", action: #selector(openDashboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart Capture", action: #selector(restartCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        NetworkMonitorDiagnostics.menuBar("Opening status item context menu.")
        NSMenu.popUpContextMenu(menu, with: event, for: button)
        interactionModel.contextMenuDidClose()
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else {
            return
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(forceDismiss: true)
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(forceDismiss: true)
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

    private func handlePointerEvent(forceDismiss: Bool) {
        guard previewPanelController.isVisible, forceDismiss else {
            return
        }

        guard currentHoverRegion() == .outside else {
            return
        }

        interactionModel.forceClose()
        closePreviewPanel()
    }

    private func closePreviewPanel() {
        cancelHoverTask()
        cancelDismissTask()
        previewPanelController.close()
        removeEventMonitors()
        lastPreviewAnchorFrame = nil
    }

    private func currentHoverRegion(for screenLocation: NSPoint = NSEvent.mouseLocation) -> StatusPreviewHoverRegion {
        if let buttonFrame = statusItemButtonFrame(), buttonFrame.contains(screenLocation) {
            return .statusItem
        }

        if let panelFrame = previewPanelController.frame, panelFrame.contains(screenLocation) {
            return .previewPanel
        }

        return .outside
    }

    private func screenForAnchorFrame(_ anchorFrame: NSRect) -> NSScreen? {
        if let buttonScreen = statusItem.button?.window?.screen {
            return buttonScreen
        }

        return NSScreen.screens.first { screen in
            screen.frame.intersects(anchorFrame) || screen.frame.contains(anchorFrame.center)
        } ?? NSScreen.main
    }

    private func statusItemButtonFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else {
            return nil
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func cancelHoverTask() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func cancelDismissTask() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
