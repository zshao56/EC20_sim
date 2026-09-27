import Foundation

public enum BridgeMessageType: String, Codable, Sendable {
    // Pairing & Authentication Handshake
    case pairStart = "PAIR_START"
    case pairChallenge = "PAIR_CHALLENGE"
    case pairVerify = "PAIR_VERIFY"
    case resumeVerify = "RESUME_VERIFY"
    case pairAccepted = "PAIR_ACCEPTED"
    case pairResult = "PAIR_RESULT" // Legacy decoder compatibility only.

    // Synchronization
    case syncRequest = "SYNC_REQUEST"
    case syncResponse = "SYNC_RESPONSE"

    // SMS Operations
    case smsSend = "SMS_SEND"
    case smsSendResult = "SMS_SEND_RESULT"
    case smsReceivedEvent = "SMS_RECEIVED_EVENT"

    // Voice Call Operations
    case callDial = "CALL_DIAL"
    case callAnswer = "CALL_ANSWER"
    case callHangup = "CALL_HANGUP"
    case callStateEvent = "CALL_STATE_EVENT"

    // Batch Deletion Operations
    case batchDeleteMessages = "BATCH_DELETE_MESSAGES"
    case batchDeleteThreads = "BATCH_DELETE_THREADS"
    case batchDeleteCalls = "BATCH_DELETE_CALLS"
    case batchDeleteResult = "BATCH_DELETE_RESULT"

    // System Events & Keepalive
    case badgeChangedEvent = "BADGE_CHANGED_EVENT"
    case ping = "PING"
    case pong = "PONG"
    case error = "ERROR"
}

public struct BridgeEnvelope: Codable, Sendable {
    public let version: Int
    public let id: String
    public let type: BridgeMessageType
    public let payload: Data
    public let sequence: UInt64
    public let capabilities: [String]
    public let timestamp: Double

    public init(
        version: Int = 1,
        id: String = UUID().uuidString,
        type: BridgeMessageType,
        payload: Data = Data(),
        sequence: UInt64 = 0,
        capabilities: [String] = ["sms", "call", "sync", "batch", "attribution"],
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.version = version
        self.id = id
        self.type = type
        self.payload = payload
        self.sequence = sequence
        self.capabilities = capabilities
        self.timestamp = timestamp
    }

    /// Stable metadata bound into ChaCha20-Poly1305 authentication. This keeps
    /// an observer from changing a captured packet's request ID or operation
    /// type while reusing its valid ciphertext.
    public var authenticatedMetadata: Data {
        Data("\(version)|\(id)|\(type.rawValue)|\(sequence)".utf8)
    }

    public func replacingPayload(_ newPayload: Data) -> BridgeEnvelope {
        BridgeEnvelope(
            version: version,
            id: id,
            type: type,
            payload: newPayload,
            sequence: sequence,
            capabilities: capabilities,
            timestamp: timestamp
        )
    }
}
