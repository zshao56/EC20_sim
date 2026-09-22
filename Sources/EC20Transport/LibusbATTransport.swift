import Foundation
import CLibUSB
import EC20Core

public final class LibusbATTransport: ATTransport, @unchecked Sendable {
    public let transportName = "libusb (Interface 2 / EP 0x03, 0x84)"
    
    public private(set) var isConnected: Bool = false
    
    private var usbContext: OpaquePointer? = nil
    private var deviceHandle: OpaquePointer? = nil
    private let targetVID: UInt16 = 0x2c7c
    private let targetPID: UInt16 = 0x0125
    private let interfaceNumber: Int32 = 2 // AT port as per Quectel USB guide
    private let epOut: UInt8 = 0x03
    private let epIn: UInt8 = 0x84
    
    private var isRunning: Bool = false
    private var readThread: Thread? = nil
    private var incomingHandler: (@Sendable (String) -> Void)? = nil
    private let lock = NSLock()
    
    public init() {}
    
    deinit {
        close()
    }
    
    public func setIncomingHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.incomingHandler = handler
        lock.unlock()
    }
    
    public func open() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isConnected else { return }
        
        var ctx: OpaquePointer? = nil
        let initRes = libusb_init(&ctx)
        guard initRes == 0 else {
            throw NSError(domain: "LibusbATTransport", code: Int(initRes), userInfo: [NSLocalizedDescriptionKey: "libusb_init failed with code \(initRes)"])
        }
        self.usbContext = ctx
        
        let handle = libusb_open_device_with_vid_pid(ctx, targetVID, targetPID)
        guard let handle = handle else {
            libusb_exit(ctx)
            self.usbContext = nil
            throw NSError(domain: "LibusbATTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "EC20 device (VID:0x2c7c PID:0x0125) not found or cannot be opened"])
        }
        self.deviceHandle = handle
        
        // Claim Interface 2 (AT port)
        let claimRes = libusb_claim_interface(handle, interfaceNumber)
        guard claimRes == 0 else {
            libusb_close(handle)
            libusb_exit(ctx)
            self.deviceHandle = nil
            self.usbContext = nil
            throw NSError(domain: "LibusbATTransport", code: Int(claimRes), userInfo: [NSLocalizedDescriptionKey: "libusb_claim_interface(\(interfaceNumber)) failed with code \(claimRes)"])
        }
        
        self.isConnected = true
        self.isRunning = true
        
        // Start background read thread
        startReadLoop()
    }
    
    public func close() {
        lock.lock()
        guard isConnected else {
            lock.unlock()
            return
        }
        self.isRunning = false
        self.isConnected = false
        
        let handle = self.deviceHandle
        let ctx = self.usbContext
        self.deviceHandle = nil
        self.usbContext = nil
        lock.unlock()
        
        if let handle = handle {
            libusb_release_interface(handle, interfaceNumber)
            libusb_close(handle)
        }
        if let ctx = ctx {
            libusb_exit(ctx)
        }
    }
    
    public func send(raw: String) async throws {
        guard isConnected, let handle = deviceHandle else {
            throw NSError(domain: "LibusbATTransport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Transport not connected"])
        }
        
        let data = Array(raw.utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                var transferred: Int32 = 0
                var buffer = data
                let res = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(handle, self.epOut, ptr.baseAddress, Int32(ptr.count), &transferred, 2000)
                }
                if res == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "LibusbATTransport",
                        code: Int(res),
                        userInfo: [NSLocalizedDescriptionKey: "libusb_bulk_transfer write error \(res)"]
                    ))
                }
            }
        }
    }
    
    private func startReadLoop() {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            var incomingBuffer = Data()
            
            while self.isRunning {
                guard let handle = self.deviceHandle else { break }
                var buffer = [UInt8](repeating: 0, count: 2048)
                var transferred: Int32 = 0
                
                let res = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(handle, self.epIn, ptr.baseAddress, Int32(ptr.count), &transferred, 200)
                }
                
                if res == 0 && transferred > 0 {
                    incomingBuffer.append(buffer, count: Int(transferred))
                    
                    // Check for SMS prompt "> "
                    if let stringSoFar = String(data: incomingBuffer, encoding: .ascii), stringSoFar.hasSuffix("> ") {
                        self.incomingHandler?("> ")
                        incomingBuffer.removeAll()
                        continue
                    }
                    
                    // Process complete lines delimited by \r\n or \n
                    while let range = incomingBuffer.range(of: Data([0x0A])) { // '\n'
                        let lineData = incomingBuffer.subdata(in: 0..<range.upperBound)
                        incomingBuffer.removeSubrange(0..<range.upperBound)
                        
                        if let line = String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .ascii) {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                self.incomingHandler?(trimmed)
                            }
                        }
                    }
                } else if res == -7 {
                    // LIBUSB_ERROR_TIMEOUT: Normal when no data is waiting, loop again
                    continue
                } else if res != 0 {
                    // Fatal or disconnection error
                    if self.isRunning {
                        self.incomingHandler?("URC_DISCONNECTED: \(res)")
                    }
                    break
                }
            }
        }
        thread.name = "EC20LibusbReadLoop"
        thread.start()
        self.readThread = thread
    }
}
