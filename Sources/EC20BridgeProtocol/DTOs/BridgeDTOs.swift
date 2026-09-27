import Foundation

// MARK: - Conversation DTO

public struct BridgeConversationDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { threadId }
    public let threadId: String
    public let displayRecipient: String
    public let contactName: String?
    public let attribution: String?
    public let latestText: String
    public let latestTimestamp: Double
    public let unreadCount: Int
    public let totalCount: Int

    public init(
        threadId: String,
        displayRecipient: String,
        contactName: String? = nil,
        attribution: String? = nil,
        latestText: String,
        latestTimestamp: Double,
        unreadCount: Int,
        totalCount: Int
    ) {
        self.threadId = threadId
        self.displayRecipient = displayRecipient
        self.contactName = contactName
        self.attribution = attribution
        self.latestText = latestText
        self.latestTimestamp = latestTimestamp
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }
}

// MARK: - Message DTO

public struct BridgeMessageDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let threadId: String
    public let senderOrRecipient: String
    public let text: String
    public let timestamp: Double
    public let isIncoming: Bool
    public let isRead: Bool
    public let sendStatus: String
    public let sendError: String?

    public init(
        id: String,
        threadId: String,
        senderOrRecipient: String,
        text: String,
        timestamp: Double,
        isIncoming: Bool,
        isRead: Bool,
        sendStatus: String,
        sendError: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.senderOrRecipient = senderOrRecipient
        self.text = text
        self.timestamp = timestamp
        self.isIncoming = isIncoming
        self.isRead = isRead
        self.sendStatus = sendStatus
        self.sendError = sendError
    }
}

// MARK: - Contact DTO

public struct BridgeContactDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let phoneNumber: String
    public let attribution: String?
    public let notes: String

    public init(
        id: String,
        name: String,
        phoneNumber: String,
        attribution: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
        self.attribution = attribution
        self.notes = notes
    }
}

// MARK: - Call History DTO

public struct BridgeCallHistoryDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let phoneNumber: String
    public let attribution: String?
    public let contactName: String?
    public let type: String
    public let timestamp: Double?
    public let durationSeconds: Int?

    public init(
        id: String,
        phoneNumber: String,
        attribution: String? = nil,
        contactName: String? = nil,
        type: String,
        timestamp: Double? = nil,
        durationSeconds: Int? = nil
    ) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.attribution = attribution
        self.contactName = contactName
        self.type = type
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
    }
}

// MARK: - Active Call DTO

public struct BridgeActiveCallDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: Int
    public let direction: String // "incoming" or "outgoing"
    public let status: String // "ringing", "active", "dialing", "held", "ended"
    public let phoneNumber: String
    public let contactName: String?
    public let attribution: String?
    public let startedAt: Double

    public init(
        id: Int,
        direction: String,
        status: String,
        phoneNumber: String,
        contactName: String? = nil,
        attribution: String? = nil,
        startedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.direction = direction
        self.status = status
        self.phoneNumber = phoneNumber
        self.contactName = contactName
        self.attribution = attribution
        self.startedAt = startedAt
    }
}

// MARK: - Synchronization DTOs

public struct BridgeSyncRequestDTO: Codable, Sendable, Equatable {
    public let sinceTimestamp: Double?
    public let sinceToken: String?
    public let fullSync: Bool

    public init(sinceTimestamp: Double? = nil, sinceToken: String? = nil, fullSync: Bool = false) {
        self.sinceTimestamp = sinceTimestamp
        self.sinceToken = sinceToken
        self.fullSync = fullSync
    }
}

public struct BridgeSyncResponseDTO: Codable, Sendable, Equatable {
    public let conversations: [BridgeConversationDTO]
    public let recentMessages: [BridgeMessageDTO]
    public let contacts: [BridgeContactDTO]
    public let callHistory: [BridgeCallHistoryDTO]
    public let unreadCount: Int
    public let serverToken: String

    public init(
        conversations: [BridgeConversationDTO],
        recentMessages: [BridgeMessageDTO],
        contacts: [BridgeContactDTO],
        callHistory: [BridgeCallHistoryDTO],
        unreadCount: Int,
        serverToken: String
    ) {
        self.conversations = conversations
        self.recentMessages = recentMessages
        self.contacts = contacts
        self.callHistory = callHistory
        self.unreadCount = unreadCount
        self.serverToken = serverToken
    }
}

// MARK: - Pairing & Handshake DTOs

public struct BridgePairStartDTO: Codable, Sendable, Equatable {
    public let clientDeviceId: String
    public let clientDeviceName: String
    public let clientPublicKeyHex: String

    public init(clientDeviceId: String, clientDeviceName: String, clientPublicKeyHex: String) {
        self.clientDeviceId = clientDeviceId
        self.clientDeviceName = clientDeviceName
        self.clientPublicKeyHex = clientPublicKeyHex
    }
}

public struct BridgePairVerifyDTO: Codable, Sendable, Equatable {
    public let clientDeviceId: String
    public let otpCode: String

