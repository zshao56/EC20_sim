import Foundation
import Network
import Combine
import EC20BridgeProtocol

@MainActor
public final class MobileGatewayClient: ObservableObject {
    public static let shared = MobileGatewayClient()

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let cryptoSession: CryptoKitSession
    private var incomingBuffer = Data()
    private var pendingServerPublicKeyHex: String?
    private var lastReportedIncomingNumber: String?
    private var reconnectTask: Task<Void, Never>?
    private var lastEndpoint: NWEndpoint?
    private var trustedServerPublicKeyHex: String?
    private var processedIncomingIds: Set<String> = []
    private var processedIncomingOrder: [String] = []

    @Published public private(set) var isSendingSMS: Bool = false
    @Published public private(set) var lastSMSSendError: String?

    public let appState = MobileAppState.shared

    private let deviceId: String
    private let keychain: KeychainStorageProtocol

    public init(keychain: KeychainStorageProtocol = SystemKeychainStorage()) {
        self.keychain = keychain
        if let storedData = (try? keychain.read(key: "ec20.mobile.deviceId")) ?? nil,
           let storedId = String(data: storedData, encoding: .utf8) {
            self.deviceId = storedId
        } else {
            let newId = "ios-client-" + String(UUID().uuidString.prefix(8))
            try? keychain.save(key: "ec20.mobile.deviceId", data: Data(newId.utf8))
            self.deviceId = newId
        }

        if let storedKey = (try? keychain.read(key: "ec20.mobile.privateKey")) ?? nil,
           let restoredSession = try? CryptoKitSession(privateKeyRawRepresentation: storedKey) {
            self.cryptoSession = restoredSession
        } else {
            let newSession = CryptoKitSession()
            try? keychain.save(
                key: "ec20.mobile.privateKey",
                data: newSession.localPrivateKeyRawRepresentation
            )
            self.cryptoSession = newSession
        }

        if let trustedKeyData = (try? keychain.read(key: "ec20.mobile.serverPublicKey")) ?? nil {
            self.trustedServerPublicKeyHex = String(data: trustedKeyData, encoding: .utf8)
        }
    }

    // MARK: - Bonjour Discovery

    public func startDiscovery() {
        stopDiscovery()
        appState.statusMessage = "正在局域网搜索 Mac EC20 网关..."

        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_ec20companion._tcp", domain: "local."), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                guard let self = self else { return }
                self.appState.discoveredGateways = results.compactMap { res in
                    if case .service(let name, _, _, _) = res.endpoint {
                        return name
                    }
                    return nil
                }
                if let first = results.first {
                    self.connect(to: first.endpoint)
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        lastEndpoint = nil
        connection?.cancel()
        connection = nil
        stopDiscovery()
        appState.isConnected = false
        appState.isPaired = false
        isSendingSMS = false
        appState.statusMessage = "已断开与 Mac 网关的连接"
    }

    // MARK: - Connection

    public func connect(to endpoint: NWEndpoint) {
        reconnectTask?.cancel()
        lastEndpoint = endpoint
        connection?.cancel()
        appState.statusMessage = "正在连接到网关..."

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        conn.start(queue: .main)
        self.connection = conn
        receivePackets()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            reconnectTask?.cancel()
            appState.isConnected = true
            appState.statusMessage = "局域网已连接，正在协商安全信道..."
            startKeyExchange()
        case .failed(let err):
            appState.isConnected = false
            MobileCallManager.shared.reportCallEnded()
            appState.activeCall = nil
            isSendingSMS = false
            appState.statusMessage = "连接失败: \(err.localizedDescription)"
            scheduleReconnect()
        case .cancelled:
            appState.isConnected = false
            MobileCallManager.shared.reportCallEnded()
            appState.activeCall = nil
            isSendingSMS = false
            appState.statusMessage = "连接已断开"
            scheduleReconnect()
        default:
            break
        }
    }

    // MARK: - Handshake & Pairing

    private func startKeyExchange() {
        let pairStart = BridgePairStartDTO(
            clientDeviceId: deviceId,
            clientDeviceName: "iPhone",
            clientPublicKeyHex: cryptoSession.localPublicKeyHex
        )
        guard let payload = try? JSONEncoder().encode(pairStart) else { return }
        let envelope = BridgeEnvelope(type: .pairStart, payload: payload)
        sendEnvelope(envelope)
    }

