import SwiftUI
import EC20BridgeProtocol

@MainActor
public struct MobilePhoneView: View {
    @ObservedObject var appState = MobileAppState.shared
    @ObservedObject var client = MobileGatewayClient.shared

    @State private var dialNumber: String = ""
    @State private var selectedTab: Int = 0 // 0: Keypad, 1: Recents

    // Batch deletion for recents
    @State private var isSelectingCalls: Bool = false
    @State private var selectedCallIds: Set<String> = []
    @State private var showDeleteCallsAlert: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("拨号盘").tag(0)
                    Text("最近通话").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    keypadSection
                } else {
                    recentCallsSection
                }
            }
            .navigationTitle(selectedTab == 0 ? "电话" : "最近通话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedTab == 1 {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if isSelectingCalls {
                            Button("完成") {
                                isSelectingCalls = false
                                selectedCallIds.removeAll()
                            }
                        } else {
                            Button("选择") {
                                isSelectingCalls = true
                                selectedCallIds.removeAll()
                            }
                            .disabled(appState.callHistory.isEmpty)
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSelectingCalls {
                            Button(action: {
                                if !selectedCallIds.isEmpty {
                                    showDeleteCallsAlert = true
                                }
                            }) {
                                Text("删除(\(selectedCallIds.count))")
                                    .foregroundColor(.red)
                            }
                            .disabled(selectedCallIds.isEmpty)
                        } else {
                            Button(action: {
                                client.requestSync()
                            }) {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            .alert("确认批量删除 \(selectedCallIds.count) 条通话记录？", isPresented: $showDeleteCallsAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    client.deleteCallHistoryBatch(ids: Array(selectedCallIds))
                    selectedCallIds.removeAll()
                    isSelectingCalls = false
                }
            } message: {
                Text("将从 Mac 本地与模块记录彻底删除选中的通话历史，不可恢复。")
            }
        }
    }

    // MARK: - Keypad Section

    private var keypadSection: some View {
        VStack(spacing: 16) {
            Spacer()

            // Number Display
            HStack {
                Spacer()
                Text(dialNumber.isEmpty ? " " : dialNumber)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal)

                if !dialNumber.isEmpty {
                    Button(action: {
                        dialNumber.removeLast()
                    }) {
                        Image(systemName: "delete.left.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.trailing, 20)
                } else {
                    Spacer().frame(width: 44)
                }
            }
            .frame(height: 50)

            // Number Attribution Hint
            let attr = PhoneAttributionLookup.shared.lookup(dialNumber).displayString
            Text(!dialNumber.isEmpty && attr != "未知" ? attr : " ")
                .font(.caption)
                .foregroundColor(.secondary)

            // Keypad Grid (3x4)
            let keys: [[(String, String)]] = [
                [("1", ""), ("2", "ABC"), ("3", "DEF")],
                [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
                [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
                [("*", ""), ("0", "+"), ("#", "")]
            ]

            VStack(spacing: 12) {
                ForEach(0..<keys.count, id: \.self) { r in
                    HStack(spacing: 24) {
                        ForEach(0..<keys[r].count, id: \.self) { c in
                            let item = keys[r][c]
                            Button(action: {
                                dialNumber.append(item.0)
                            }) {
                                VStack(spacing: 2) {
                                    Text(item.0)
                                        .font(.system(size: 28, weight: .regular))
                                    if !item.1.isEmpty {
                                        Text(item.1)
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 76, height: 76)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Dial Call Button
                HStack {
                    Button(action: {
                        guard !dialNumber.isEmpty else { return }
                        client.dial(number: dialNumber)
                    }) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .frame(width: 76, height: 76)
                            .background(Color.green)
                            .clipShape(Circle())
                    }
                    .disabled(dialNumber.isEmpty)
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(.bottom, 20)
    }

    // MARK: - Recents Section

    private var recentCallsSection: some View {
        List {
            if appState.callHistory.isEmpty {
                Text("暂无最近通话记录")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(appState.callHistory) { item in
                    HStack(spacing: 12) {
                        if isSelectingCalls {
                            Button(action: {
                                if selectedCallIds.contains(item.id) {
                                    selectedCallIds.remove(item.id)
                                } else {
                                    selectedCallIds.insert(item.id)
                                }
                            }) {
                                Image(systemName: selectedCallIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedCallIds.contains(item.id) ? .accentColor : .secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        callIcon(for: item.type)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.contactName ?? item.phoneNumber)
                                .font(.headline)
                                .foregroundColor(item.type.lowercased() == "missed" ? .red : .primary)

                            HStack(spacing: 6) {
                                if let attr = item.attribution, !attr.isEmpty, attr != "未知" {
                                    Text(attr)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                if let ts = item.timestamp {
                                    Text("• \(Date(timeIntervalSince1970: ts).formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                if let dur = item.durationSeconds, dur > 0 {
                                    Text("• \(dur / 60)分\(dur % 60)秒")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if !isSelectingCalls {
                            Button(action: {
                                client.dial(number: item.phoneNumber)
                            }) {
                                Image(systemName: "phone.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.plain)
    }

    private func callIcon(for type: String) -> some View {
        Group {
            switch type.lowercased() {
            case "incoming":
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundColor(.blue)
            case "outgoing":
                Image(systemName: "phone.arrow.up.right.fill")
                    .foregroundColor(.green)
            case "missed":
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundColor(.red)
            default:
                Image(systemName: "phone.fill")
                    .foregroundColor(.secondary)
            }
        }
        .font(.subheadline)
    }
}
