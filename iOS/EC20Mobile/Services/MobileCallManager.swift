import Foundation
import CallKit
import Combine
import EC20BridgeProtocol

@MainActor
public final class MobileCallManager: NSObject, ObservableObject, CXProviderDelegate {
    public static let shared = MobileCallManager()

    private var provider: CXProvider?
    private let callController = CXCallController()
    private var currentCallUUID: UUID?

    public override init() {
        super.init()
        let config = CXProviderConfiguration(localizedName: "EC20 互联")
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber]

        let prov = CXProvider(configuration: config)
        prov.setDelegate(self, queue: .main)
        self.provider = prov
    }

    public func reportIncomingCall(caller: String, contactName: String?) {
        guard currentCallUUID == nil else { return }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: caller)
        update.localizedCallerName = contactName ?? caller
        update.hasVideo = false

        let callUUID = UUID()
        currentCallUUID = callUUID
        provider?.reportNewIncomingCall(with: callUUID, update: update) { error in
            if let error = error {
                print("CallKit reportNewIncomingCall error: \(error)")
                Task { @MainActor in
                    if self.currentCallUUID == callUUID {
                        self.currentCallUUID = nil
                    }
                }
            }
        }
    }

    public func reportCallEnded() {
        guard let callUUID = currentCallUUID else { return }
        provider?.reportCall(with: callUUID, endedAt: Date(), reason: .remoteEnded)
        currentCallUUID = nil
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        currentCallUUID = nil
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MobileGatewayClient.shared.answerCall()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MobileGatewayClient.shared.hangupCall()
        currentCallUUID = nil
        action.fulfill()
    }
}
