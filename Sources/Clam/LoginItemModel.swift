#if canImport(AppKit)
import AppKit
import Combine
import ServiceManagement

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    // A pending registration remains checked so it can also be cancelled.
    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    var statusText: String {
        switch status {
        case .notRegistered: return "Launch at login is off."
        case .enabled: return "Clam will open at login; keeping awake remains off."
        case .requiresApproval: return "Approve Clam in System Settings > Login Items."
        case .notFound: return "Login item unavailable. Run Clam.app from /Applications."
        @unknown default: return "Login item status is unavailable."
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isRequested else { return }
        defer { refresh() }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
