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
        qpcmvSupported: Bool = true,
        qpcmvCurrentSetting: String = "0,0",
        qdaiSetting: String? = "3,0,0,4,0,0,1,1",
        pcmInterfaceIndex: Int = 1,
        pcmOutEndpoint: UInt8 = 0x02,
        pcmInEndpoint: UInt8 = 0x82,
        pcmFormatDescription: String = "8000 Hz, 16-bit Linear PCM, Mono (320 bytes per 20ms frame)",
        callSignalingStatus: String = "Signaling Operational (ATD/ATA/ATH/CLCC/CLIP)",
        systemAudioBridgeStatus: String = "Not Bridged to macOS CoreAudio",
        technicalConclusion: String = """
            1. USB Audio Class (UAC): Not exposed in current USB descriptor (VID:PID 2c7c:0125). No standard macOS audio input/output device is present.
            2. Voice over USB (Raw PCM): Fully supported by EC20 hardware via Interface 1 (GNSS/NMEA port, EP 0x02/0x82) with command AT+QPCMV=1,0.
            3. Call Control vs Audio: Call signaling (dialing, incoming alert, answer, hangup, CLCC) operates independently over AT Interface 2.
            4. Bridge Conclusion: Full bidirectional voice requires a userspace PCM audio pump or CoreAudio HAL Virtual Driver to stream the raw PCM frames between Interface 1 and macOS microphones/speakers.
            """
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
