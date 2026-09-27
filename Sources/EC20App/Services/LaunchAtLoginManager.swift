import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false

    public init() {
        refreshStatus()
    }

    public func refreshStatus() {
        if #available(macOS 13.0, *) {
            self.isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            self.isEnabled = false
        }
    }

    public func setEnabled(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                print("[LaunchAtLogin] Failed to change status: \(error)")
            }
            refreshStatus()
        }
    }
}
