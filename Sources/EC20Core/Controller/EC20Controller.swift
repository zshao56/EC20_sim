import Foundation
import Combine
import EC20BridgeProtocol

public typealias BatchItemResult = BridgeBatchItemResultDTO
public typealias BatchOperationResult = BridgeBatchDeleteResultDTO

public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(transportName: String)
    case error(message: String)
}

@MainActor
public final class EC20Controller: ObservableObject {
    @Published public private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published public private(set) var simInfo = SIMCardInfo()
    @Published public private(set) var smsMessages: [SMSMessage] = []
    @Published public private(set) var conversations: [SMSConversation] = []
    @Published public private(set) var activeCalls: [CallRecord] = []
    @Published public private(set) var callHistory: [CallHistoryItem] = []
    @Published public private(set) var contacts: [Contact] = []
    @Published public private(set) var storageCapacities: [StorageCapacity] = []
    @Published public private(set) var totalUnreadCount: Int = 0
    @Published public private(set) var cellularStatus = CellularNetworkStatus()
    @Published public var incomingCallAlert: String? = nil
    @Published public private(set) var audioAssessment = AudioBridgeAssessment()
    @Published public private(set) var atLogs: [String] = []
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var audioBridgeStatus: String = "Inactive"

    public var onCallStarted: (@MainActor @Sendable () async -> Void)?
    public var onCallEnded: (@MainActor @Sendable () async -> Void)?
    public var onIncomingSMSNotification: (@MainActor @Sendable (SMSMessage) -> Void)?
    public var onIncomingCallAlertWithDetails: (@MainActor @Sendable (_ callerNumber: String, _ contactName: String?) -> Void)?

    public let transport: any ATTransport
    public let database: EC20Database
    public let serialQueue = ATSerialQueue()

    private var urcTask: Task<Void, Never>?
    private var callPollingTimer: Timer?
    private var signalPollingTimer: Timer?
    private var networkPollingTimer: Timer?
    private let rawInputContinuation: AsyncStream<String>.Continuation
    private var inputProcessingTask: Task<Void, Never>?

    private var currentCallStartTime: Date?
    private var currentDialedNumber: String?
    private var lastIncomingCLIPNumber: String?
    private var isManualDisconnect: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var completedBatchCommands: [String: BatchOperationResult] = [:]
    private var completedSMSSendCommandIds: Set<String> = []
    private var completedSMSSendCommandOrder: [String] = []
    private var inFlightSMSSendCommands: [String: Task<Void, Error>] = [:]

    public init(transport: any ATTransport, database: EC20Database = EC20Database()) {
        self.transport = transport
        self.database = database

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { c in
            cont = c
        }
        self.rawInputContinuation = cont

        let q = self.serialQueue
        self.inputProcessingTask = Task {
            for await line in stream {
                if line == "> " {
                    await q.receivePrompt()
                } else {
                    await q.receiveLine(line)
                }
            }
        }

        setupTransportCallbacks()
        loadLocalData()
    }

    deinit {
        callPollingTimer?.invalidate()
        signalPollingTimer?.invalidate()
        networkPollingTimer?.invalidate()
        urcTask?.cancel()
        inputProcessingTask?.cancel()
        rawInputContinuation.finish()
    }

    private func setupTransportCallbacks() {
        transport.setIncomingHandler { [weak self] line in
            self?.rawInputContinuation.yield(line)
        }
        transport.setDisconnectHandler { [weak self] reason in
            Task { @MainActor in
                await self?.handleTransportDisconnect(reason: reason)
            }
        }
    }

