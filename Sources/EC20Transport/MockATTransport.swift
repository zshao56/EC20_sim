import Foundation
import EC20Core

public final class MockATTransport: ATTransport, @unchecked Sendable {
    public let transportName = "Mock AT Transport (Simulation Mode)"
    public private(set) var isConnected: Bool = false
    
    private var incomingHandler: (@Sendable (String) -> Void)? = nil
    private let lock = NSLock()
    
    private var isAwaitingSMSData: Bool = false
    public private(set) var lastSMSPayloadHadCRLF = false
    private var activeCalls: [String] = []
    
    public init() {}
    
    public func setIncomingHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.incomingHandler = handler
        lock.unlock()
    }
    
    public func open() throws {
        lock.lock()
        isConnected = true
        lock.unlock()
    }
    
    public func close() {
        lock.lock()
        isConnected = false
        lock.unlock()
    }
    
    public func send(raw: String) async throws {
        guard isConnected else {
            throw NSError(domain: "MockATTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mock transport disconnected"])
        }
        
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle SMS prompt input
        if isAwaitingSMSData {
            if raw.contains("\u{1A}") || raw.contains("\u{1B}") {
                lastSMSPayloadHadCRLF = raw.hasSuffix("\r\n")
                isAwaitingSMSData = false
                try? await Task.sleep(nanoseconds: 200_000_000)
                incomingHandler?("+CMGS: 42")
                incomingHandler?("OK")
                return
            }
        }
        
        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms simulated modem latency
        
        if trimmed == "ATE0" || trimmed == "ATE1" || trimmed == "AT" {
            incomingHandler?("OK")
        } else if trimmed == "ATI" {
            incomingHandler?("Quectel")
            incomingHandler?("EC20F")
            incomingHandler?("Revision: EC20CEHDLGR08A02M1G")
            incomingHandler?("OK")
        } else if trimmed == "AT+CPIN?" {
            incomingHandler?("+CPIN: READY")
            incomingHandler?("OK")
        } else if trimmed == "AT+CREG?" {
            incomingHandler?("+CREG: 0,1")
            incomingHandler?("OK")
        } else if trimmed == "AT+CEREG?" {
            incomingHandler?("+CEREG: 0,1")
            incomingHandler?("OK")
        } else if trimmed == "AT+CSQ" {
            incomingHandler?("+CSQ: 25,99")
            incomingHandler?("OK")
        } else if trimmed == "AT+COPS?" {
            incomingHandler?("+COPS: 0,0,\"CHN-UNICOM\",7")
            incomingHandler?("OK")
        } else if trimmed == "AT+QCCID" {
            incomingHandler?("+QCCID: 89860401123456789012")
            incomingHandler?("OK")
        } else if trimmed == "AT+CIMI" {
            incomingHandler?("460011234567890")
            incomingHandler?("OK")
        } else if trimmed == "AT+GSN" {
            incomingHandler?("867543021234567")
            incomingHandler?("OK")
        } else if trimmed.hasPrefix("AT+CMGF=") {
            incomingHandler?("OK")
        } else if trimmed.hasPrefix("AT+CSCS=") {
            incomingHandler?("OK")
        } else if trimmed == "AT+CPMS?" {
            incomingHandler?("+CPMS: \"ME\",2,255,\"ME\",2,255,\"ME\",2,255")
            incomingHandler?("OK")
        } else if trimmed.hasPrefix("AT+CPMS=") {
            incomingHandler?("+CPMS: 2,255,2,255,2,255")
            incomingHandler?("OK")
        } else if trimmed.hasPrefix("AT+CMGL=") {
            incomingHandler?("+CMGL: 1,1,,35")
            incomingHandler?("0891683108200005F0040D91683108000000F000006290220202022304D4F29C0E")
            incomingHandler?("OK")
        } else if trimmed.hasPrefix("AT+CMGS=") {
            isAwaitingSMSData = true
            incomingHandler?("> ")
        } else if trimmed.hasPrefix("ATD") {
            // Dialing
            activeCalls = ["1,0,0,0,0,\"10010\",129"]
            incomingHandler?("OK")
        } else if trimmed == "ATA" {
            // Answer
            activeCalls = ["1,0,0,0,0,\"13800138000\",129"]
            incomingHandler?("OK")
        } else if trimmed == "ATH" {
            // Hangup
            activeCalls.removeAll()
            incomingHandler?("OK")
            incomingHandler?("NO CARRIER")
        } else if trimmed == "AT+CLCC" {
            for call in activeCalls {
                incomingHandler?("+CLCC: \(call)")
            }
            incomingHandler?("OK")
        } else if trimmed == "AT+QPCMV=?" {
            incomingHandler?("+QPCMV: (0,1),(0-2)")
            incomingHandler?("OK")
        } else if trimmed == "AT+QPCMV?" {
            incomingHandler?("+QPCMV: 0,0")
            incomingHandler?("OK")
        } else if trimmed == "AT+QDAI=?" {
            incomingHandler?("+QDAI: (1-7,10,11),(0,1),(0,1),(0-5),(0-2),(0,1),(1),(1-16)")
            incomingHandler?("OK")
        } else if trimmed == "AT+QDAI?" {
            incomingHandler?("+QDAI: 3,0,0,4,0,0,1,1")
            incomingHandler?("OK")
        } else if trimmed == "AT+QAUDMOD=?" {
            incomingHandler?("+QAUDMOD: (0-5)")
            incomingHandler?("OK")
        } else if trimmed == "AT+QAUDMOD?" {
            incomingHandler?("+QAUDMOD: 0")
            incomingHandler?("OK")
        } else {
            incomingHandler?("OK")
        }
    }
    
    // MARK: - Simulation Triggers
    
    public func simulateIncomingCall(number: String) {
        incomingHandler?("RING")
        incomingHandler?("+CLIP: \"\(number)\",129,,,,0")
    }
    
    public func simulateIncomingSMS(storage: String = "ME", index: Int = 3) {
        incomingHandler?("+CMTI: \"\(storage)\",\(index)")
    }
}
