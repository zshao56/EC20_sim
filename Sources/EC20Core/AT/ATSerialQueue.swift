import Foundation

public protocol ATQueueDelegate: AnyObject, Sendable {
    func didEncounterURC(_ event: URCEvent, raw: String)
}

public actor ATSerialQueue {
    private var isBusy: Bool = false
    private var pendingContinuation: CheckedContinuation<ATResponse, Error>?
    private var accumulatedLines: [String] = []
    private var activeTimeoutTask: Task<Void, Never>?
    
    public nonisolated let urcStream: AsyncStream<(URCEvent, String)>
    private let urcContinuation: AsyncStream<(URCEvent, String)>.Continuation
    
    public init() {
        var cont: AsyncStream<(URCEvent, String)>.Continuation!
        self.urcStream = AsyncStream { c in
            cont = c
        }
        self.urcContinuation = cont
    }
    
    /// Called when raw data/line is received from transport
    public func receiveLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Check if line is a URC
        if URCParser.isURC(trimmed) {
            if let event = URCParser.parse(trimmed) {
                urcContinuation.yield((event, trimmed))
            }
            // Some URCs like RING or NO CARRIER might arrive during or outside a command
            if pendingContinuation == nil {
                return
            }
        }
        
        // If an AT command is in flight, accumulate line
        if pendingContinuation != nil {
            accumulatedLines.append(trimmed)
            
            // Check terminal condition: "OK", "ERROR", "+CME ERROR: ...", "+CMS ERROR: ...", "> "
            if trimmed == "OK" ||
               trimmed == "ERROR" ||
               trimmed == "NO CARRIER" ||
               trimmed == "BUSY" ||
               trimmed.hasPrefix("+CME ERROR:") ||
               trimmed.hasPrefix("+CMS ERROR:") {
                
                activeTimeoutTask?.cancel()
                activeTimeoutTask = nil
                
                let response = ATResponse(rawLines: accumulatedLines)
                let cont = pendingContinuation
                pendingContinuation = nil
                accumulatedLines = []
                cont?.resume(returning: response)
            }
        }
    }
    
    /// Handle prompt for SMS PDU or text mode (e.g. "> ")
    public func receivePrompt() {
        if pendingContinuation != nil {
            accumulatedLines.append(">")
            activeTimeoutTask?.cancel()
            activeTimeoutTask = nil
            let response = ATResponse(rawLines: accumulatedLines)
            let cont = pendingContinuation
            pendingContinuation = nil
            accumulatedLines = []
            cont?.resume(returning: response)
        }
    }
    
    /// Executes a single AT command, waiting for completion or timeout
    public func execute(
        command: ATCommand,
        sendAction: @escaping @Sendable (String) async throws -> Void
    ) async throws -> ATResponse {
        while isBusy {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms wait
        }
        isBusy = true
        defer { isBusy = false }
        
        accumulatedLines = []
        
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation
            
            // Launch timeout task
            self.activeTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(command.timeoutSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.handleTimeout(for: command)
                } catch {}
            }
            
            // Send command
            Task { [weak self] in
                do {
                    try await sendAction(command.raw)
                } catch {
                    await self?.handleSendError(error)
                }
            }
        }
    }
    
    private func handleSendError(_ error: Error) {
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        let cont = pendingContinuation
        pendingContinuation = nil
        cont?.resume(throwing: error)
    }
    
    private func handleTimeout(for command: ATCommand) {
        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        let timeoutError = NSError(
            domain: "EC20SerialQueue",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "AT command '\(command.raw.trimmingCharacters(in: .whitespacesAndNewlines))' timed out after \(command.timeoutSeconds)s"]
        )
        cont.resume(throwing: timeoutError)
    }
}
