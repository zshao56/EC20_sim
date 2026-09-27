import AppKit
import SwiftUI
import EC20Core

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private weak var controller: EC20Controller?

    public var onOpenMainWindow: (() -> Void)?
    public var onSelectConversation: ((String) -> Void)?

    public override init() {
        super.init()
    }

    public func setup(controller: EC20Controller) {
        self.controller = controller
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "EC20")
            item.button?.imagePosition = .imageLeft
            item.menu = NSMenu()
            item.menu?.delegate = self
            self.statusItem = item
        }
        updateBadge(unreadCount: controller.totalUnreadCount)
    }

    public func updateBadge(unreadCount: Int) {
        guard let button = statusItem?.button else { return }
        if unreadCount > 0 {
            let countText = unreadCount > 99 ? "99+" : "\(unreadCount)"
            button.title = " \(countText)"
            button.image = NSImage(systemSymbolName: "envelope.badge.fill", accessibilityDescription: "EC20 New SMS")
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "EC20")
        }
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = controller else { return }

        // Status header
        let opName = controller.simInfo.operatorName ?? "无运营商"
        let signalBars = "\(controller.simInfo.signal.signalBars)/4 格"
        let statusTitle = "\(opName) (\(signalBars)) - SIM: \(controller.simInfo.cpinStatus.rawValue)"
        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Cellular status
        let netDesc = controller.cellularStatus.isConnected
            ? "蜂窝网络: 已连接 (\(controller.cellularStatus.ipv4Address ?? "IPv6"))"
            : "蜂窝网络: \(controller.cellularStatus.statusDescription)"
        let netItem = NSMenuItem(title: netDesc, action: nil, keyEquivalent: "")
        netItem.isEnabled = false
        menu.addItem(netItem)

        menu.addItem(NSMenuItem.separator())

        // Open Main Window
        let openItem = NSMenuItem(title: "打开 EC20 助理", action: #selector(openMainWindowAction), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        // Unread messages list
        let unreadConvs = controller.conversations.filter { $0.unreadCount > 0 }
        if !unreadConvs.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let unreadHeader = NSMenuItem(title: "未读信息 (\(unreadConvs.count) 个会话):", action: nil, keyEquivalent: "")
            unreadHeader.isEnabled = false
            menu.addItem(unreadHeader)

            for conv in unreadConvs.prefix(5) {
                let title = "• \(conv.title): \(conv.latestMessage.text.prefix(20))..."
                let item = NSMenuItem(title: title, action: #selector(selectThreadAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = conv.threadId
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "退出 EC20 助理", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func openMainWindowAction() {
        onOpenMainWindow?()
    }

    @objc private func selectThreadAction(_ sender: NSMenuItem) {
        if let threadId = sender.representedObject as? String {
            onSelectConversation?(threadId)
        }
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
