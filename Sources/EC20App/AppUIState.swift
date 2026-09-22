import SwiftUI
import Combine
import EC20Core

@MainActor
public final class AppUIState: ObservableObject {
    @Published public var selectedSection: NavigationSection = .dashboard
    @Published public var useSimulation: Bool = false
    
    // Call UI State
    @Published public var dialNumber: String = ""
    @Published public var callErrorMessage: String? = nil
    
    // SMS UI State
    @Published public var selectedMessage: SMSMessage? = nil
    @Published public var isShowingComposeSheet: Bool = false
    @Published public var composeRecipient: String = ""
    @Published public var composeText: String = ""
    @Published public var isSendingSMS: Bool = false
    @Published public var sendSMSError: String? = nil
    @Published public var sendSMSSuccess: Bool = false
    
    // AT Console State
    @Published public var customCommand: String = ""
    
    public init() {}
}
