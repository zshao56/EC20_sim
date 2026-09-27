import Foundation

public enum BridgeFramingError: Error, LocalizedError, Equatable {
    case frameTooLarge(size: UInt32, max: Int)
    case malformedLengthHeader

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size, let max):
            return "帧大小 (\(size) 字节) 超过最大允许限制 (\(max) 字节)"
        case .malformedLengthHeader:
            return "帧长度头部数据异常"
        }
    }
}

public struct BridgeFraming: Sendable {
    public static let defaultMaxFrameSize: Int = 2 * 1024 * 1024 // 2 MB

    /// Encodes arbitrary payload bytes into a length-prefixed frame (4-byte big-endian length + payload)
    public static func encode(_ data: Data) -> Data {
        var frame = Data()
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { ptr in
            frame.append(contentsOf: ptr)
        }
        frame.append(data)
        return frame
    }

    /// Attempts to extract one complete frame from incoming buffer stream.
    /// Returns extracted frame Data if ready, or nil if buffer is incomplete.
    /// Throws BridgeFramingError if frame header indicates an oversized frame.
    public static func decode(
        from buffer: inout Data,
        maxFrameSize: Int = defaultMaxFrameSize
    ) throws -> Data? {
        guard buffer.count >= 4 else {
            return nil
        }

        let length: UInt32 = buffer.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: 0, as: UInt32.self).bigEndian
        }

        guard Int(length) <= maxFrameSize else {
            // Buffer is invalid/malicious; clear buffer to avoid infinite error loop
            buffer.removeAll()
            throw BridgeFramingError.frameTooLarge(size: length, max: maxFrameSize)
        }

        let totalNeeded = 4 + Int(length)
        guard buffer.count >= totalNeeded else {
            // Wait for remaining packet data
            return nil
        }

        let payload = buffer.subdata(in: 4..<totalNeeded)
        buffer.removeSubrange(0..<totalNeeded)
        return payload
    }
}
