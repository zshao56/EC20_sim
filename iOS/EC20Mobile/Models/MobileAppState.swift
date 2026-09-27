import Foundation
import Combine
import EC20BridgeProtocol

@MainActor
public final class MobileAppState: ObservableObject {
    public static let shared = MobileAppState()

    // Connection & Pairing State
    @Published public var isConnected: Bool = false
    @Published public var isPaired: Bool = false
    @Published public var statusMessage: String = "未连接到 Mac 网关"
    @Published public var discoveredGateways: [String] = []

    // Synced Data
    @Published public var conversations: [BridgeConversationDTO] = []
    @Published public var messages: [BridgeMessageDTO] = []
    @Published public var contacts: [BridgeContactDTO] = []
    @Published public var callHistory: [BridgeCallHistoryDTO] = []
    @Published public var totalUnreadCount: Int = 0

    // Active Call State
    @Published public var activeCall: BridgeActiveCallDTO? = nil

    // Sync Token
    public var lastSyncToken: String? = nil

    public init() {}

    public func messages(for threadId: String) -> [BridgeMessageDTO] {
        messages.filter { $0.threadId == threadId }.sorted { $0.timestamp < $1.timestamp }
    }

    public func findContact(for phoneNumber: String) -> BridgeContactDTO? {
        let clean = phoneNumber.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        return contacts.first { c in
            let cClean = c.phoneNumber.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            return cClean == clean || cClean.hasSuffix(clean) || clean.hasSuffix(cClean)
        }
    }
}
