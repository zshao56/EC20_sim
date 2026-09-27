import Foundation
import Network
import Combine
import EC20BridgeProtocol

public enum GatewayStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(port: UInt16)
    case error(message: String)

    public var displayDescription: String {
        switch self {
        case .stopped:
            return "网关已停止 (局域网互联未开启)"
        case .starting:
            return "正在启动网络监听..."
        case .running(let port):
            return "运行中 (端口: \(port), Bonjour: _ec20companion._tcp)"
        case .error(let msg):
            return "网关异常: \(msg)"
        }
    }
}

@MainActor
public final class EC20GatewayServer: ObservableObject {
    public static let shared = EC20GatewayServer()

    @Published public private(set) var status: GatewayStatus = .stopped
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var connectedClientsCount: Int = 0
    @Published public private(set) var pairedDevices: [PairedDevice] = []
    @Published public private(set) var currentOTP: String? = nil
    @Published public private(set) var otpSecondsRemaining: Int = 0

    private var listener: NWListener?
    private var connections: [UUID: GatewayClientSession] = [:]
    public let pairingManager: GatewayPairingManager

    public weak var controller: EC20Controller?
    private var cancellables = Set<AnyCancellable>()
    private var otpTimer: Timer?

    public init(pairingManager: GatewayPairingManager = GatewayPairingManager()) {
        self.pairingManager = pairingManager
        self.pairedDevices = pairingManager.listPairedDevices()
    }

    public func configure(with controller: EC20Controller) {
        cancellables.removeAll()
        self.controller = controller
        setupControllerHooks()
    }

    // MARK: - Server Lifecycle