    public init(clientDeviceId: String, otpCode: String) {
        self.clientDeviceId = clientDeviceId
        self.otpCode = otpCode
    }
}

/// Public half of the first-time pairing handshake. It contains no secret.
/// The client combines this public key with the secret displayed on the Mac
/// before it can encrypt `BridgePairVerifyDTO`.
public struct BridgePairChallengeDTO: Codable, Sendable, Equatable {
    public let serverDeviceId: String
    public let serverDeviceName: String
    public let serverPublicKeyHex: String
    public let requiresPairingSecret: Bool?
    public let resumeNonce: String?

    public init(
        serverDeviceId: String,
        serverDeviceName: String,
        serverPublicKeyHex: String,
        requiresPairingSecret: Bool = true,
        resumeNonce: String? = nil
    ) {
        self.serverDeviceId = serverDeviceId
        self.serverDeviceName = serverDeviceName
        self.serverPublicKeyHex = serverPublicKeyHex
        self.requiresPairingSecret = requiresPairingSecret
        self.resumeNonce = resumeNonce
    }
}

public struct BridgeResumeVerifyDTO: Codable, Sendable, Equatable {
    public let clientDeviceId: String
    public let challengeNonce: String

    public init(clientDeviceId: String, challengeNonce: String) {
        self.clientDeviceId = clientDeviceId
        self.challengeNonce = challengeNonce
    }
}

public struct BridgePairAcceptedDTO: Codable, Sendable, Equatable {
    public let deviceId: String
    public let acceptedAt: Double

    public init(deviceId: String, acceptedAt: Double = Date().timeIntervalSince1970) {
        self.deviceId = deviceId
        self.acceptedAt = acceptedAt
    }
}

public struct BridgePairResultDTO: Codable, Sendable, Equatable {
    public let success: Bool
    public let serverDeviceId: String
    public let serverDeviceName: String
    public let serverPublicKeyHex: String
    public let errorMessage: String?

    public init(
        success: Bool,
        serverDeviceId: String,
        serverDeviceName: String,
        serverPublicKeyHex: String,
        errorMessage: String? = nil
    ) {
        self.success = success
        self.serverDeviceId = serverDeviceId
        self.serverDeviceName = serverDeviceName
        self.serverPublicKeyHex = serverPublicKeyHex
        self.errorMessage = errorMessage
    }
}

// MARK: - SMS Send DTO

public struct BridgeSMSSendDTO: Codable, Sendable, Equatable {
    public let clientCommandId: String
    public let destination: String
    public let text: String

    public init(clientCommandId: String, destination: String, text: String) {
        self.clientCommandId = clientCommandId
        self.destination = destination
        self.text = text
    }
}

// MARK: - Call Action DTO

public struct BridgeCallActionDTO: Codable, Sendable, Equatable {
    public let action: String // "answer", "hangup", "dial"
    public let number: String?

    public init(action: String, number: String? = nil) {
        self.action = action
        self.number = number
    }
}

// MARK: - Batch Deletion DTOs

public struct BridgeBatchDeleteRequestDTO: Codable, Sendable, Equatable {
    public let clientCommandId: String
    public let targetType: String // "messages", "threads", "calls"
    public let ids: [String]

    public init(clientCommandId: String, targetType: String, ids: [String]) {
        self.clientCommandId = clientCommandId
        self.targetType = targetType
        self.ids = ids
    }
}

public struct BridgeBatchItemResultDTO: Codable, Sendable, Equatable {
    public let id: String
    public let success: Bool
    public let reason: String?

    public init(id: String, success: Bool, reason: String? = nil) {
        self.id = id
        self.success = success
        self.reason = reason
    }
}

public struct BridgeBatchDeleteResultDTO: Codable, Sendable, Equatable {
    public let clientCommandId: String
    public let totalRequested: Int
    public let succeededCount: Int
    public let failedCount: Int
    public let items: [BridgeBatchItemResultDTO]

    public var isFullSuccess: Bool { failedCount == 0 }

    public init(
        clientCommandId: String,
        totalRequested: Int,
        succeededCount: Int,
        failedCount: Int,
        items: [BridgeBatchItemResultDTO]
    ) {
        self.clientCommandId = clientCommandId
        self.totalRequested = totalRequested
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.items = items
    }
}

// MARK: - Event DTOs

public struct BridgeCallStateEventDTO: Codable, Sendable, Equatable {
    public let activeCall: BridgeActiveCallDTO?
    public let endedReason: String?

    public init(activeCall: BridgeActiveCallDTO?, endedReason: String? = nil) {
        self.activeCall = activeCall
        self.endedReason = endedReason
    }
}

public struct BridgeBadgeChangedEventDTO: Codable, Sendable, Equatable {
    public let totalUnreadCount: Int

    public init(totalUnreadCount: Int) {
        self.totalUnreadCount = totalUnreadCount
    }
}

public struct BridgeErrorDTO: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}
