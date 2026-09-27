import SwiftUI
import AppKit

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MainWindowDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide window instead of destroying it, keeping background services active
        sender.orderOut(nil)
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar when main window is closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.showMainWindow()
        return true
    }
}

@main
struct EC20CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 920, minHeight: 620)
                .navigationTitle("EC20 蜂窝通信助理")
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
