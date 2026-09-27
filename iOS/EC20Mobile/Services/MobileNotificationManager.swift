import Foundation
import UserNotifications
import EC20BridgeProtocol

@MainActor
public final class MobileNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = MobileNotificationManager()

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    public func showIncomingSMS(
        message: BridgeMessageDTO,
        contactName: String?,
        badgeCount: Int
    ) {
        let content = UNMutableNotificationContent()
        content.title = contactName ?? message.senderOrRecipient
        content.body = message.text
        content.sound = .default
        content.badge = NSNumber(value: max(0, badgeCount))
        content.threadIdentifier = message.threadId

        let request = UNNotificationRequest(
            identifier: "sms-\(message.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func updateAppBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
