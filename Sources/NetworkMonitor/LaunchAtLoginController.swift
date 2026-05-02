import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isToggleOn: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        }
    }

    var message: String? {
        switch self {
        case .requiresApproval:
            return "Needs approval in System Settings."
        case .notFound:
            return "Launch at login is unavailable for this build."
        case .enabled, .notRegistered:
            return nil
        }
    }

    init(serviceStatus: SMAppService.Status) {
        switch serviceStatus {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        case .notRegistered:
            self = .notRegistered
        @unknown default:
            self = .notFound
        }
    }
}

protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

final class MainAppLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus {
        LaunchAtLoginStatus(serviceStatus: SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let preferences: NetworkMonitorPreferences
    private let service: any LaunchAtLoginServicing

    init(
        preferences: NetworkMonitorPreferences,
        service: any LaunchAtLoginServicing = MainAppLaunchAtLoginService()
    ) {
        self.preferences = preferences
        self.service = service
        self.status = service.status
        synchronizeWithSystem()
    }

    var isEnabled: Bool {
        status.isToggleOn
    }

    var statusMessage: String? {
        errorMessage ?? status.message
    }

    func synchronizeWithSystem() {
        errorMessage = nil
        updateStatus(service.status)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        isUpdating = true
        defer { isUpdating = false }

        if enabled {
            enable()
        } else {
            disable()
        }
    }

    private func enable() {
        let currentStatus = service.status
        updateStatus(currentStatus)

        switch currentStatus {
        case .enabled, .requiresApproval:
            return
        case .notFound:
            preferences.launchAtLoginEnabled = false
            return
        case .notRegistered:
            break
        }

        do {
            try service.register()
            updateStatus(service.status)
        } catch {
            updateStatus(service.status)
            preferences.launchAtLoginEnabled = false
            errorMessage = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    private func disable() {
        let currentStatus = service.status
        updateStatus(currentStatus)

        switch currentStatus {
        case .notRegistered, .notFound:
            preferences.launchAtLoginEnabled = false
            return
        case .enabled, .requiresApproval:
            break
        }

        do {
            try service.unregister()
            updateStatus(service.status)
        } catch {
            updateStatus(service.status)
            errorMessage = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    private func updateStatus(_ newStatus: LaunchAtLoginStatus) {
        status = newStatus
        preferences.launchAtLoginEnabled = newStatus.isToggleOn
    }
}
