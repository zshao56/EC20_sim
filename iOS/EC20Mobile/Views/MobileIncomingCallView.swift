import SwiftUI
import EC20BridgeProtocol

@MainActor
public struct MobileIncomingCallView: View {
    public let activeCall: BridgeActiveCallDTO
    @ObservedObject var client = MobileGatewayClient.shared

    public init(activeCall: BridgeActiveCallDTO) {
        self.activeCall = activeCall
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Avatar & Info
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 96, height: 96)
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.white.opacity(0.9))
                    }

                    VStack(spacing: 6) {
                        Text(activeCall.contactName ?? activeCall.phoneNumber)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)

                        if activeCall.contactName != nil {
                            Text(activeCall.phoneNumber)
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.8))
                        }

                        if let attr = activeCall.attribution, !attr.isEmpty, attr != "未知" {
                            Text(attr)
                                .font(.subheadline.bold())
                                .foregroundColor(.yellow.opacity(0.9))
                        }

                        Text(activeCall.status == "ringing" ? "蜂窝网络来电中..." : "通话中")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 4)
                    }
                }

                Spacer()

                // Actions: Answer & Hangup
                HStack(spacing: 80) {
                    // Hangup / Decline
                    Button(action: {
                        client.hangupCall()
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 72, height: 72)
                                Image(systemName: "phone.down.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("拒绝")
                                .font(.subheadline)
                                .foregroundColor(.white)
                        }
                    }

                    // Answer
                    if activeCall.status == "ringing" {
                        Button(action: {
                            client.answerCall()
                        }) {
                            VStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 72, height: 72)
                                    Image(systemName: "phone.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                }
                                Text("接听")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                .padding(.bottom, 60)
            }
        }
    }
}
