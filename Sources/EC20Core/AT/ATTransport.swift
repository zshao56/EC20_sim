import Foundation

public protocol ATTransport: AnyObject, Sendable {
    var isConnected: Bool { get }
    var transportName: String { get }
    var rawDeviceHandle: OpaquePointer? { get }
    
    func open() throws
    func close()
    func send(raw: String) async throws
    
    /// Register incoming raw string callback (lines and prompts)
    func setIncomingHandler(_ handler: @escaping @Sendable (String) -> Void)
}

public extension ATTransport {
    var rawDeviceHandle: OpaquePointer? { nil }
}
