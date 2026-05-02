import AppKit
import SwiftUI

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