    public func start() {
        guard !isRunning else { return }
        self.status = .starting

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10

            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.includePeerToPeer = true

            let newListener = try NWListener(using: params)
            newListener.service = NWListener.Service(
                name: "EC20-Mac-Gateway",
                type: "_ec20companion._tcp",
                domain: "local.",
                txtRecord: Data("v=1\0caps=sms,call,sync,batch,attribution".utf8)
            )

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            newListener.start(queue: .main)
            self.listener = newListener
            self.isRunning = true
            startOTPTimer()
        } catch {
            self.status = .error(message: "监听端口初始化失败: \(error.localizedDescription)")
            self.isRunning = false
        }
    }

    public func stop() {
        guard isRunning else { return }
        stopOTPTimer()

        for session in connections.values {
            session.cancel()
        }
        connections.removeAll()
        connectedClientsCount = 0

        listener?.cancel()
        listener = nil
        isRunning = false
        status = .stopped
    }

    public func generateNewOTP() -> String {
        let code = pairingManager.generateNewOTP()
        self.currentOTP = code
        self.otpSecondsRemaining = pairingManager.otpSecondsRemaining
        return code
    }

    public func revokeDevice(deviceId: String) {
        pairingManager.revokeDevice(deviceId: deviceId)
        self.pairedDevices = pairingManager.listPairedDevices()
        for (id, session) in connections where session.deviceId == deviceId {
            session.cancel()
            connections.removeValue(forKey: id)
        }
        self.connectedClientsCount = connections.count
    }

    fileprivate func refreshPairedDevices() {
        pairedDevices = pairingManager.listPairedDevices()
    }

    // MARK: - Controller Event Hooks

    private func setupControllerHooks() {
        guard let ctrl = controller else { return }

        // Unread Badge Count
        ctrl.$totalUnreadCount
            .sink { [weak self] count in
                self?.broadcastBadgeChanged(unreadCount: count)
            }
            .store(in: &cancellables)

        // Observe call state instead of replacing the app coordinator's incoming
        // call callback. Replacing it would disable the native Mac call popup.
        ctrl.$activeCalls
            .sink { [weak self, weak ctrl] calls in
                guard let self, let ctrl else { return }
                self.broadcastCallState(calls.first, controller: ctrl)
            }
            .store(in: &cancellables)
    }

    public func broadcastSMSReceived(_ msg: SMSMessage) {
        let dto = BridgeMessageDTO(
            id: msg.id.uuidString,
            threadId: msg.threadId,
            senderOrRecipient: msg.senderOrRecipient,
            text: msg.text,
            timestamp: msg.timestamp.timeIntervalSince1970,
            isIncoming: msg.isIncoming,
            isRead: msg.isRead,
            sendStatus: msg.sendStatus.rawValue,
            sendError: msg.sendError
        )
        guard let payload = try? JSONEncoder().encode(dto) else { return }
        let envelope = BridgeEnvelope(type: .smsReceivedEvent, payload: payload)
        broadcastEnvelope(envelope)
    }

    private func broadcastCallState(_ call: CallRecord?, controller: EC20Controller) {
        let activeCall = call.map { call in
            BridgeActiveCallDTO(
                id: call.id,
                direction: call.direction.rawValue.lowercased(),
                status: call.status.rawValue.lowercased(),
                phoneNumber: call.phoneNumber,
                contactName: controller.database.findContact(forPhone: call.phoneNumber)?.name,
                attribution: PhoneAttributionLookup.shared.lookup(call.phoneNumber).displayString
            )
        }
        let event = BridgeCallStateEventDTO(
            activeCall: activeCall,
            endedReason: activeCall == nil ? "ended" : nil
        )
        guard let payload = try? JSONEncoder().encode(event) else { return }
        let envelope = BridgeEnvelope(type: .callStateEvent, payload: payload)
        broadcastEnvelope(envelope)
    }

    private func broadcastBadgeChanged(unreadCount: Int) {
        let dto = BridgeBadgeChangedEventDTO(totalUnreadCount: unreadCount)
        guard let payload = try? JSONEncoder().encode(dto) else { return }
        let envelope = BridgeEnvelope(type: .badgeChangedEvent, payload: payload)
        broadcastEnvelope(envelope)
    }

    fileprivate func broadcastCurrentState() {
        guard let controller else { return }
        broadcastCallState(controller.activeCalls.first, controller: controller)
        broadcastBadgeChanged(unreadCount: controller.totalUnreadCount)
    }

    public func broadcastEnvelope(_ envelope: BridgeEnvelope) {
        for session in connections.values where session.isAuthenticated {
            session.sendEncryptedEvent(envelope)
        }
    }

    // MARK: - Connection Management

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                self.status = .running(port: port)
            } else {
                self.status = .running(port: 0)
            }
        case .failed(let err):
            self.status = .error(message: err.localizedDescription)
            self.isRunning = false
        case .cancelled:
            self.status = .stopped
            self.isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ nwConn: NWConnection) {
        let sessionId = UUID()
        let session = GatewayClientSession(
            id: sessionId,
            connection: nwConn,
            server: self
        )
        connections[sessionId] = session
        connectedClientsCount = connections.count
        session.start()
    }

    func sessionDisconnected(id: UUID) {
        connections.removeValue(forKey: id)
        connectedClientsCount = connections.count
    }

    private func startOTPTimer() {
        otpTimer?.invalidate()
        otpTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentOTP = self.pairingManager.currentOTP
                self.otpSecondsRemaining = self.pairingManager.otpSecondsRemaining
            }
        }
    }

    private func stopOTPTimer() {
        otpTimer?.invalidate()
        otpTimer = nil
    }
}

// MARK: - Client Session Handler

@MainActor
final class GatewayClientSession {
    let id: UUID
    let connection: NWConnection
    weak var server: EC20GatewayServer?

    var isPaired: Bool = false
    var isAuthenticated: Bool = false
    var deviceId: String? = nil

    private let cryptoSession: CryptoKitSession
    private var incomingBuffer = Data()
    private var pendingPairStart: BridgePairStartDTO?
    private var pendingResumeNonce: String?
    private var processedRequestIds: Set<String> = []
    private var processedRequestOrder: [String] = []

