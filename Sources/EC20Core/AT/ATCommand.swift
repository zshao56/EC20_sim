import Foundation

public struct ATCommand: Sendable {
    public let raw: String
    public let timeoutSeconds: TimeInterval
    public let customTerminator: String?
    
    public init(raw: String, timeoutSeconds: TimeInterval = 3.0, customTerminator: String? = nil) {
        self.raw = raw
        self.timeoutSeconds = timeoutSeconds
        self.customTerminator = customTerminator
    }
    
    public static func basic(_ cmd: String, timeout: TimeInterval = 3.0) -> ATCommand {
        ATCommand(raw: cmd, timeoutSeconds: timeout)
    }
}
