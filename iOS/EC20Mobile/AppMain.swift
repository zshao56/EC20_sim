import SwiftUI
import EC20BridgeProtocol

@main
struct EC20MobileApp: App {
    init() {
        // Initialize call manager and gateway discovery
        _ = MobileCallManager.shared
        _ = MobileNotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            MobileContentView()
        }
    }
}
