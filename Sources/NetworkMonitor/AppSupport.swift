import AppKit
import Combine
import SwiftUI

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
final class StatusItemController: NSObject {
    private let store: TrafficDashboardStore
    private let onOpen: () -> Void
    private let onRestart: () -> Void
    private let onQuit: () -> Void

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    private var statusLabelCancellable: AnyCancellable?
    private var hoverTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var mouseInsideButton = false

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
        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
    }

    @objc
    func mouseEntered(with event: NSEvent) {
        mouseInsideButton = true
        scheduleHoverPopover()
    }

    @objc
    func mouseExited(with event: NSEvent) {
        mouseInsideButton = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.dismissPopoverIfNeeded()
        }
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        hoverTask?.cancel()
        guard let event = NSApp.currentEvent else {
            openDashboard()
            return
        }

        switch event.type {
        case .rightMouseUp:
            showContextMenu(with: event)
        case .leftMouseUp:
            openDashboard()
        default:
            break
        }
    }

    @objc
    private func openDashboard() {
        popover.performClose(nil)
        removeEventMonitors()
        onOpen()
    }

    @objc
    private func restartCapture() {
        popover.performClose(nil)
        removeEventMonitors()
        onRestart()
    }

    @objc
    private func quitApplication() {
        onQuit()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Network Monitor"

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea

        updateButtonTitle(with: store.statusLabelText)
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
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

    private func scheduleHoverPopover() {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, self.mouseInsideButton else {
                return
            }
            self.showHoverPopover()
        }
    }

    private func showHoverPopover() {
        guard let button = statusItem.button, !popover.isShown else {
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installEventMonitors()
    }

    private func showContextMenu(with event: NSEvent) {
        popover.performClose(nil)
        removeEventMonitors()

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
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else {
            return
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.dismissPopoverIfNeeded(force: event.type == .leftMouseDown || event.type == .rightMouseDown)
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.dismissPopoverIfNeeded(force: event.type == .leftMouseDown || event.type == .rightMouseDown)
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

    private func dismissPopoverIfNeeded(force: Bool = false) {
        guard popover.isShown else {
            removeEventMonitors()
            return
        }

        if force || !containsMouseLocation(NSEvent.mouseLocation) {
            popover.performClose(nil)
            removeEventMonitors()
        }
    }

    private func containsMouseLocation(_ screenLocation: NSPoint) -> Bool {
        if let buttonFrame = statusItemButtonFrame(), buttonFrame.contains(screenLocation) {
            return true
        }

        if let popoverFrame = popover.contentViewController?.view.window?.frame, popoverFrame.contains(screenLocation) {
            return true
        }

        return false
    }

    private func statusItemButtonFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else {
            return nil
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }
}
