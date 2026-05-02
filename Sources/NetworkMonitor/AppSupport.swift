import AppKit
import Combine
import SwiftUI

enum StatusPreviewLayout {
    static let panelSize = CGSize(width: 392, height: 520)
    static let margin: CGFloat = 8
    static let statusItemReferenceText = "↓ 99.9T ↑ 99.9T"
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
    case openDashboard
    case showContextMenu
}

struct StatusPreviewInteractionModel {
    private(set) var state: StatusPreviewInteractionState = .idle

    mutating func observe(region: StatusPreviewHoverRegion) -> [StatusPreviewInteractionAction] {
        switch state {
        case .contextMenuVisible:
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
        state = .idle
        return [.cancelHoverOpen, .cancelDismiss, .closePreview, .openDashboard]
    }

    mutating func rightClick() -> [StatusPreviewInteractionAction] {
        state = .contextMenuVisible
        return [.cancelHoverOpen, .cancelDismiss, .closePreview, .showContextMenu]
    }

    mutating func forceClose() {
        state = .idle
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences: NetworkMonitorPreferences
    private let store: TrafficDashboardStore
    private let launchOptions = NetworkMonitorLaunchOptions()
    private var statusItemController: StatusItemController?
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?

    override init() {
        let preferences = NetworkMonitorPreferences()
        self.preferences = preferences
        self.store = TrafficDashboardStore(preferences: preferences)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()

        mainWindowController = MainWindowController(
            store: store,
            onRestart: { [weak self] in
                self?.store.restartCapture()
            }
        )

        settingsWindowController = SettingsWindowController(preferences: preferences)

        statusItemController = StatusItemController(
            store: store,
            onOpen: { [weak self] in
                self?.openDashboard()
            },
            onRestart: { [weak self] in
                self?.store.restartCapture()
            },
            onSettings: { [weak self] in
                self?.openSettings()
            },
            onQuit: { [weak self] in
                self?.terminateApplication()
            }
        )

        store.start()

        if launchOptions.openDashboardOnLaunch {
            openDashboard(resetPosition: true, forceFront: true)
        }

        if launchOptions.showPreviewOnLaunch {
            statusItemController?.showPreviewWhenReadyForDebug()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    private func openDashboard(resetPosition: Bool = false, forceFront: Bool = false) {
        mainWindowController?.showDashboard(resetPosition: resetPosition, forceFront: forceFront)
    }

    @objc
    private func openSettings() {
        settingsWindowController?.showSettings()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit NetworkMonitor",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func terminateApplication() {
        store.stop()
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(preferences: NetworkMonitorPreferences) {
        let rootView = SettingsView(preferences: preferences)
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("NetworkMonitorSettingsWindow")

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        guard let window else {
            return
        }

        NetworkMonitorDiagnostics.window("Opening settings window.")
        if !MainWindowController.isVisibleOnAnyScreen(window.frame) {
            MainWindowController.centerWindowOnMainVisibleScreen(window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
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

    func showDashboard(resetPosition: Bool = false, forceFront: Bool = false) {
        guard let window else {
            return
        }

        NetworkMonitorDiagnostics.window("Opening dashboard window.")
        if resetPosition || !Self.isVisibleOnAnyScreen(window.frame) {
            Self.centerWindowOnMainVisibleScreen(window)
        }
        window.level = forceFront ? .floating : .normal
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        if resetPosition {
            Self.centerWindowOnMainVisibleScreen(window)
        }
    }

    static func isVisibleOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(frame)
        }
    }

    static func centerWindowOnMainVisibleScreen(_ window: NSWindow) {
        guard let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            window.center()
            return
        }

        let size = window.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
        window.setFrame(NSRect(origin: origin, size: size), display: window.isVisible)
    }
}

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

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
