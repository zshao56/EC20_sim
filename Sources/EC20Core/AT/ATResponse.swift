import Foundation

public struct ATResponse: Equatable, Sendable {
    public let rawLines: [String]
    public let isOK: Bool
    public let isError: Bool
    public let errorMessage: String?
    
    public init(rawLines: [String]) {
        self.rawLines = rawLines
        var ok = false
        var error = false
        var errMsg: String? = nil
        
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "OK" {
                ok = true
            } else if trimmed == "ERROR" || trimmed == "NO CARRIER" || trimmed == "BUSY" || trimmed == "NO DIALTONE" {
                error = true
                errMsg = trimmed
            } else if trimmed.hasPrefix("+CME ERROR:") {
                error = true
                errMsg = trimmed
            } else if trimmed.hasPrefix("+CMS ERROR:") {
                error = true
                errMsg = trimmed
            }
        }
        
        self.isOK = ok && !error
        self.isError = error
        self.errorMessage = errMsg
    }
    
    public var dataLines: [String] {
        rawLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if trimmed == "OK" || trimmed == "ERROR" || trimmed == "NO CARRIER" || trimmed == "BUSY" {
                return false
            }
            if trimmed.hasPrefix("+CME ERROR:") || trimmed.hasPrefix("+CMS ERROR:") {
                return false
            }
            return true
        }
    }
}
