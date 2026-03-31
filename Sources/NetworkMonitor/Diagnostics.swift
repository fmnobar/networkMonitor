import Foundation
import OSLog

enum NetworkMonitorDiagnostics {
    private static let logger = Logger(subsystem: "com.fmnobar.NetworkMonitor", category: "Runtime")
    private static let isVerbose = ProcessInfo.processInfo.environment["NETWORK_MONITOR_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        let rendered = message()
        logger.debug("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][debug] \(rendered)")
        }
    }

    static func error(_ message: @autoclosure () -> String) {
        let rendered = message()
        logger.error("\(rendered, privacy: .public)")
        if isVerbose {
            print("[NetworkMonitor][error] \(rendered)")
        }
    }
}