    init(id: UUID, connection: NWConnection, server: EC20GatewayServer) {
        self.id = id
        self.connection = connection
        self.server = server
        self.cryptoSession = server.pairingManager.makeServerCryptoSession()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }
        connection.start(queue: .main)
        receiveNextPacket()
    }

    func cancel() {
        connection.cancel()
    }

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            break
        case .failed, .cancelled:
            server?.sessionDisconnected(id: id)
        default:
            break
        }
    }

    private func receiveNextPacket() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.incomingBuffer.append(data)
                    self.processIncomingBuffer()
                }
                if isComplete || error != nil {
                    self.server?.sessionDisconnected(id: self.id)
                } else {
                    self.receiveNextPacket()
                }
            }
        }
    }

    private func processIncomingBuffer() {
        while true {
            do {
                guard let frame = try BridgeFraming.decode(from: &incomingBuffer) else {
                    break
                }
                handleReceivedFrame(frame)
            } catch {
                sendError(code: -1, message: "数据帧解析失败: \(error.localizedDescription)")
                break
            }
        }
    }

    private func handleReceivedFrame(_ frame: Data) {
        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: frame) else {
            sendError(code: -2, message: "信封结构解析失败")
            return
        }

        // Only public-key discovery is accepted before encryption. The pairing
        // secret itself is never sent in a plaintext envelope.
        switch envelope.type {
        case .pairStart:
            guard !isAuthenticated else {
                sendError(code: -409, message: "当前会话已经通过认证")
                return
            }
            handlePairStart(envelope)
            return
        case .pairVerify:
            guard !isAuthenticated else {
                sendError(code: -409, message: "当前会话已经通过认证")
                return
            }
            handlePairVerify(envelope)
            return
        case .resumeVerify:
            guard !isAuthenticated else {
                sendError(code: -409, message: "当前会话已经通过认证")
                return
            }
            handleResumeVerify(envelope)
            return
        case .ping:
            let pong = BridgeEnvelope(type: .pong, payload: Data("PONG".utf8))
            sendEnvelope(pong)
            return
        default:
            break
        }

        // Encrypted Operations Require Established Session
        guard cryptoSession.isEstablished else {
            sendError(code: -401, message: "会话尚未通过安全密钥协商")
            return
        }

        guard isAuthenticated else {
            sendError(code: -402, message: "设备尚未完成配对认证")
            return
        }

        let decryptedPayload: Data
        do {
            decryptedPayload = try cryptoSession.open(
                envelope.payload,
                authenticating: envelope.authenticatedMetadata
            )
        } catch {
            sendError(code: -403, message: "数据包解密/防篡改鉴权失败: \(error.localizedDescription)")
            return
        }

        guard registerRequestId(envelope.id) else {
            sendError(code: -409, message: "已拒绝重复请求")
            return
        }

        dispatchAuthenticatedRequest(type: envelope.type, payload: decryptedPayload, requestId: envelope.id)
    }

    private func registerRequestId(_ requestId: String) -> Bool {
        guard !processedRequestIds.contains(requestId) else { return false }
        processedRequestIds.insert(requestId)
        processedRequestOrder.append(requestId)
        if processedRequestOrder.count > 1024 {
            let expired = processedRequestOrder.removeFirst()
            processedRequestIds.remove(expired)
        }
        return true
    }

    private func handlePairStart(_ envelope: BridgeEnvelope) {
        guard let startDTO = try? JSONDecoder().decode(BridgePairStartDTO.self, from: envelope.payload) else {
            sendError(code: -3, message: "配对起始数据无效")
            return
        }

        guard let server else { return }

        self.deviceId = startDTO.clientDeviceId
        self.pendingPairStart = startDTO
        self.pendingResumeNonce = nil

        do {
            let pairedDevice = server.pairingManager.getDevice(deviceId: startDTO.clientDeviceId)
            let canResume = pairedDevice?.publicKeyHex.caseInsensitiveCompare(
                startDTO.clientPublicKeyHex
            ) == .orderedSame

            let challenge: BridgePairChallengeDTO
            if canResume {
                let nonce = UUID().uuidString + UUID().uuidString
                pendingResumeNonce = nonce
                try cryptoSession.establishSharedKey(
                    peerPublicKeyHex: startDTO.clientPublicKeyHex,
                    pairingSecret: nonce
                )
                challenge = BridgePairChallengeDTO(
                    serverDeviceId: "mac-gateway-\(Host.current().localizedName ?? "gateway")",
                    serverDeviceName: Host.current().localizedName ?? "Mac",
                    serverPublicKeyHex: cryptoSession.localPublicKeyHex,
                    requiresPairingSecret: false,
                    resumeNonce: nonce
                )
            } else {
                guard let pairingSecret = server.pairingManager.currentOTP else {
                    sendError(code: -6, message: "设备尚未配对，Mac 端没有有效配对密钥，请重新生成")
                    return
                }
                try cryptoSession.establishSharedKey(
                    peerPublicKeyHex: startDTO.clientPublicKeyHex,
                    pairingSecret: pairingSecret
                )
                challenge = BridgePairChallengeDTO(
                    serverDeviceId: "mac-gateway-\(Host.current().localizedName ?? "gateway")",
                    serverDeviceName: Host.current().localizedName ?? "Mac",
                    serverPublicKeyHex: cryptoSession.localPublicKeyHex,
                    requiresPairingSecret: true
                )
            }
            let payload = try JSONEncoder().encode(challenge)
            let reply = BridgeEnvelope(type: .pairChallenge, payload: payload)
            sendEnvelope(reply)
        } catch {
            sendError(code: -4, message: "ECDH 密钥协商失败: \(error.localizedDescription)")
        }
    }

    private func handleResumeVerify(_ envelope: BridgeEnvelope) {
        guard let server,
              let pending = pendingPairStart,
              let expectedNonce = pendingResumeNonce,
              cryptoSession.isEstablished else {
            sendError(code: -5, message: "会话恢复参数无效")
            return
        }

        let plaintext: Data
        do {
            plaintext = try cryptoSession.open(
                envelope.payload,
                authenticating: envelope.authenticatedMetadata
            )
        } catch {
            sendError(code: -401, message: "已配对设备身份验证失败")
            return
        }

        guard let verify = try? JSONDecoder().decode(BridgeResumeVerifyDTO.self, from: plaintext),
              verify.clientDeviceId == pending.clientDeviceId,
              verify.challengeNonce == expectedNonce,
              let paired = server.pairingManager.getDevice(deviceId: verify.clientDeviceId),
              paired.publicKeyHex.caseInsensitiveCompare(pending.clientPublicKeyHex) == .orderedSame else {
            sendError(code: -401, message: "已配对设备身份验证失败")
            return
        }

        isAuthenticated = true
        isPaired = true
        pendingPairStart = nil
        pendingResumeNonce = nil
        let accepted = BridgePairAcceptedDTO(deviceId: verify.clientDeviceId)
        sendEncryptedResponse(accepted, type: .pairAccepted, requestId: envelope.id)
        server.broadcastCurrentState()
    }

    private func handlePairVerify(_ envelope: BridgeEnvelope) {
        guard let server, let pending = pendingPairStart, cryptoSession.isEstablished else {
            sendError(code: -5, message: "配对验证参数无效")
            return
        }

        let plaintext: Data
        do {
            plaintext = try cryptoSession.open(
                envelope.payload,
                authenticating: envelope.authenticatedMetadata
            )
        } catch {
            let failure = server.pairingManager.registerFailedAttempt()
            sendError(code: -401, message: failure.localizedDescription)
            return
        }

        guard let verifyDTO = try? JSONDecoder().decode(BridgePairVerifyDTO.self, from: plaintext),
              verifyDTO.clientDeviceId == pending.clientDeviceId else {
            let failure = server.pairingManager.registerFailedAttempt()
            sendError(code: -5, message: failure.localizedDescription)
            return
        }

        let verifyRes = server.pairingManager.verifyOTP(
            code: verifyDTO.otpCode,
            clientDeviceId: verifyDTO.clientDeviceId,
            clientName: pending.clientDeviceName,
            clientPublicKeyHex: pending.clientPublicKeyHex
        )

        switch verifyRes {
        case .success:
            self.isAuthenticated = true
            self.isPaired = true
            self.pendingPairStart = nil
            self.pendingResumeNonce = nil
            let accepted = BridgePairAcceptedDTO(deviceId: verifyDTO.clientDeviceId)
            sendEncryptedResponse(accepted, type: .pairAccepted, requestId: envelope.id)
            server.refreshPairedDevices()
            server.broadcastCurrentState()
        case .failure(let err):
            sendError(code: -401, message: err.localizedDescription)
        }
    }

    private func dispatchAuthenticatedRequest(type: BridgeMessageType, payload: Data, requestId: String) {
        guard let ctrl = server?.controller else {
            sendError(code: -500, message: "EC20 控制器未就绪")
            return
        }

        switch type {
        case .syncRequest:
            handleSyncRequest(payload: payload, requestId: requestId, ctrl: ctrl)
        case .smsSend:
            handleSMSSend(payload: payload, requestId: requestId, ctrl: ctrl)
        case .callAnswer:
            Task { try? await ctrl.answerCall() }
        case .callHangup:
            Task { try? await ctrl.hangupCall() }
        case .callDial:
            if let action = try? JSONDecoder().decode(BridgeCallActionDTO.self, from: payload), let num = action.number {
                Task { try? await ctrl.dial(number: num) }
            }
        case .batchDeleteMessages:
            handleBatchDeleteMessages(payload: payload, requestId: requestId, ctrl: ctrl)
        case .batchDeleteThreads:
            handleBatchDeleteThreads(payload: payload, requestId: requestId, ctrl: ctrl)
        case .batchDeleteCalls:
            handleBatchDeleteCalls(payload: payload, requestId: requestId, ctrl: ctrl)
        default:
            break
        }
    }

    private func handleSyncRequest(payload: Data, requestId: String, ctrl: EC20Controller) {
        let db = ctrl.database
        let convs = db.fetchConversations().map { c -> BridgeConversationDTO in
            let attr = PhoneAttributionLookup.shared.lookup(c.displayRecipient).displayString
            return BridgeConversationDTO(
                threadId: c.threadId,
                displayRecipient: c.displayRecipient,
                contactName: c.contactName,
                attribution: attr,
                latestText: c.latestMessage.text,
                latestTimestamp: c.latestMessage.timestamp.timeIntervalSince1970,
                unreadCount: c.unreadCount,
                totalCount: c.totalCount
            )
        }

        let msgs = db.fetchAllMessages().prefix(100).map { m -> BridgeMessageDTO in
            BridgeMessageDTO(
                id: m.id.uuidString,
                threadId: m.threadId,
                senderOrRecipient: m.senderOrRecipient,
                text: m.text,
                timestamp: m.timestamp.timeIntervalSince1970,
                isIncoming: m.isIncoming,
                isRead: m.isRead,
                sendStatus: m.sendStatus.rawValue,
                sendError: m.sendError
            )
        }

        let contacts = db.fetchContacts().map { ct -> BridgeContactDTO in
            let attr = PhoneAttributionLookup.shared.lookup(ct.phoneNumber).displayString
            return BridgeContactDTO(
                id: ct.id.uuidString,
                name: ct.name,
                phoneNumber: ct.phoneNumber,
                attribution: attr,
                notes: ct.notes
            )
        }

        let calls = db.fetchCallHistory(limit: 50).map { cl -> BridgeCallHistoryDTO in
            let attr = PhoneAttributionLookup.shared.lookup(cl.phoneNumber).displayString
            return BridgeCallHistoryDTO(
                id: cl.id.uuidString,
                phoneNumber: cl.phoneNumber,
                attribution: attr,
                contactName: cl.contactName,
                type: cl.type.rawValue,
                timestamp: cl.timestamp?.timeIntervalSince1970,
                durationSeconds: cl.durationSeconds
            )
        }

        let syncResp = BridgeSyncResponseDTO(
            conversations: convs,
            recentMessages: Array(msgs),
            contacts: contacts,
            callHistory: calls,
            unreadCount: ctrl.totalUnreadCount,
            serverToken: String(Date().timeIntervalSince1970)
        )

        sendEncryptedResponse(syncResp, type: .syncResponse, requestId: requestId)
    }

    private func handleSMSSend(payload: Data, requestId: String, ctrl: EC20Controller) {
        guard let sendDTO = try? JSONDecoder().decode(BridgeSMSSendDTO.self, from: payload) else {
            sendError(code: -10, message: "短信发送参数异常")
            return
        }

        Task {
            do {
                try await ctrl.sendSMSIdempotently(
                    to: sendDTO.destination,
                    text: sendDTO.text,
                    clientCommandId: sendDTO.clientCommandId
                )
                let res = BridgeBatchItemResultDTO(id: sendDTO.clientCommandId, success: true, reason: nil)
                self.sendEncryptedResponse(res, type: .smsSendResult, requestId: requestId)
            } catch {
                let res = BridgeBatchItemResultDTO(id: sendDTO.clientCommandId, success: false, reason: error.localizedDescription)
                self.sendEncryptedResponse(res, type: .smsSendResult, requestId: requestId)
            }
        }
    }

    private func handleBatchDeleteMessages(payload: Data, requestId: String, ctrl: EC20Controller) {
        guard let req = try? JSONDecoder().decode(BridgeBatchDeleteRequestDTO.self, from: payload) else { return }
        let uuids = req.ids.compactMap { UUID(uuidString: $0) }
        Task {
            let res = await ctrl.deleteSMSBatch(ids: uuids, clientCommandId: req.clientCommandId)
            self.sendEncryptedResponse(res, type: .batchDeleteResult, requestId: requestId)
        }
    }

    private func handleBatchDeleteThreads(payload: Data, requestId: String, ctrl: EC20Controller) {
        guard let req = try? JSONDecoder().decode(BridgeBatchDeleteRequestDTO.self, from: payload) else { return }
        Task {
            let res = await ctrl.deleteThreadsBatch(threadIds: req.ids, clientCommandId: req.clientCommandId)
            self.sendEncryptedResponse(res, type: .batchDeleteResult, requestId: requestId)
        }
    }

    private func handleBatchDeleteCalls(payload: Data, requestId: String, ctrl: EC20Controller) {
        guard let req = try? JSONDecoder().decode(BridgeBatchDeleteRequestDTO.self, from: payload) else { return }
        let uuids = req.ids.compactMap { UUID(uuidString: $0) }
        let res = ctrl.deleteCallHistoryBatch(ids: uuids, clientCommandId: req.clientCommandId)
        sendEncryptedResponse(res, type: .batchDeleteResult, requestId: requestId)
    }

    private func sendEncryptedResponse<T: Encodable>(_ dataObj: T, type: BridgeMessageType, requestId: String) {
        let metadata = BridgeEnvelope(id: requestId, type: type)
        guard let rawJSON = try? JSONEncoder().encode(dataObj),
              let ciphertext = try? cryptoSession.seal(
                rawJSON,
                authenticating: metadata.authenticatedMetadata
              ) else {
            return
        }
        sendEnvelope(metadata.replacingPayload(ciphertext))
    }

    func sendEncryptedEvent(_ envelope: BridgeEnvelope) {
        guard isAuthenticated,
              let ciphertext = try? cryptoSession.seal(
                envelope.payload,
                authenticating: envelope.authenticatedMetadata
              ) else {
            return
        }
        sendEnvelope(envelope.replacingPayload(ciphertext))
    }

    func sendEnvelope(_ envelope: BridgeEnvelope) {
        guard let envData = try? JSONEncoder().encode(envelope) else { return }
        let frame = BridgeFraming.encode(envData)
        connection.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private func sendError(code: Int, message: String) {
        let errDTO = BridgeErrorDTO(code: code, message: message)
        guard let pl = try? JSONEncoder().encode(errDTO) else { return }
        let env = BridgeEnvelope(type: .error, payload: pl)
        sendEnvelope(env)
    }
}
