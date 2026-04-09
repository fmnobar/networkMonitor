import Foundation
import OSLog

enum NetworkMonitorDiagnostics {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.fmnobar.NetworkMonitor"
    private static let runtimeLogger = Logger(subsystem: subsystem, category: "Runtime")
    private static let captureLogger = Logger(subsystem: subsystem, category: "Capture")
    private static let menuBarLogger = Logger(subsystem: subsystem, category: "MenuBar")
    private static let windowLogger = Logger(subsystem: subsystem, category: "Windowing")
    private static let isVerbose = ProcessInfo.processInfo.environment["NETWORK_MONITOR_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        let rendered = message()
        runtimeLogger.debug("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][debug] \(rendered)")
        }
    }

    static func error(_ message: @autoclosure () -> String) {
        let rendered = message()
        runtimeLogger.error("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][error] \(rendered)")
        }
    }

    static func capture(_ message: @autoclosure () -> String) {
        let rendered = message()
        captureLogger.info("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][capture] \(rendered)")
        }
    }

    static func captureError(_ message: @autoclosure () -> String) {
        let rendered = message()
        captureLogger.error("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][capture][error] \(rendered)")
        }
    }

    static func menuBar(_ message: @autoclosure () -> String) {
        let rendered = message()
        menuBarLogger.info("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][menubar] \(rendered)")
        }
    }

    static func window(_ message: @autoclosure () -> String) {
        let rendered = message()
        windowLogger.info("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][window] \(rendered)")
        }
    }
}
