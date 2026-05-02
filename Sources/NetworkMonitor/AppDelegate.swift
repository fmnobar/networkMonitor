import AppKit

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
