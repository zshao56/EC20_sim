import Foundation

public struct AudioBridgeAssessment: Equatable, Sendable {
    public let uacDeviceDetected: Bool
    public let qpcmvSupported: Bool
    public let qpcmvCurrentSetting: String
    public let qdaiSetting: String?
    public let pcmInterfaceIndex: Int
    public let pcmOutEndpoint: UInt8
    public let pcmInEndpoint: UInt8
    public let pcmFormatDescription: String
    public let callSignalingStatus: String
    public let systemAudioBridgeStatus: String
    public let technicalConclusion: String
    
    public init(
        uacDeviceDetected: Bool = false,
        qpcmvSupported: Bool = false,
        qpcmvCurrentSetting: String = "Unknown",
        qdaiSetting: String? = nil,
        pcmInterfaceIndex: Int = 1,
        pcmOutEndpoint: UInt8 = 0x02,
        pcmInEndpoint: UInt8 = 0x82,
        pcmFormatDescription: String = "8000 Hz, signed 16-bit mono (640 bytes/40ms down, 1600 bytes/100ms up)",
        callSignalingStatus: String = "AT call commands implemented; live call unverified",
        systemAudioBridgeStatus: String = "CoreAudio bridge implemented; live audio unverified",
        technicalConclusion: String = "Voice over USB capability has not yet been queried on this connection."
    ) {
        self.uacDeviceDetected = uacDeviceDetected
        self.qpcmvSupported = qpcmvSupported
        self.qpcmvCurrentSetting = qpcmvCurrentSetting
        self.qdaiSetting = qdaiSetting
        self.pcmInterfaceIndex = pcmInterfaceIndex
        self.pcmOutEndpoint = pcmOutEndpoint
        self.pcmInEndpoint = pcmInEndpoint
        self.pcmFormatDescription = pcmFormatDescription
        self.callSignalingStatus = callSignalingStatus
        self.systemAudioBridgeStatus = systemAudioBridgeStatus
        self.technicalConclusion = technicalConclusion
    }
}
