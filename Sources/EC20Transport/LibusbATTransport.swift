import Foundation
import CLibUSB
import EC20Core

public final class LibusbATTransport: ATTransport, @unchecked Sendable {
    public var transportName: String {
        "libusb (Interface \(interfaceNumber) / EP 0x0\(String(epOut, radix: 16)), 0x\(String(epIn, radix: 16)))"
    }

    public private(set) var isConnected: Bool = false

    private var usbContext: OpaquePointer? = nil
    private var deviceHandle: OpaquePointer? = nil
    private let targetVID: UInt16 = 0x2c7c
    private let targetPID: UInt16 = 0x0125

    // Dynamically detected
    private var interfaceNumber: Int32 = 2 // AT port default
    private var epOut: UInt8 = 0x03
    private var epIn: UInt8 = 0x84

    private var isRunning: Bool = false
    private var readThread: Thread? = nil
    private var incomingHandler: (@Sendable (String) -> Void)? = nil
    private var disconnectHandler: (@Sendable (String) -> Void)? = nil
    private let lock = NSLock()
    private let transferGroup = DispatchGroup()

    public init() {}

    deinit {
        close()
    }

    public func setIncomingHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.incomingHandler = handler
        lock.unlock()
    }

    public func setDisconnectHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock()
        self.disconnectHandler = handler
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

        // Try opening device, with short retry if recently rebooted
        var handle: OpaquePointer? = nil
        for _ in 0..<5 {
            handle = libusb_open_device_with_vid_pid(ctx, targetVID, targetPID)
            if handle != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let handle = handle else {
            libusb_exit(ctx)
            self.usbContext = nil
            throw NSError(domain: "LibusbATTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "EC20 device (VID:0x2c7c PID:0x0125) not found or cannot be opened"])
        }
        self.deviceHandle = handle

        // Dynamically discover AT interface & endpoints without touching CDC-ECM (classes 2, 10)
        discoverEndpoints(handle: handle)

        // Claim AT interface
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

    private func discoverEndpoints(handle: OpaquePointer) {
        let dev = libusb_get_device(handle)
        var configDesc: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(dev, &configDesc) == 0, let config = configDesc?.pointee else {
            return
        }
        defer { libusb_free_config_descriptor(configDesc) }

        // Look for AT interface (interface 2 or interface with bulk endpoints)
        for i in 0..<Int(config.bNumInterfaces) {
            let iface = config.interface[i]
            for a in 0..<Int(iface.num_altsetting) {
                let alt = iface.altsetting[a]
                // Never claim CDC-ECM interfaces
                if alt.bInterfaceClass == 2 || alt.bInterfaceClass == 10 {
                    continue
                }
                if alt.bInterfaceNumber == 2 {
                    self.interfaceNumber = 2
                    for e in 0..<Int(alt.bNumEndpoints) {
                        let ep = alt.endpoint[e]
                        let isBulk = (ep.bmAttributes & 0x03) == 2
                        if isBulk {
                            if (ep.bEndpointAddress & 0x80) == 0 {
                                self.epOut = ep.bEndpointAddress
                            } else {
                                self.epIn = ep.bEndpointAddress
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    public func close() {
        lock.lock()
        guard isConnected else {
            lock.unlock()
            return
        }
        self.isRunning = false
        self.isConnected = false

        lock.unlock()
        // Both endpoints share the handle. Let in-flight timed transfers exit first.
        transferGroup.wait()
        lock.lock()
        let handle = self.deviceHandle
        let ctx = self.usbContext
        let iface = self.interfaceNumber
        self.deviceHandle = nil
        self.usbContext = nil
        lock.unlock()

        if let handle = handle {
            libusb_release_interface(handle, iface)
            libusb_close(handle)
        }
        if let ctx = ctx {
            libusb_exit(ctx)
        }
    }

    public var rawDeviceHandle: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return deviceHandle
    }

    private func beginWrite() throws -> SafeDevicePointer {
        lock.lock()
        defer { lock.unlock() }
        guard isConnected, let handle = deviceHandle else {
            throw NSError(domain: "LibusbATTransport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Transport not connected"])
        }
        transferGroup.enter()
        return SafeDevicePointer(handle)
    }

    public func send(raw: String) async throws {
        let safeHandle = try beginWrite()
        let data = Array(raw.utf8)
        let outEp = self.epOut

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { transferGroup.leave() }
                var transferred: Int32 = 0
                var buffer = data
                let res = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(safeHandle.pointer, outEp, ptr.baseAddress, Int32(ptr.count), &transferred, 2000)
                }
                if res == 0 && transferred == Int32(buffer.count) {
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
        transferGroup.enter()
        let group = transferGroup
        let inEp = self.epIn
        let thread = Thread { [weak self] in
            defer { group.leave() }
            guard let self = self else { return }
            var incomingBuffer = Data()

            while true {
                self.lock.lock()
                let handle = self.isRunning ? self.deviceHandle : nil
                self.lock.unlock()
                guard let handle else { break }
                var buffer = [UInt8](repeating: 0, count: 2048)
                var transferred: Int32 = 0

                let res = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(handle, inEp, ptr.baseAddress, Int32(ptr.count), &transferred, 200)
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
                    // Fatal or disconnection error (device reboot, unplug, port reset)
                    self.lock.lock()
                    let wasRunning = self.isRunning
                    let handler = self.disconnectHandler
                    self.lock.unlock()
                    if wasRunning {
                        handler?("libusb bulk read error \(res)")
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
