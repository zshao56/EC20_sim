import Foundation
@preconcurrency import UserNotifications
import AppKit
import EC20Core

@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, ObservableObject {
    public static let shared = NotificationManager()

    public var onSelectThread: ((String) -> Void)?
    public var onDirectReply: ((_ threadId: String, _ recipient: String, _ text: String) async -> Void)?

    private override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        setupCategories()
    }

    public func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[Notification] Authorization error: \(error)")
            }
        }
    }

    private func setupCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: "ACTION_REPLY",
            title: "回复",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "输入短信内容..."
        )
        let viewAction = UNNotificationAction(
            identifier: "ACTION_VIEW",
            title: "查看会话",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: "SMS_MESSAGE",
            actions: [replyAction, viewAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    public func sendSMSNotification(message: SMSMessage, contactName: String?) {
        let content = UNMutableNotificationContent()
        let senderTitle = contactName != nil && !contactName!.isEmpty ? "\(contactName!) (\(message.senderOrRecipient))" : message.senderOrRecipient
        content.title = "新短信: \(senderTitle)"
        content.body = message.text
        content.sound = .default
        content.categoryIdentifier = "SMS_MESSAGE"
        content.userInfo = [
            "threadId": message.threadId,
            "recipient": message.senderOrRecipient,
            "messageId": message.id.uuidString
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: "sms-\(message.id.uuidString)", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Notification] Failed to add notification: \(error)")
            }
        }
    }

    public func updateBadgeCount(_ count: Int) {
        if count > 0 {
            NSApplication.shared.dockTile.badgeLabel = count > 99 ? "99+" : "\(count)"
        } else {
            NSApplication.shared.dockTile.badgeLabel = nil
        }
    }

    public func clearNotifications(for threadId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let idsToRemove = notifications.compactMap { notif -> String? in
                if (notif.request.content.userInfo["threadId"] as? String) == threadId {
                    return notif.request.identifier
                }
                return nil
            }
            if !idsToRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Foreground alert presentation
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let threadId = userInfo["threadId"] as? String,
              let recipient = userInfo["recipient"] as? String else {
            completionHandler()
            return
        }

        Task { @MainActor in
            if let textResponse = response as? UNTextInputNotificationResponse {
                let replyText = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !replyText.isEmpty {
                    await self.onDirectReply?(threadId, recipient, replyText)
                }
            } else {
                self.onSelectThread?(threadId)
            }
            completionHandler()
        }
    }
}
