import Foundation
import Combine

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
    @Published public private(set) var activeCalls: [CallRecord] = []
    @Published public var incomingCallAlert: String? = nil
    @Published public private(set) var audioAssessment = AudioBridgeAssessment()
    @Published public private(set) var atLogs: [String] = []
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var audioBridgeStatus: String = "Inactive"
    
    public var onCallStarted: (@MainActor @Sendable () async -> Void)?
    public var onCallEnded: (@MainActor @Sendable () async -> Void)?
    
    public let transport: any ATTransport
    public let serialQueue = ATSerialQueue()
    
    private var urcTask: Task<Void, Never>?
    private var callPollingTimer: Timer?
    private var signalPollingTimer: Timer?
    private let rawInputContinuation: AsyncStream<String>.Continuation
    private var inputProcessingTask: Task<Void, Never>?
    
    public init(transport: any ATTransport) {
        self.transport = transport
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
    }
    
    deinit {
        callPollingTimer?.invalidate()
        signalPollingTimer?.invalidate()
        urcTask?.cancel()
        inputProcessingTask?.cancel()
        rawInputContinuation.finish()
    }
    
    private func setupTransportCallbacks() {
        transport.setIncomingHandler { [weak self] line in
            self?.rawInputContinuation.yield(line)
        }
    }
    
    // MARK: - Connection Lifecycle
    
    public func connect() async {
        switch connectionStatus {
        case .disconnected, .error:
            break
        case .connecting, .connected:
            return
        }
        connectionStatus = .connecting
        appendLog("[System] Connecting via \(transport.transportName)...")
        
        do {
            try transport.open()
            connectionStatus = .connected(transportName: transport.transportName)
            appendLog("[System] Connected successfully.")
            
            startURCListener()
            
            // Initial probe
            await initializeModem()
            startTimers()
        } catch {
            let msg = error.localizedDescription
            connectionStatus = .error(message: msg)
            appendLog("[Error] Connection failed: \(msg)")
        }
    }
    
    public func disconnect() {
        stopTimers()
        urcTask?.cancel()
        urcTask = nil
        transport.close()
        connectionStatus = .disconnected
        appendLog("[System] Disconnected.")
    }
    
    // MARK: - AT Execution
    
    public func executeAT(_ raw: String, timeout: TimeInterval = 3.0) async throws -> ATResponse {
        let maskedCmd = SensitiveMasker.sanitizeLog(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        appendLog(">> \(maskedCmd)")
        
        let cmd = ATCommand(raw: raw.hasSuffix("\r\n") ? raw : raw + "\r\n", timeoutSeconds: timeout)
        let resp = try await serialQueue.execute(command: cmd) { [weak self] stringToSend in
            guard let self = self else { return }
            try await self.transport.send(raw: stringToSend)
        }
        
        for line in resp.rawLines {
            appendLog("<< \(SensitiveMasker.sanitizeLog(line))")
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
        
        // 9. Load SMS
        await loadSMSMessages()
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
            systemAudioBridgeStatus: audioBridgeStatus
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
    
    // MARK: - SMS Operations
    
    public func loadSMSMessages() async {
        // Read messages from ME (module) and SM (SIM)
        _ = try? await executeAT("AT+CMGF=1") // Use text mode for listing or fallback
        _ = try? await executeAT("AT+CPMS=\"ME\",\"ME\",\"ME\"")
        if let resp = try? await executeAT("AT+CMGL=\"ALL\"") {
            parseAndStoreSMSList(resp.dataLines, storageArea: "ME")
        }
        _ = try? await executeAT("AT+CPMS=\"SM\",\"SM\",\"SM\"")
        if let resp = try? await executeAT("AT+CMGL=\"ALL\"") {
            parseAndStoreSMSList(resp.dataLines, storageArea: "SM")
        }
    }
    
    private func parseAndStoreSMSList(_ lines: [String], storageArea: String) {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("+CMGL:") {
                let header = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                let parts = header.components(separatedBy: ",")
                let msgIdx = Int(parts.first ?? "0") ?? 0
                var sender = "Unknown"
                if parts.count >= 3 {
                    sender = parts[2].replacingOccurrences(of: "\"", with: "")
                }
                
                var body = ""
                if index + 1 < lines.count && !lines[index + 1].hasPrefix("+CMGL:") {
                    body = lines[index + 1]
                    index += 1
                }
                
                let message = SMSMessage(
                    storageIndex: msgIdx,
                    storageArea: storageArea,
                    senderOrRecipient: sender,
                    text: body,
                    timestamp: Date(),
                    isIncoming: true,
                    isRead: true
                )
                
                if !smsMessages.contains(where: { $0.storageIndex == msgIdx && $0.storageArea == storageArea }) {
                    smsMessages.append(message)
                }
            }
            index += 1
        }
    }
    
    public func sendSMS(to destination: String, text: String) async throws {
        appendLog("[SMS] Sending SMS to \(SensitiveMasker.mask(phoneNumber: destination))...")
        
        let pdus = PDUCodec.encodeSubmitPDUs(destination: destination, text: text)
        _ = try await executeAT("AT+CMGF=0") // Switch to PDU mode
        
        for (idx, pdu) in pdus.enumerated() {
            appendLog("[SMS] Sending part \(idx + 1)/\(pdus.count) (tpduLength=\(pdu.tpduLength))...")
            let promptResp = try await executeAT("AT+CMGS=\(pdu.tpduLength)", timeout: 5.0)
            guard promptResp.rawLines.contains(">") else {
                throw NSError(domain: "EC20Controller", code: -3, userInfo: [NSLocalizedDescriptionKey: "Did not receive '>' prompt from modem"])
            }
            // Send PDU hex followed by Ctrl+Z (\u{1A})
            let sendPduResp = try await executeAT("\(pdu.pduHex)\u{1A}", timeout: 15.0)
            guard sendPduResp.isOK else {
                throw NSError(domain: "EC20Controller", code: -4, userInfo: [NSLocalizedDescriptionKey: "Send PDU failed: \(sendPduResp.errorMessage ?? "Unknown error")"])
            }
        }
        
        // Add to local message list
        let sentMsg = SMSMessage(
            senderOrRecipient: destination,
            text: text,
            timestamp: Date(),
            isIncoming: false,
            isRead: true
        )
        smsMessages.insert(sentMsg, at: 0)
        appendLog("[SMS] Message sent successfully!")
    }
    
    // MARK: - Call Operations
    
    public func dial(number: String) async throws {
        let clean = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        appendLog("[Call] Dialing \(SensitiveMasker.mask(phoneNumber: clean))...")
        
        let resp = try await executeAT("ATD\(clean);", timeout: 10.0)
        guard resp.isOK else {
            throw NSError(domain: "EC20Controller", code: -5, userInfo: [NSLocalizedDescriptionKey: "Dial failed: \(resp.errorMessage ?? "Error")"])
        }
        let record = CallRecord(id: 1, direction: .outgoing, status: .dialing, phoneNumber: clean, startedAt: Date())
        activeCalls = [record]
    }
    
    public func answerCall() async throws {
        appendLog("[Call] Answering incoming call...")
        let resp = try await executeAT("ATA", timeout: 5.0)
        guard resp.isOK else {
            throw NSError(domain: "EC20Controller", code: -6, userInfo: [NSLocalizedDescriptionKey: "Answer failed: \(resp.errorMessage ?? "Error")"])
        }
        incomingCallAlert = nil
        if let idx = activeCalls.firstIndex(where: { $0.status == .ringingIncoming }) {
            activeCalls[idx].status = .active
            activeCalls[idx].startedAt = Date()
            await onCallStarted?()
        }
    }
    
    public func hangupCall() async throws {
        appendLog("[Call] Hanging up call...")
        _ = try? await executeAT("ATH", timeout: 5.0)
        incomingCallAlert = nil
        activeCalls.removeAll()
        await onCallEnded?()
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
                    let num = parts[5].replacingOccurrences(of: "\"", with: "")
                    
                    let dir: CallDirection = (dirInt == 0) ? .outgoing : .incoming
                    let status: CallStatus
                    switch statInt {
                    case 0: status = .active
                    case 1: status = .held
                    case 2: status = .dialing
                    case 3: status = .dialing // alerting
                    case 4: status = .ringingIncoming
                    case 5: status = .ringingIncoming // waiting
                    default: status = .ended
                    }
                    currentActive.append(CallRecord(id: id, direction: dir, status: status, phoneNumber: num, startedAt: Date()))
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
                incomingCallAlert = "Incoming Call..."
            }
        case .incomingCall(let caller):
            if let number = caller {
                incomingCallAlert = "Incoming Call: \(SensitiveMasker.mask(phoneNumber: number))"
                let call = CallRecord(id: 1, direction: .incoming, status: .ringingIncoming, phoneNumber: number)
                activeCalls = [call]
            }
        case .callEnded(let reason):
            incomingCallAlert = nil
            activeCalls.removeAll()
            await onCallEnded?()
            appendLog("[Call] Ended: \(reason)")
        case .incomingSMS(let storage, let index):
            appendLog("[SMS] New incoming message at \(storage)[\(index)]")
            await loadSMSMessages()
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
    }
    
    private func stopTimers() {
        callPollingTimer?.invalidate()
        callPollingTimer = nil
        signalPollingTimer?.invalidate()
        signalPollingTimer = nil
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
