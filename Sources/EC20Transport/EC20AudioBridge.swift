import Foundation
import AudioToolbox
import CLibUSB
import EC20Core

/// Wrapper to make OpaquePointer safe under Swift 6 concurrency
public struct SafeDevicePointer: @unchecked Sendable {
    public let pointer: OpaquePointer
    public init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }
}

public enum AudioBridgeState: String, Sendable {
    case stopped = "Stopped"
    case starting = "Starting..."
    case streaming = "Active (Bidirectional 8kHz PCM)"
    case loopbackTest = "Loopback Self-Test Mode"
    case error = "Error"
}

public final class EC20AudioBridge: @unchecked Sendable {
    public private(set) var state: AudioBridgeState = .stopped
    public private(set) var lastErrorMessage: String? = nil
    
    // USB Interface 1 details (GNSS/NMEA port used for PCM)
    private let interfaceIndex: Int32 = 1
    private let epOut: UInt8 = 0x02
    private let epIn: UInt8 = 0x82
    
    // Buffer sizing per Quectel Voice over USB specification:
    // Read: 640 bytes per 40ms (320 samples @ 16-bit mono 8kHz)
    // Write: 1600 bytes per 100ms (800 samples @ 16-bit mono 8kHz)
    private let readChunkSize = 640
    private let writeChunkSize = 1600
    
    // CoreAudio Output Buffer Pool (Pre-allocated, fixed bounded pool)
    private let kNumOutputBuffers = 8
    private let outputBufferCapacity = 1600
    private let outputBufferLock = NSLock()
    private var freeOutputBuffers: [AudioQueueBufferRef] = []
    private var allocatedOutputBuffers: [AudioQueueBufferRef] = []
    
    // CoreAudio Input Queue
    private var inputQueue: AudioQueueRef?
    private var outputQueue: AudioQueueRef?
    
    private var isRunning: Bool = false
    private var isLoopback: Bool = false
    private var activeDeviceHandle: OpaquePointer?
    
    // Threads synchronization
    private let threadsDispatchGroup = DispatchGroup()
    private var usbReadThread: Thread?
    private var usbWriteThread: Thread?
    
    // Bounded outgoing PCM buffer (Cap at 1 second = 16000 bytes)
    private let maxOutgoingBufferSize = 16000
    private let writeBufferLock = NSLock()
    private var outgoingPCMData = Data()
    
    private var stateChangeHandler: (@Sendable (AudioBridgeState, String?) -> Void)?
    
    public init() {}
    
    deinit {
        stop()
    }
    
    public func setStateChangeHandler(_ handler: @escaping @Sendable (AudioBridgeState, String?) -> Void) {
        self.stateChangeHandler = handler
    }
    
    private func updateState(_ newState: AudioBridgeState, error: String? = nil) {
        self.state = newState
        self.lastErrorMessage = error
        stateChangeHandler?(newState, error)
    }
    
    // MARK: - Start & Stop Bridge
    