    public func submitPairingOTP(_ otp: String) {
        let secret = GatewayPairingManager.normalizeSecret(otp)
        guard let serverPublicKeyHex = pendingServerPublicKeyHex else {
            appState.statusMessage = "尚未收到 Mac 的安全配对质询"
            return
        }

        do {
            try cryptoSession.establishSharedKey(
                peerPublicKeyHex: serverPublicKeyHex,
                pairingSecret: secret
            )
        } catch {
            appState.statusMessage = "安全密钥协商失败"
            return
        }

        let verifyDTO = BridgePairVerifyDTO(
            clientDeviceId: deviceId,
            otpCode: secret
        )
        let metadata = BridgeEnvelope(type: .pairVerify)
        guard let payload = try? JSONEncoder().encode(verifyDTO),
              let ciphertext = try? cryptoSession.seal(
                payload,
                authenticating: metadata.authenticatedMetadata
              ) else { return }
        sendEnvelope(metadata.replacingPayload(ciphertext))
    }

    // MARK: - Packet Handling

    private func receivePackets() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let data = data, !data.isEmpty {
                    self.incomingBuffer.append(data)
                    self.processIncomingBuffer()
                }
                if isComplete || error != nil {
                    self.appState.isConnected = false
                    MobileCallManager.shared.reportCallEnded()
                    self.appState.activeCall = nil
                    self.isSendingSMS = false
                    self.appState.statusMessage = "连接已关闭"
                    self.scheduleReconnect()
                } else {
                    self.receivePackets()
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
                appState.statusMessage = "解包错误: \(error.localizedDescription)"
                break
            }
        }
    }

    private func handleReceivedFrame(_ frame: Data) {
        guard let envelope = try? JSONDecoder().decode(BridgeEnvelope.self, from: frame) else { return }

        switch envelope.type {
        case .pairChallenge:
            handlePairChallenge(envelope)
        case .error:
            if let errDTO = try? JSONDecoder().decode(BridgeErrorDTO.self, from: envelope.payload) {
                appState.statusMessage = "网关错误: \(errDTO.message)"
            }
        case .pong:
            break
        default:
            // Decrypt authenticated packets
            guard cryptoSession.isEstablished,
                  let decrypted = try? cryptoSession.open(
                    envelope.payload,
                    authenticating: envelope.authenticatedMetadata
                  ) else {
                return
            }
            guard registerIncomingId(envelope.id) else { return }
            dispatchDecryptedPacket(type: envelope.type, payload: decrypted)
        }
    }

    private func handlePairChallenge(_ envelope: BridgeEnvelope) {
        guard let challenge = try? JSONDecoder().decode(BridgePairChallengeDTO.self, from: envelope.payload) else {
            appState.statusMessage = "Mac 返回了无效的配对质询"
            return
        }
        pendingServerPublicKeyHex = challenge.serverPublicKeyHex
        if challenge.requiresPairingSecret == false, let nonce = challenge.resumeNonce {
            guard let trustedServerPublicKeyHex,
                  trustedServerPublicKeyHex.caseInsensitiveCompare(
                    challenge.serverPublicKeyHex
                  ) == .orderedSame else {
                appState.isPaired = false
                appState.statusMessage = "安全警告：Mac 网关身份密钥与首次配对记录不一致"
                return
            }
            do {
                try cryptoSession.establishSharedKey(
                    peerPublicKeyHex: challenge.serverPublicKeyHex,
                    pairingSecret: nonce
                )
                let verify = BridgeResumeVerifyDTO(
                    clientDeviceId: deviceId,
                    challengeNonce: nonce
                )
                sendEncrypted(verify, type: .resumeVerify)
                appState.statusMessage = "正在恢复与 \(challenge.serverDeviceName) 的安全会话..."
            } catch {
                appState.isPaired = false
                appState.statusMessage = "恢复安全会话失败，请重新配对"
            }
        } else {
            appState.isPaired = false
            appState.statusMessage = "已找到 \(challenge.serverDeviceName)，请输入 Mac 显示的安全配对密钥"
        }
    }

    private func dispatchDecryptedPacket(type: BridgeMessageType, payload: Data) {
        switch type {
        case .pairAccepted:
            if (try? JSONDecoder().decode(BridgePairAcceptedDTO.self, from: payload)) != nil {
                if let pendingServerPublicKeyHex {
                    trustedServerPublicKeyHex = pendingServerPublicKeyHex
                    try? keychain.save(
                        key: "ec20.mobile.serverPublicKey",
                        data: Data(pendingServerPublicKeyHex.utf8)
                    )
                }
                appState.isPaired = true
                appState.statusMessage = "已与 Mac 网关建立加密信道"
                requestSync()
            }
        case .syncResponse:
            if let sync = try? JSONDecoder().decode(BridgeSyncResponseDTO.self, from: payload) {
                appState.conversations = sync.conversations
                appState.messages = sync.recentMessages
                appState.contacts = sync.contacts
                appState.callHistory = sync.callHistory
                appState.totalUnreadCount = sync.unreadCount
                MobileNotificationManager.shared.updateAppBadge(sync.unreadCount)
                appState.lastSyncToken = sync.serverToken
            }
        case .smsReceivedEvent:
            if let msg = try? JSONDecoder().decode(BridgeMessageDTO.self, from: payload) {
                appState.messages.append(msg)
                MobileNotificationManager.shared.showIncomingSMS(
                    message: msg,
                    contactName: appState.findContact(for: msg.senderOrRecipient)?.name,
                    badgeCount: appState.totalUnreadCount + 1
                )
                requestSync()
            }
        case .callStateEvent:
            if let callState = try? JSONDecoder().decode(BridgeCallStateEventDTO.self, from: payload) {
                appState.activeCall = callState.activeCall
                if let call = callState.activeCall, call.status == "ringing" {
                    if lastReportedIncomingNumber != call.phoneNumber {
                        MobileCallManager.shared.reportIncomingCall(
                            caller: call.phoneNumber,
                            contactName: call.contactName
                        )
                        lastReportedIncomingNumber = call.phoneNumber
                    }
                } else if callState.activeCall == nil || callState.activeCall?.status == "ended" {
                    MobileCallManager.shared.reportCallEnded()
                    lastReportedIncomingNumber = nil
                }
            }
        case .badgeChangedEvent:
            if let badge = try? JSONDecoder().decode(BridgeBadgeChangedEventDTO.self, from: payload) {
                appState.totalUnreadCount = badge.totalUnreadCount
                MobileNotificationManager.shared.updateAppBadge(badge.totalUnreadCount)
            }
        case .smsSendResult:
            if let result = try? JSONDecoder().decode(BridgeBatchItemResultDTO.self, from: payload) {
                isSendingSMS = false
                if result.success {
                    lastSMSSendError = nil
                    requestSync()
                } else {
                    lastSMSSendError = result.reason ?? "短信发送失败"
                    appState.statusMessage = lastSMSSendError ?? "短信发送失败"
                }
            }
        case .batchDeleteResult:
            if (try? JSONDecoder().decode(BridgeBatchDeleteResultDTO.self, from: payload)) != nil {
                requestSync()
            }
        default:
            break
        }
    }

    // MARK: - Actions

    public func requestSync() {
        let req = BridgeSyncRequestDTO(sinceToken: appState.lastSyncToken)
        sendEncrypted(req, type: .syncRequest)
    }

    public func sendSMS(destination: String, text: String) {
        guard !isSendingSMS else { return }
        isSendingSMS = true
        lastSMSSendError = nil
        let req = BridgeSMSSendDTO(
            clientCommandId: UUID().uuidString,
            destination: destination,
            text: text
        )
        sendEncrypted(req, type: .smsSend)
    }

    public func answerCall() {
        let req = BridgeCallActionDTO(action: "answer")
        sendEncrypted(req, type: .callAnswer)
    }

    public func hangupCall() {
        let req = BridgeCallActionDTO(action: "hangup")
        sendEncrypted(req, type: .callHangup)
    }

    public func dial(number: String) {
        let req = BridgeCallActionDTO(action: "dial", number: number)
        sendEncrypted(req, type: .callDial)
    }

    public func deleteSMSBatch(ids: [String]) {
        let req = BridgeBatchDeleteRequestDTO(
            clientCommandId: UUID().uuidString,
            ids: ids
        )
        sendEncrypted(req, type: .batchDeleteMessages)
    }

    public func deleteThreadsBatch(threadIds: [String]) {
        let req = BridgeBatchDeleteRequestDTO(
            clientCommandId: UUID().uuidString,
            ids: threadIds
        )
        sendEncrypted(req, type: .batchDeleteThreads)
    }

    public func deleteCallHistoryBatch(ids: [String]) {
        let req = BridgeBatchDeleteRequestDTO(
            clientCommandId: UUID().uuidString,
            ids: ids
        )
        sendEncrypted(req, type: .batchDeleteCalls)
    }

    // MARK: - Transport

    private func sendEncrypted<T: Encodable>(_ obj: T, type: BridgeMessageType) {
        let metadata = BridgeEnvelope(type: type)
        guard let json = try? JSONEncoder().encode(obj),
              let ciphertext = try? cryptoSession.seal(
                json,
                authenticating: metadata.authenticatedMetadata
              ) else { return }
        sendEnvelope(metadata.replacingPayload(ciphertext))
    }

    private func sendEnvelope(_ envelope: BridgeEnvelope) {
        guard let envData = try? JSONEncoder().encode(envelope) else { return }
        let frame = BridgeFraming.encode(envData)
        connection?.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let endpoint = lastEndpoint else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect(to: endpoint)
        }
    }

    private func registerIncomingId(_ messageId: String) -> Bool {
        guard !processedIncomingIds.contains(messageId) else { return false }
        processedIncomingIds.insert(messageId)
        processedIncomingOrder.append(messageId)
        if processedIncomingOrder.count > 1024 {
            let expired = processedIncomingOrder.removeFirst()
            processedIncomingIds.remove(expired)
        }
        return true
    }
}