    /// Handles unexpected device loss (module reboot, USB unplug) and auto-reconnects.
    private func handleTransportDisconnect(reason: String) async {
        guard !isManualDisconnect else { return }
        appendLog("[System] 设备连接中断: \(reason)，准备自动重连...")
        stopTimers()
        await serialQueue.reset(reason: reason)
        if !activeCalls.isEmpty {
            recordCallHistoryOnEnd(rejected: false)
            activeCalls.removeAll()
            await onCallEnded?()
        }
        incomingCallAlert = nil
        urcTask?.cancel()
        urcTask = nil
        transport.close()
        connectionStatus = .disconnected
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isManualDisconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self = self else { return }
            for attempt in 1...15 {
                guard !Task.isCancelled, !self.isManualDisconnect else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, !self.isManualDisconnect else { return }
                self.appendLog("[System] 自动重连尝试 \(attempt)/15...")
                await self.connect()
                if case .connected = self.connectionStatus {
                    self.appendLog("[System] 自动重连成功。")
                    return
                }
            }
            if !self.isManualDisconnect {
                self.connectionStatus = .error(message: "设备已断开，自动重连失败，请检查 USB 连接")
            }
        }
    }

    // MARK: - Local Data Loading

    public func loadLocalData() {
        self.conversations = database.fetchConversations()
        self.contacts = database.fetchContacts()
        self.callHistory = database.fetchCallHistory(limit: 100)
        self.storageCapacities = database.fetchStorageCapacity()
        self.totalUnreadCount = database.totalUnreadCount()
        self.smsMessages = database.fetchAllMessages()
    }

    // MARK: - Connection Lifecycle

    public func connect() async {
        switch connectionStatus {
        case .disconnected, .error:
            break
        case .connecting, .connected:
            return
        }
        isManualDisconnect = false
        connectionStatus = .connecting
        appendLog("[System] Connecting via \(transport.transportName)...")

        do {
            try transport.open()
            connectionStatus = .connected(transportName: transport.transportName)
            appendLog("[System] Connected successfully.")

            startURCListener()

            // Initial probe
            await initializeModem()

            // Initial SMS sync and storage query
            await syncModemSMS()
            await refreshCellularStatus()

            startTimers()
        } catch {
            let msg = error.localizedDescription
            connectionStatus = .error(message: msg)
            appendLog("[Error] Connection failed: \(msg)")
            if !isManualDisconnect {
                scheduleReconnect()
            }
        }
    }

    public func disconnect() async {
        isManualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        stopTimers()
        if case .connected = connectionStatus {
            await onCallEnded?()
        }
        urcTask?.cancel()
        urcTask = nil
        transport.close()
        connectionStatus = .disconnected
        appendLog("[System] Disconnected.")
    }

    // MARK: - AT Execution

    public func executeAT(_ raw: String, timeout: TimeInterval = 3.0) async throws -> ATResponse {
        let isSMSPayload = raw.hasSuffix("\u{1A}")
        let isSMSRead = raw.hasPrefix("AT+CMGL") || raw.hasPrefix("AT+CMGR")
        let isPrivateQuery = ["AT+CIMI", "AT+GSN", "AT+QCCID"].contains(raw) || raw.hasPrefix("ATD")
        let maskedCmd = isSMSPayload ? "[SMS PDU hidden]" :
            (raw.hasPrefix("ATD") ? "ATD[phone hidden];" : SensitiveMasker.sanitizeLog(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        appendLog(">> \(maskedCmd)")

        let wireCommand = isSMSPayload || raw.hasSuffix("\r\n") ? raw : raw + "\r\n"
        let cmd = ATCommand(raw: wireCommand, timeoutSeconds: timeout)
        let resp = try await serialQueue.execute(command: cmd) { [weak self] stringToSend in
            guard let self = self else { throw CancellationError() }
            try await self.transport.send(raw: stringToSend)
        }

        for line in resp.rawLines {
            if isSMSRead || isPrivateQuery || isSMSPayload {
                if line == "OK" || line == "ERROR" || line.hasPrefix("+CME ERROR:") || line.hasPrefix("+CMS ERROR:") {
                    appendLog("<< \(line)")
                }
            } else {
                appendLog("<< \(SensitiveMasker.sanitizeLog(line))")
            }
        }
        return resp
    }

    // MARK: - Initialization & Probing

    public func initializeModem() async {
        isBusy = true
        defer { isBusy = false }

        // 1. Disable echo & enable verbose errors
        _ = try? await executeAT("ATE0")
        _ = try? await executeAT("AT+CMEE=2")

        // 2. Query basic identity
        if let ati = try? await executeAT("ATI") {
            for line in ati.dataLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Revision:") {
                    simInfo.revision = trimmed.replacingOccurrences(of: "Revision:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.contains("EC20") || trimmed.contains("Quectel") {
                    if let existing = simInfo.model {
                        simInfo.model = "\(existing) \(trimmed)"
                    } else {
                        simInfo.model = trimmed
                    }
                }
            }
        }

        // 3. Query SIM Status
        if let cpinResp = try? await executeAT("AT+CPIN?") {
            for line in cpinResp.dataLines {
                if line.hasPrefix("+CPIN:") {
                    let statusStr = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    simInfo.cpinStatus = CPINStatus(rawValue: statusStr) ?? .unknown
                }
            }
        }

        // 4. Query Registration & Operator
        await refreshRegistration()

        // 5. Query Signal CSQ
        await refreshSignal()

        // 6. Query ICCID, IMSI, IMEI
        if let qccid = try? await executeAT("AT+QCCID") {
            for line in qccid.dataLines {
                if line.hasPrefix("+QCCID:") {
                    simInfo.iccid = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let cimi = try? await executeAT("AT+CIMI") {
            if let first = cimi.dataLines.first, first.allSatisfy({ $0.isNumber }) {
                simInfo.imsi = first.trimmingCharacters(in: .whitespaces)
            }
        }
        if let gsn = try? await executeAT("AT+GSN") {
            if let first = gsn.dataLines.first, first.allSatisfy({ $0.isNumber }) {
                simInfo.imei = first.trimmingCharacters(in: .whitespaces)
            }
        }

        // 7. Enable Caller ID and Call Waiting URCs
        _ = try? await executeAT("AT+CLIP=1")
        _ = try? await executeAT("AT+COLP=1")

        // 8. Probe Audio Bridge capabilities (non-destructive)
        await refreshAudioAssessment()
    }

    public func refreshRegistration() async {
        if let resp = try? await executeAT("AT+CREG?") {
            for line in resp.dataLines {
                if let ev = URCParser.parse(line), case let .cregChanged(status) = ev {
                    simInfo.cregStatus = status
                }
            }
        }
        if let resp = try? await executeAT("AT+CEREG?") {
            for line in resp.dataLines {
                if let ev = URCParser.parse(line), case let .ceregChanged(status) = ev {
                    simInfo.ceregStatus = status
                }
            }
        }
        if let resp = try? await executeAT("AT+COPS?") {
            for line in resp.dataLines {
                if line.hasPrefix("+COPS:") {
                    let parts = line.components(separatedBy: "\"")
                    if parts.count >= 2 {
                        simInfo.operatorName = parts[1]
                    }
                }
            }
        }
    }

    public func refreshSignal() async {
        if let resp = try? await executeAT("AT+CSQ") {
            for line in resp.dataLines {
                if let ev = URCParser.parse(line), case let .signalChanged(csq) = ev {
                    simInfo.signal = SignalInfo(csq: csq)
                }
            }
        }
    }

    public func refreshAudioAssessment() async {
        var qpcmv = "0,0"
        var qdai: String? = nil
        var isSupported = false

        if let resp = try? await executeAT("AT+QPCMV=?") {
            for line in resp.dataLines {
                if line.hasPrefix("+QPCMV:") {
                    isSupported = true
                }
            }
        }
        if let resp = try? await executeAT("AT+QPCMV?") {
            for line in resp.dataLines {
                if line.hasPrefix("+QPCMV:") {
                    qpcmv = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if let resp = try? await executeAT("AT+QDAI?") {
            for line in resp.dataLines {
                if line.hasPrefix("+QDAI:") {
                    qdai = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        self.audioAssessment = AudioBridgeAssessment(
            uacDeviceDetected: false,
            qpcmvSupported: isSupported,
            qpcmvCurrentSetting: qpcmv,
            qdaiSetting: qdai,
            systemAudioBridgeStatus: audioBridgeStatus,
            technicalConclusion: isSupported
                ? "AT+QPCMV reports Voice over USB support. The CoreAudio/USB PCM bridge is implemented; a live call is still needed to verify two-way audio."
                : "AT+QPCMV support was not confirmed on this connection."
        )
    }

    public func setAudioBridgeStatus(_ status: String) {
        self.audioBridgeStatus = status
        self.audioAssessment = AudioBridgeAssessment(
            uacDeviceDetected: audioAssessment.uacDeviceDetected,
            qpcmvSupported: audioAssessment.qpcmvSupported,
            qpcmvCurrentSetting: audioAssessment.qpcmvCurrentSetting,
            qdaiSetting: audioAssessment.qdaiSetting,
            systemAudioBridgeStatus: status
        )
    }

    // MARK: - Cellular Network Status & Control

    public func refreshCellularStatus() async {
        let status = await EC20NetworkManager.shared.detectNetworkStatus()
        self.cellularStatus = status
    }

    public func setCellularDataEnabled(_ enabled: Bool) async throws {
        try await EC20NetworkManager.shared.setCellularDataEnabled(enabled)
        await refreshCellularStatus()
    }

    // MARK: - SMS Operations & Persistence

    /// Catch-up sync from ME and SM storages without deleting module SMS.
    /// Returns only the messages newly inserted into SQLite (used for notifications).
    @discardableResult
    public func syncModemSMS() async -> [SMSMessage] {
        guard let mode = try? await executeAT("AT+CMGF=0"), mode.isOK else { return [] }

        // Query storage capacities
        await queryStorageCapacities()

        var listed: [SMSMessage] = []

        // Sync ME
        _ = try? await executeAT("AT+CPMS=\"ME\",\"ME\",\"ME\"")
        if let resp = try? await executeAT("AT+CMGL=4", timeout: 10) {
            listed += parseSMSList(resp.dataLines, storageArea: "ME")
        }

        // Sync SM
        _ = try? await executeAT("AT+CPMS=\"SM\",\"SM\",\"SM\"")
        if let resp = try? await executeAT("AT+CMGL=4", timeout: 10) {
            listed += parseSMSList(resp.dataLines, storageArea: "SM")
        }

        let assembled = Self.assembleMultipartMessages(listed)
        var inserted: [SMSMessage] = []
        for message in assembled where database.saveMessage(message) {
            inserted.append(message)
        }
        appendLog("[SMS] Sync complete: \(assembled.count) module messages checked (\(inserted.count) newly added to SQLite)")

        loadLocalData()
        return inserted
    }

    /// Loads/syncs SMS messages from module (backward-compatible alias for syncModemSMS)
    @discardableResult
    public func loadSMSMessages() async -> [SMSMessage] {
        return await syncModemSMS()
    }

    private func queryStorageCapacities() async {
        if let cpms = try? await executeAT("AT+CPMS?") {
            for line in cpms.dataLines {
                if line.hasPrefix("+CPMS:") {
                    let parts = line.dropFirst(6).components(separatedBy: ",")
                    if parts.count >= 3 {
                        let area1 = parts[0].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                        let used1 = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                        let total1 = Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
                        database.updateStorageCapacity(area: area1, used: used1, total: total1)
                    }
                }
            }
        }
        self.storageCapacities = database.fetchStorageCapacity()
    }

    private func parseSMSList(_ lines: [String], storageArea: String) -> [SMSMessage] {
        var messages: [SMSMessage] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("+CMGL:") {
                let header = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                let parts = header.components(separatedBy: ",")
                if let messageIndex = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? ""),
                   index + 1 < lines.count,
                   let decoded = PDUCodec.decodeDeliverPDU(lines[index + 1]) {
                    let msg = SMSMessage(
                        storageIndex: messageIndex,
                        storageArea: storageArea,
                        senderOrRecipient: decoded.sender,
                        text: decoded.text,
                        timestamp: decoded.timestamp ?? Date(),
                        isIncoming: true,
                        isRead: (Int(parts.dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? "1") ?? 1) != 0,
                        rawPDU: lines[index + 1],
                        multipartInfo: decoded.multipartInfo
                    )
                    messages.append(msg)
                    index += 1
                }
            }
            index += 1
        }
        return messages
    }

    public static func assembleMultipartMessages(_ messages: [SMSMessage]) -> [SMSMessage] {
        var result = messages.filter { $0.multipartInfo == nil }
        var groups: [String: [SMSMessage]] = [:]
        for message in messages {
            guard let part = message.multipartInfo else { continue }
            let key = "\(message.storageArea ?? "")|\(message.senderOrRecipient)|\(part.referenceNumber)|\(part.totalParts)"
            groups[key, default: []].append(message)
        }
        for group in groups.values {
            guard let first = group.first, let descriptor = first.multipartInfo else { continue }
            let ordered = group.sorted { ($0.multipartInfo?.currentPart ?? 0) < ($1.multipartInfo?.currentPart ?? 0) }
            let partNumbers = Set(ordered.compactMap { $0.multipartInfo?.currentPart })
            if descriptor.totalParts > 0 && ordered.count == descriptor.totalParts && partNumbers == Set(1...descriptor.totalParts) {
                result.append(SMSMessage(
                    storageIndex: first.storageIndex,
                    storageArea: first.storageArea,
                    senderOrRecipient: first.senderOrRecipient,
                    text: ordered.map(\.text).joined(),
                    timestamp: ordered.map(\.timestamp).min() ?? first.timestamp,
                    isIncoming: true,
                    isRead: ordered.allSatisfy(\.isRead),
                    rawPDU: ordered.compactMap(\.rawPDU).joined(separator: ";")
                ))
            }
            // Incomplete multipart fragments are not emitted as complete conversation messages;
            // they remain safely stored in module memory until all parts are collected.
        }
        return result
    }

    public func sendSMS(to destination: String, text: String) async throws {
        guard isValidPhoneNumber(destination), !text.isEmpty else {
            throw NSError(domain: "EC20Controller", code: -8, userInfo: [NSLocalizedDescriptionKey: "请输入有效手机号和非空内容"])
        }

        let normalized = PhoneNumberNormalizer.normalize(destination)
        let outboxMsg = SMSMessage(
            threadId: normalized,
            senderOrRecipient: destination,
            text: text,
            timestamp: Date(),
            isIncoming: false,
            isRead: true,
            sendStatus: .sending
        )
        database.saveMessage(outboxMsg)
        loadLocalData()

        do {
            try await transmitSMS(to: destination, text: text)
            database.updateMessageStatus(id: outboxMsg.id, status: .sent)
            appendLog("[SMS] 短信发送成功！")
        } catch {
            database.updateMessageStatus(id: outboxMsg.id, status: .failed, error: error.localizedDescription)
            loadLocalData()
            throw error
        }
        loadLocalData()
    }

    /// Sends a remote SMS command at most once for a given command ID.
    /// Concurrent retries await the same in-flight operation; successful IDs are
    /// retained in a bounded process-lifetime cache so a retransmitted request
    /// cannot create a second modem submission.
    public func sendSMSIdempotently(
        to destination: String,
        text: String,
        clientCommandId: String
    ) async throws {
        let commandId = clientCommandId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandId.isEmpty else {
            throw NSError(
                domain: "EC20Controller",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "短信命令 ID 不能为空"]
            )
        }

        if completedSMSSendCommandIds.contains(commandId) {
            return
        }
        if let existing = inFlightSMSSendCommands[commandId] {
            return try await existing.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                throw CancellationError()
            }
            try await self.sendSMS(to: destination, text: text)
        }
        inFlightSMSSendCommands[commandId] = task

        do {
            try await task.value
            inFlightSMSSendCommands.removeValue(forKey: commandId)
            completedSMSSendCommandIds.insert(commandId)
            completedSMSSendCommandOrder.append(commandId)
            if completedSMSSendCommandOrder.count > 512 {
                let expired = completedSMSSendCommandOrder.removeFirst()
                completedSMSSendCommandIds.remove(expired)
            }
        } catch {
            inFlightSMSSendCommands.removeValue(forKey: commandId)
            throw error
        }
    }

    /// Sends the PDU sequence for an SMS. Does not touch SQLite; callers own message state.
    private func transmitSMS(to destination: String, text: String) async throws {
        appendLog("[SMS] 发送短信至 \(SensitiveMasker.mask(phoneNumber: destination))...")
        let pdus = PDUCodec.encodeSubmitPDUs(destination: destination, text: text)
        _ = try await executeAT("AT+CMGF=0")
        for (idx, pdu) in pdus.enumerated() {
            appendLog("[SMS] 发送分包 \(idx + 1)/\(pdus.count) (tpduLength=\(pdu.tpduLength))...")
            let promptResp = try await executeAT("AT+CMGS=\(pdu.tpduLength)", timeout: 5.0)
            guard promptResp.rawLines.contains(">") else {
                throw NSError(domain: "EC20Controller", code: -3, userInfo: [NSLocalizedDescriptionKey: "未收到短信提示符 '>'"])
            }
            let sendPduResp = try await executeAT("\(pdu.pduHex)\u{1A}", timeout: 15.0)
            guard sendPduResp.isOK else {
                throw NSError(domain: "EC20Controller", code: -4, userInfo: [NSLocalizedDescriptionKey: sendPduResp.errorMessage ?? "PDU 发送失败"])
            }
        }
    }

    /// Retries an existing failed outbox message in place (same row/id, status updated).
    public func retrySMS(id: UUID) async throws {
        guard let msg = database.fetchMessage(id: id) else {
            throw NSError(domain: "EC20Controller", code: -11, userInfo: [NSLocalizedDescriptionKey: "未找到待重发的短信"])
        }
        guard !msg.isIncoming else {
            throw NSError(domain: "EC20Controller", code: -12, userInfo: [NSLocalizedDescriptionKey: "接收到的短信无法重发"])
        }
        database.updateMessageStatus(id: id, status: .sending, error: nil)
        loadLocalData()
        do {
            try await transmitSMS(to: msg.senderOrRecipient, text: msg.text)
            database.updateMessageStatus(id: id, status: .sent, error: nil)
        } catch {
            database.updateMessageStatus(id: id, status: .failed, error: error.localizedDescription)
            loadLocalData()
            throw error
        }
        loadLocalData()
    }

    public func markConversationRead(threadId: String) {
        database.markThreadRead(threadId: threadId)
        loadLocalData()
    }

    public func fetchMessagesForThread(_ threadId: String) -> [SMSMessage] {
        return database.fetchMessages(threadId: threadId)
    }

    /// Deletes a single SMS. If message resides in module storage, deletes from module first via AT+CPMS + AT+CMGD.
    public func deleteSMS(id: UUID) async throws {
        guard let msg = database.fetchMessage(id: id) else {
            loadLocalData()
            return
        }

        if let idx = msg.storageIndex {
            guard let area = validatedSMSStorageArea(msg.storageArea) else {
                throw NSError(domain: "EC20Controller", code: -19, userInfo: [
                    NSLocalizedDescriptionKey: "短信存储区标识无效"
                ])
            }
            appendLog("[SMS] 正在从模块 \(area) 存储区删除短信 (索引: \(idx))...")
            let cpms = try await executeAT("AT+CPMS=\"\(area)\",\"\(area)\",\"\(area)\"", timeout: 5.0)
            guard cpms.isOK else {
                throw NSError(domain: "EC20Controller", code: -20, userInfo: [
                    NSLocalizedDescriptionKey: "切换短信存储区 \(area) 失败: \(cpms.errorMessage ?? "未知错误")"
                ])
            }
            let cmgd = try await executeAT("AT+CMGD=\(idx)", timeout: 5.0)
            guard cmgd.isOK else {
                throw NSError(domain: "EC20Controller", code: -21, userInfo: [
                    NSLocalizedDescriptionKey: "模块删除短信失败 (索引 \(idx)): \(cmgd.errorMessage ?? "未知错误")"
                ])
            }
        }

        database.deleteMessage(id: id)
        loadLocalData()
    }

    /// Deletes all messages in a conversation thread safely one by one.
    public func deleteThread(threadId: String) async throws {
        let messages = database.fetchMessages(threadId: threadId)
        var failedCount = 0
        var lastError: Error?

        for msg in messages {
            do {
                try await deleteSMS(id: msg.id)
            } catch {
                failedCount += 1
                lastError = error
                appendLog("[SMS] 会话删除失败 (短信 ID \(msg.id)): \(error.localizedDescription)")
            }
        }

        loadLocalData()

        if failedCount > 0 {
            let desc = "删除会话部分完成，但有 \(failedCount) 条短信从模块删除失败（已保留本地记录）：\(lastError?.localizedDescription ?? "未知错误")"
            throw NSError(domain: "EC20Controller", code: -22, userInfo: [NSLocalizedDescriptionKey: desc])
        } else {
            database.deleteThread(threadId: threadId)
            loadLocalData()
        }
    }

    // MARK: - Batch Deletion Operations

    /// Batch delete SMS messages with idempotency, descending index ordering per storage area, and SQLite transactions.
    public func deleteSMSBatch(ids: [UUID], clientCommandId: String? = nil) async -> BatchOperationResult {
        if let cmdId = clientCommandId, let cached = completedBatchCommands[cmdId] {
            return cached
        }

        var itemResults: [BatchItemResult] = []
        var localOnlyIds: [UUID] = []
        var moduleMsgsByArea: [String: [SMSMessage]] = [:]

        // Categorize messages
        for id in ids {
            guard let msg = database.fetchMessage(id: id) else {
                // Already deleted or non-existent
                itemResults.append(BatchItemResult(id: id.uuidString, success: true, reason: nil))
                continue
            }

            if let _ = msg.storageIndex {
                guard let area = validatedSMSStorageArea(msg.storageArea) else {
                    itemResults.append(BatchItemResult(
                        id: msg.id.uuidString,
                        success: false,
                        reason: "短信存储区标识无效"
                    ))
                    continue
                }
                moduleMsgsByArea[area, default: []].append(msg)
            } else {
                localOnlyIds.append(id)
            }
        }

        // Delete module messages in descending order of storageIndex per area
        for (area, msgs) in moduleMsgsByArea {
            let sortedMsgs = msgs.sorted { ($0.storageIndex ?? 0) > ($1.storageIndex ?? 0) }

            // Switch storage area once per area
            let cpms = try? await executeAT("AT+CPMS=\"\(area)\",\"\(area)\",\"\(area)\"", timeout: 5.0)
            if cpms?.isOK != true {
                for m in sortedMsgs {
                    itemResults.append(BatchItemResult(
                        id: m.id.uuidString,
                        success: false,
                        reason: "切换存储区 \(area) 失败"
                    ))
                }
                continue
            }

            for m in sortedMsgs {
                guard let idx = m.storageIndex else { continue }
                let cmgd = try? await executeAT("AT+CMGD=\(idx)", timeout: 5.0)
                if cmgd?.isOK == true {
                    database.deleteMessage(id: m.id)
                    itemResults.append(BatchItemResult(id: m.id.uuidString, success: true, reason: nil))
                } else {
                    let errMsg = cmgd?.errorMessage ?? "模块删除失败"
                    itemResults.append(BatchItemResult(id: m.id.uuidString, success: false, reason: errMsg))
                }
            }
        }

        // Delete local-only messages in transaction
        if !localOnlyIds.isEmpty {
            database.deleteMessagesBatch(ids: localOnlyIds)
            for id in localOnlyIds {
                itemResults.append(BatchItemResult(id: id.uuidString, success: true, reason: nil))
            }
        }

        loadLocalData()

        let succeeded = itemResults.filter(\.success).count
        let failed = itemResults.filter { !$0.success }.count
        let finalResult = BatchOperationResult(
            clientCommandId: clientCommandId ?? UUID().uuidString,
            totalRequested: ids.count,
            succeededCount: succeeded,
            failedCount: failed,
            items: itemResults
        )

        if let cmdId = clientCommandId {
            completedBatchCommands[cmdId] = finalResult
        }
        return finalResult
    }

    private func validatedSMSStorageArea(_ rawValue: String?) -> String? {
        let area = (rawValue ?? "ME")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return ["ME", "SM", "MT"].contains(area) ? area : nil
    }

    /// Batch delete conversation threads safely.
    public func deleteThreadsBatch(threadIds: [String], clientCommandId: String? = nil) async -> BatchOperationResult {
        if let cmdId = clientCommandId, let cached = completedBatchCommands[cmdId] {
            return cached
        }

        var itemResults: [BatchItemResult] = []

        for threadId in threadIds {
            let messages = database.fetchMessages(threadId: threadId)
            if messages.isEmpty {
                database.deleteThread(threadId: threadId)
                itemResults.append(BatchItemResult(id: threadId, success: true, reason: nil))
                continue
            }

            let msgIds = messages.map(\.id)
            let batchRes = await deleteSMSBatch(ids: msgIds)
            if batchRes.isFullSuccess {
                database.deleteThread(threadId: threadId)
                itemResults.append(BatchItemResult(id: threadId, success: true, reason: nil))
            } else {
                let failCount = batchRes.failedCount
                itemResults.append(BatchItemResult(
                    id: threadId,
                    success: false,
                    reason: "部分短信未能从模块删除 (\(failCount) 条失败，已保留本地记录)"
                ))
            }
        }

        loadLocalData()

        let succeeded = itemResults.filter(\.success).count
        let failed = itemResults.filter { !$0.success }.count
        let finalResult = BatchOperationResult(
            clientCommandId: clientCommandId ?? UUID().uuidString,
            totalRequested: threadIds.count,
            succeededCount: succeeded,
            failedCount: failed,
            items: itemResults
        )

        if let cmdId = clientCommandId {
            completedBatchCommands[cmdId] = finalResult
        }
        return finalResult
    }

    /// Batch delete call history records in transaction.
    public func deleteCallHistoryBatch(ids: [UUID], clientCommandId: String? = nil) -> BatchOperationResult {
        if let cmdId = clientCommandId, let cached = completedBatchCommands[cmdId] {
            return cached
        }

        database.deleteCallHistoryBatch(ids: ids)
        loadLocalData()

        let items = ids.map { BatchItemResult(id: $0.uuidString, success: true, reason: nil) }
        let finalResult = BatchOperationResult(
            clientCommandId: clientCommandId ?? UUID().uuidString,
            totalRequested: ids.count,
            succeededCount: ids.count,
            failedCount: 0,
            items: items
        )

        if let cmdId = clientCommandId {
            completedBatchCommands[cmdId] = finalResult
        }
        return finalResult
    }

    // MARK: - Contacts Management

    public func saveContact(name: String, phone: String, notes: String = "") {
        let contact = Contact(name: name, phoneNumber: phone, notes: notes)
        database.saveContact(contact)
        loadLocalData()
    }

    public func deleteContact(id: UUID) {
        database.deleteContact(id: id)
        loadLocalData()
    }

    /// Import phonebook contacts from SIM and Modem
    public func importContactsFromSIM() async throws -> Int {
        var count = 0
        for book in ["SM", "ME"] {
            _ = try? await executeAT("AT+CPBS=\"\(book)\"")
            if let resp = try? await executeAT("AT+CPBR=1,500", timeout: 8.0) {
                for line in resp.dataLines {
                    if line.hasPrefix("+CPBR:") {
                        let content = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        let parts = content.components(separatedBy: ",")
                        if parts.count >= 4 {
                            let number = parts[1].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                            var name = parts[3].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                            if name.isEmpty { name = "联系人 \(number)" }
                            if !number.isEmpty {
                                let contact = Contact(name: name, phoneNumber: number, notes: "导入自 \(book)")
                                database.saveContact(contact)
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        loadLocalData()
        return count
    }

    // MARK: - Call History Operations

    /// Import call history records from module DC/MC/RC
    public func importCallHistoryFromModem() async throws -> Int {
        var count = 0
        let mapping: [(String, CallHistoryType, CallRecordSource)] = [
            ("DC", .outgoing, .moduleDC),
            ("MC", .missed, .moduleMC),
            ("RC", .incoming, .moduleRC)
        ]
        for (book, type, src) in mapping {
            _ = try? await executeAT("AT+CPBS=\"\(book)\"")
            if let resp = try? await executeAT("AT+CPBR=1,100", timeout: 5.0) {
                for line in resp.dataLines {
                    if line.hasPrefix("+CPBR:") {
                        let content = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        let parts = content.components(separatedBy: ",")
                        if parts.count >= 2 {
                            let number = parts[1].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                            if !number.isEmpty {
                                let contact = database.findContact(forPhone: number)
                                let record = CallHistoryItem(
                                    phoneNumber: number,
                                    contactName: contact?.name,
                                    type: type,
                                    timestamp: nil, // Module does not provide exact timestamp
                                    source: src,
                                    hasExactTimestamp: false
                                )
                                database.saveCallRecord(record)
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        loadLocalData()
        return count
    }

    // MARK: - Call Operations

    public func dial(number: String) async throws {
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPhoneNumber(clean) else {
            throw NSError(domain: "EC20Controller", code: -9, userInfo: [NSLocalizedDescriptionKey: "请输入有效电话号码"])
        }
        appendLog("[Call] 拨号中 \(SensitiveMasker.mask(phoneNumber: clean))...")
        await onCallStarted?()
        do {
            let resp = try await executeAT("ATD\(clean);", timeout: 10.0)
            guard resp.isOK else {
                throw NSError(domain: "EC20Controller", code: -5, userInfo: [NSLocalizedDescriptionKey: "拨号失败: \(resp.errorMessage ?? "错误")"])
            }
        } catch {
            await onCallEnded?()
            throw error
        }
        self.currentDialedNumber = clean
        self.currentCallStartTime = Date()
        let record = CallRecord(id: 1, direction: .outgoing, status: .dialing, phoneNumber: clean, startedAt: Date())
        activeCalls = [record]
    }

    public func answerCall() async throws {
        appendLog("[Call] 正在接听来电...")
        await onCallStarted?()
        do {
            let resp = try await executeAT("ATA", timeout: 5.0)
            guard resp.isOK else {
                throw NSError(domain: "EC20Controller", code: -6, userInfo: [NSLocalizedDescriptionKey: "接听失败: \(resp.errorMessage ?? "错误")"])
            }
        } catch {
            await onCallEnded?()
            throw error
        }
        incomingCallAlert = nil
        self.currentCallStartTime = Date()
        if let idx = activeCalls.firstIndex(where: { $0.status == .ringingIncoming }) {
            activeCalls[idx].status = .active
            activeCalls[idx].startedAt = Date()
        }
    }

    public func hangupCall() async throws {
        appendLog("[Call] 正在挂断电话...")
        let response = try await executeAT("ATH", timeout: 5.0)
        guard response.isOK else {
            throw NSError(domain: "EC20Controller", code: -10, userInfo: [NSLocalizedDescriptionKey: response.errorMessage ?? "挂断失败"])
        }

        recordCallHistoryOnEnd(rejected: false)
        incomingCallAlert = nil
        activeCalls.removeAll()
        await onCallEnded?()
    }

    public func rejectCall() async throws {
        appendLog("[Call] 正在拒绝来电...")
        _ = try? await executeAT("ATH", timeout: 5.0)
        recordCallHistoryOnEnd(rejected: true)
        incomingCallAlert = nil
        activeCalls.removeAll()
        await onCallEnded?()
    }

    private func recordCallHistoryOnEnd(rejected: Bool) {
        let call = activeCalls.first
        // Guard against duplicate end events
        if call == nil && currentCallStartTime == nil && currentDialedNumber == nil && lastIncomingCLIPNumber == nil {
            return
        }

        var resolvedPhone = call?.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if resolvedPhone.isEmpty {
            if let dialed = currentDialedNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !dialed.isEmpty {
                resolvedPhone = dialed
            } else if let clip = lastIncomingCLIPNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                resolvedPhone = clip
            } else {
                resolvedPhone = "未知号码"
            }
        }

        let dur: Int?
        if let start = currentCallStartTime {
            dur = max(0, Int(Date().timeIntervalSince(start)))
        } else {
            dur = nil
        }

        let isOutgoing = (call?.direction == .outgoing) || (currentDialedNumber != nil)
        let type: CallHistoryType
        if isOutgoing {
            type = .outgoing
        } else {
            type = rejected ? .rejected : ((call?.status == .active) ? .incoming : .missed)
        }

        let contact = (resolvedPhone != "未知号码") ? database.findContact(forPhone: resolvedPhone) : nil
        let item = CallHistoryItem(
            phoneNumber: resolvedPhone,
            contactName: contact?.name,
            type: type,
            timestamp: currentCallStartTime ?? Date(),
            durationSeconds: dur,
            source: .local,
            hasExactTimestamp: true
        )
        database.saveCallRecord(item)
        loadLocalData()

        currentCallStartTime = nil
        currentDialedNumber = nil
        lastIncomingCLIPNumber = nil
    }

    private func isValidPhoneNumber(_ value: String) -> Bool {
        let digits = value.hasPrefix("+") ? value.dropFirst() : Substring(value)
        return (3...20).contains(digits.count) && digits.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    public func pollCalls() async {
        guard let resp = try? await executeAT("AT+CLCC", timeout: 3.0) else { return }
        var currentActive: [CallRecord] = []
        for line in resp.dataLines {
            if line.hasPrefix("+CLCC:") {
                let content = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                let parts = content.components(separatedBy: ",")
                if parts.count >= 6 {
                    let id = Int(parts[0]) ?? 1
                    let dirInt = Int(parts[1]) ?? 0
                    let statInt = Int(parts[2]) ?? 0
                    var num = parts[5].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

                    let dir: CallDirection = (dirInt == 0) ? .outgoing : .incoming
                    if num.isEmpty {
                        // +CLCC received empty number; do NOT overwrite existing valid number
                        if let existing = self.activeCalls.first(where: { $0.id == id && !$0.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                            num = existing.phoneNumber
                        } else if let existingAny = self.activeCalls.first(where: { !$0.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                            num = existingAny.phoneNumber
                        } else if dir == .outgoing, let dialed = self.currentDialedNumber, !dialed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            num = dialed
                        } else if dir == .incoming, let clip = self.lastIncomingCLIPNumber, !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            num = clip
                        }
                    }

                    let status: CallStatus
                    switch statInt {
                    case 0: status = .active
                    case 1: status = .held
                    case 2: status = .dialing
                    case 3: status = .dialing
                    case 4: status = .ringingIncoming
                    case 5: status = .ringingIncoming
                    default: status = .ended
                    }
                    currentActive.append(CallRecord(id: id, direction: dir, status: status, phoneNumber: num, startedAt: currentCallStartTime ?? Date()))
                }
            }
        }
        let previouslyActive = self.activeCalls.contains(where: { $0.status == .active })
        if !currentActive.isEmpty {
            self.activeCalls = currentActive
            let currentlyActive = currentActive.contains(where: { $0.status == .active })
            if !previouslyActive && currentlyActive {
                await onCallStarted?()
            }
        } else if !self.activeCalls.isEmpty && !self.activeCalls.contains(where: { $0.status == .dialing || $0.status == .ringingIncoming }) {
            recordCallHistoryOnEnd(rejected: false)
            self.activeCalls.removeAll()
            if previouslyActive {
                await onCallEnded?()
            }
        }
    }

    // MARK: - URC & Timers

    private func startURCListener() {
        urcTask = Task { [weak self] in
            guard let self = self else { return }
            for await (event, raw) in self.serialQueue.urcStream {
                await self.handleURCEvent(event, raw: raw)
            }
        }
    }

    private func handleURCEvent(_ event: URCEvent, raw: String) async {
        appendLog("[URC] \(SensitiveMasker.sanitizeLog(raw))")

        switch event {
        case .ring:
            if incomingCallAlert == nil {
                incomingCallAlert = "未知来电..."
                let num = self.lastIncomingCLIPNumber ?? "未知号码"
                let contact = (num != "未知号码") ? database.findContact(forPhone: num) : nil
                onIncomingCallAlertWithDetails?(num, contact?.name)
            }
        case .incomingCall(let caller):
            if let number = caller, !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.lastIncomingCLIPNumber = number
                let contact = database.findContact(forPhone: number)
                let masked = SensitiveMasker.mask(phoneNumber: number)
                incomingCallAlert = contact != nil ? "\(contact!.name) (\(masked))" : masked
                let call = CallRecord(id: 1, direction: .incoming, status: .ringingIncoming, phoneNumber: number)
                activeCalls = [call]
                onIncomingCallAlertWithDetails?(number, contact?.name)
            }
        case .callEnded(let reason):
            recordCallHistoryOnEnd(rejected: false)
            incomingCallAlert = nil
            activeCalls.removeAll()
            await onCallEnded?()
            appendLog("[Call] 通话已结束: \(reason)")
        case .incomingSMS(let storage, let index):
            appendLog("[SMS] 收到新短信通知: \(storage)[\(index)]")
            let inserted = await syncModemSMS()
            let incomingInserted = inserted.filter { $0.isIncoming && $0.multipartInfo == nil }
            if !incomingInserted.isEmpty {
                for msg in incomingInserted {
                    onIncomingSMSNotification?(msg)
                }
            } else {
                appendLog("[SMS] 该短信已存在或为未收齐分片，暂不重复通知。")
            }
        case .cregChanged(let status):
            simInfo.cregStatus = status
        case .ceregChanged(let status):
            simInfo.ceregStatus = status
        case .signalChanged(let csq):
            simInfo.signal = SignalInfo(csq: csq)
        case .simStatusChanged(let cpin):
            simInfo.cpinStatus = cpin
        default:
            break
        }
    }

    private func startTimers() {
        callPollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if !self.activeCalls.isEmpty {
                    await self.pollCalls()
                }
            }
        }

        signalPollingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.refreshSignal()
            }
        }

        networkPollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.refreshCellularStatus()
            }
        }
    }

    private func stopTimers() {
        callPollingTimer?.invalidate()
        callPollingTimer = nil
        signalPollingTimer?.invalidate()
        signalPollingTimer = nil
        networkPollingTimer?.invalidate()
        networkPollingTimer = nil
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        atLogs.append("[\(timestamp)] \(text)")
        if atLogs.count > 500 {
            atLogs.removeFirst(atLogs.count - 500)
        }
    }
}