    /// Starts bidirectional audio bridge over USB Interface 1 connected with macOS CoreAudio
    public func start(deviceHandle: OpaquePointer?, loopbackOnly: Bool = false) {
        guard !isRunning else { return }
        self.isLoopback = loopbackOnly
        self.activeDeviceHandle = deviceHandle
        self.isRunning = true
        updateState(.starting)
        
        do {
            if !loopbackOnly {
                guard let handle = deviceHandle else {
                    throw NSError(domain: "EC20AudioBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "No USB device handle provided"])
                }
                
                // Claim Interface 1 (GNSS/NMEA)
                let claimRes = libusb_claim_interface(handle, interfaceIndex)
                if claimRes != 0 {
                    throw NSError(domain: "EC20AudioBridge", code: Int(claimRes), userInfo: [NSLocalizedDescriptionKey: "libusb_claim_interface(1) failed with code \(claimRes)"])
                }
            }
            
            // Setup CoreAudio AudioQueue for Input (Microphone) and Output (Speaker)
            try setupCoreAudioQueues()
            
            if !loopbackOnly {
                // Start USB bulk threads
                startUSBReadLoop()
                startUSBWriteLoop()
            }
            
            updateState(loopbackOnly ? .loopbackTest : .streaming)
        } catch {
            stop()
            updateState(.error, error: error.localizedDescription)
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        // 1. Stop CoreAudio Queues first to stop producing input and playing output
        if let inQ = inputQueue {
            AudioQueueStop(inQ, true)
            AudioQueueDispose(inQ, true)
            inputQueue = nil
        }
        if let outQ = outputQueue {
            AudioQueueStop(outQ, true)
            AudioQueueDispose(outQ, true)
            outputQueue = nil
        }
        
        // 2. Wait for USB read/write threads to finish their in-flight transfers and exit
        _ = threadsDispatchGroup.wait(timeout: .now() + 1.0)
        
        // 3. Now that threads have exited and are no longer using the handle, release Interface 1
        if !isLoopback, let handle = activeDeviceHandle {
            libusb_release_interface(handle, interfaceIndex)
        }
        activeDeviceHandle = nil
        
        // 4. Clean up audio output buffer tracking
        outputBufferLock.lock()
        freeOutputBuffers.removeAll()
        allocatedOutputBuffers.removeAll()
        outputBufferLock.unlock()
        
        // 5. Clean up outgoing PCM data
        writeBufferLock.lock()
        outgoingPCMData.removeAll()
        writeBufferLock.unlock()
        
        updateState(.stopped)
    }
    
    // MARK: - CoreAudio AudioQueue Setup
    
    private func setupCoreAudioQueues() throws {
        // Linear PCM 8000 Hz, 16-bit Signed Integer, Mono
        var format = AudioStreamBasicDescription(
            mSampleRate: 8000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        // 1. Output Queue (Speaker)
        let outStatus = AudioQueueNewOutput(&format, audioQueueOutputCallback, selfPointer, nil, nil, 0, &outputQueue)
        guard outStatus == noErr, let outQueue = outputQueue else {
            throw NSError(domain: "EC20AudioBridge", code: Int(outStatus), userInfo: [NSLocalizedDescriptionKey: "AudioQueueNewOutput failed (\(outStatus))"])
        }
        
        // Pre-allocate fixed pool of output buffers
        outputBufferLock.lock()
        freeOutputBuffers.removeAll()
        allocatedOutputBuffers.removeAll()
        for _ in 0..<kNumOutputBuffers {
            var buf: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(outQueue, UInt32(outputBufferCapacity), &buf)
            if allocStatus == noErr, let buf = buf {
                allocatedOutputBuffers.append(buf)
                freeOutputBuffers.append(buf)
            }
        }
        outputBufferLock.unlock()
        AudioQueueStart(outQueue, nil)
        
        // 2. Input Queue (Microphone)
        let inStatus = AudioQueueNewInput(&format, audioQueueInputCallback, selfPointer, nil, nil, 0, &inputQueue)
        guard inStatus == noErr, let inQueue = inputQueue else {
            throw NSError(domain: "EC20AudioBridge", code: Int(inStatus), userInfo: [NSLocalizedDescriptionKey: "AudioQueueNewInput failed (\(inStatus))"])
        }
        
        // Allocate 3 input buffers (320 bytes = 20ms each)
        for _ in 0..<3 {
            var buf: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(inQueue, 320, &buf)
            if let buf = buf {
                AudioQueueEnqueueBuffer(inQueue, buf, 0, nil)
            }
        }
        AudioQueueStart(inQueue, nil)
    }
    
    // MARK: - CoreAudio Callbacks
    
    fileprivate func handleMicrophoneInput(buffer: AudioQueueBufferRef) {
        guard isRunning else { return }
        let bytesCount = Int(buffer.pointee.mAudioDataByteSize)
        guard bytesCount > 0 else { return }
        
        if isLoopback {
            // Loopback self-test: directly play mic input on output queue
            playPCMToSpeaker(pointer: buffer.pointee.mAudioData, length: bytesCount)
            return
        }
        
        // Enqueue to outgoing PCM data with strict upper bound (drop oldest on overflow)
        let rawPointer = buffer.pointee.mAudioData.bindMemory(to: UInt8.self, capacity: bytesCount)
        writeBufferLock.lock()
        if outgoingPCMData.count + bytesCount > maxOutgoingBufferSize {
            let overflow = (outgoingPCMData.count + bytesCount) - maxOutgoingBufferSize
            let dropCount = min(overflow, outgoingPCMData.count)
            outgoingPCMData.removeSubrange(0..<dropCount)
        }
        outgoingPCMData.append(rawPointer, count: bytesCount)
        writeBufferLock.unlock()
    }
    
    public func playPCMToSpeaker(pointer: UnsafeRawPointer, length: Int) {
        guard let outQ = outputQueue, isRunning, length > 0 else { return }
        
        outputBufferLock.lock()
        let bufferToUse = freeOutputBuffers.isEmpty ? nil : freeOutputBuffers.removeFirst()
        outputBufferLock.unlock()
        
        // If all pre-allocated buffers are currently in flight, drop the frame to prevent latency build-up
        guard let buf = bufferToUse else {
            return
        }
        
        let copyLen = min(length, Int(buf.pointee.mAudioDataBytesCapacity))
        memcpy(buf.pointee.mAudioData, pointer, copyLen)
        buf.pointee.mAudioDataByteSize = UInt32(copyLen)
        AudioQueueEnqueueBuffer(outQ, buf, 0, nil)
    }
    
    fileprivate func recycleOutputBuffer(_ buffer: AudioQueueBufferRef) {
        outputBufferLock.lock()
        freeOutputBuffers.append(buffer)
        outputBufferLock.unlock()
    }
    
    // MARK: - USB Streaming Loops
    
    private func startUSBReadLoop() {
        threadsDispatchGroup.enter()
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            defer { self.threadsDispatchGroup.leave() }
            
            var buffer = [UInt8](repeating: 0, count: self.readChunkSize)
            
            while self.isRunning {
                guard let handle = self.activeDeviceHandle else { break }
                var transferred: Int32 = 0
                
                let res = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(handle, self.epIn, ptr.baseAddress, Int32(ptr.count), &transferred, 100)
                }
                
                if res == 0 && transferred > 0 {
                    // Feed received PCM audio into macOS speaker
                    buffer.withUnsafeBytes { rawPtr in
                        if let base = rawPtr.baseAddress {
                            self.playPCMToSpeaker(pointer: base, length: Int(transferred))
                        }
                    }
                } else if res == -7 {
                    // Timeout (LIBUSB_ERROR_TIMEOUT): expected when waiting for next frame
                    continue
                } else if res != 0 {
                    // Device disconnected or fatal transfer failure
                    break
                }
            }
        }
        thread.name = "EC20AudioReadThread"
        thread.start()
        self.usbReadThread = thread
    }
    
    private func startUSBWriteLoop() {
        threadsDispatchGroup.enter()
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            defer { self.threadsDispatchGroup.leave() }
            
            while self.isRunning {
                guard let handle = self.activeDeviceHandle else { break }
                
                var chunkToSend: Data? = nil
                self.writeBufferLock.lock()
                if self.outgoingPCMData.count >= self.writeChunkSize {
                    chunkToSend = self.outgoingPCMData.prefix(self.writeChunkSize)
                    self.outgoingPCMData.removeSubrange(0..<self.writeChunkSize)
                }
                self.writeBufferLock.unlock()
                
                if let data = chunkToSend {
                    var buffer = Array(data)
                    var transferred: Int32 = 0
                    let res = buffer.withUnsafeMutableBufferPointer { ptr in
                        libusb_bulk_transfer(handle, self.epOut, ptr.baseAddress, Int32(ptr.count), &transferred, 200)
                    }
                    
                    if res == 0 {
                        if transferred < Int32(data.count) {
                            // Partial transfer: re-insert unsent bytes at head of outgoingPCMData
                            let remaining = data.dropFirst(Int(transferred))
                            self.writeBufferLock.lock()
                            self.outgoingPCMData.insert(contentsOf: remaining, at: 0)
                            self.writeBufferLock.unlock()
                        }
                    } else if res == -7 {
                        // Timeout (LIBUSB_ERROR_TIMEOUT): keep unsent chunk for retry
                        self.writeBufferLock.lock()
                        self.outgoingPCMData.insert(contentsOf: data, at: 0)
                        self.writeBufferLock.unlock()
                    } else {
                        // Fatal USB error (LIBUSB_ERROR_NO_DEVICE, LIBUSB_ERROR_PIPE, etc.)
                        break
                    }
                } else {
                    // Wait for microphone data accumulation
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        thread.name = "EC20AudioWriteThread"
        thread.start()
        self.usbWriteThread = thread
    }
}

// MARK: - Global C-Function AudioQueue Callbacks

private func audioQueueInputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
    inStartTime: UnsafePointer<AudioTimeStamp>,
    inNumberPacketDescriptions: UInt32,
    inPacketDescs: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData = inUserData else { return }
    let bridge = Unmanaged<EC20AudioBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.handleMicrophoneInput(buffer: inBuffer)
    
    // Re-enqueue buffer for next audio recording
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
}

private func audioQueueOutputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef
) {
    guard let userData = inUserData else { return }
    let bridge = Unmanaged<EC20AudioBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.recycleOutputBuffer(inBuffer)
}
