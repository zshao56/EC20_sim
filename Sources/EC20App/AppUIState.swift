import SwiftUI
import Combine
import EC20Core

public enum AppTab: String, CaseIterable, Identifiable {
    case phone = "电话"
    case messages = "信息"
    case contacts = "通讯录"
    case cellular = "蜂窝网络"
    case settings = "设置与高级"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .phone: return "phone.fill"
        case .messages: return "message.fill"
        case .contacts: return "person.crop.circle.fill"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
public final class AppUIState: ObservableObject {
    @Published public var selectedTab: AppTab = .phone
    @Published public var useSimulation: Bool = false

    // Call UI State
    @Published public var dialNumber: String = ""
    @Published public var callErrorMessage: String? = nil
    @Published public var isMicMuted: Bool = false
    @Published public var speakerVolume: Double = 1.0

    // SMS UI State
    @Published public var selectedThreadId: String? = nil
    @Published public var inlineReplyText: String = ""
    @Published public var isSendingInlineSMS: Bool = false
    @Published public var inlineSMSError: String? = nil

    // Compose New Message Sheet
    @Published public var isShowingNewMessageSheet: Bool = false
    @Published public var newRecipient: String = ""
    @Published public var newText: String = ""
    @Published public var isSendingNewMessage: Bool = false
    @Published public var newMessageError: String? = nil

    // Contacts UI State
    @Published public var contactSearchText: String = ""
    @Published public var isShowingAddContactSheet: Bool = false
    @Published public var editingContact: Contact? = nil
    @Published public var isImportingContacts: Bool = false
    @Published public var importContactsAlert: String? = nil

    // AT Console State
    @Published public var customCommand: String = ""

    public init() {}

    public func selectThread(_ threadId: String) {
        self.selectedTab = .messages
        self.selectedThreadId = threadId
    }
}
