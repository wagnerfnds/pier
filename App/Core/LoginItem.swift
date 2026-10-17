#if targetEnvironment(macCatalyst)
import ServiceManagement
import os

/// Pier opening when the Mac starts (a login item, SMAppService): the Mac app tells the person's iPhone and iPad what
/// needs them (CloudAlerts) and keeps the edge tab, so it is best always running. The onboarding's "Neste Mac" turns it
/// on (the person can say no there); Ajustes → Notificações has the switch, beside the iCloud one.
enum LoginItem {
    static var isOn: Bool { !Shared.isLocalTest && SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard !Shared.isLocalTest else { return false }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            Logger(subsystem: Shared.appBundleID, category: "login-item").error("\(on ? "register" : "unregister"): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
#endif
