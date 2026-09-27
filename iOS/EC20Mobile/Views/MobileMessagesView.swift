import SwiftUI
import EC20BridgeProtocol

@MainActor
public struct MobileMessagesView: View {
    @ObservedObject var appState = MobileAppState.shared
    @ObservedObject var client = MobileGatewayClient.shared

    @State private var selectedThreadId: String? = nil
    @State private var isSelectingThreads: Bool = false
    @State private var selectedThreadIds: Set<String> = []
    @State private var showDeleteThreadsAlert: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List(selection: $selectedThreadId) {
                ForEach(appState.conversations) { conv in
                    NavigationLink(value: conv.threadId) {
                        HStack(spacing: 12) {
                            if isSelectingThreads {
                                Button(action: {
                                    if selectedThreadIds.contains(conv.threadId) {
                                        selectedThreadIds.remove(conv.threadId)
                                    } else {
                                        selectedThreadIds.insert(conv.threadId)
                                    }
                                }) {
                                    Image(systemName: selectedThreadIds.contains(conv.threadId) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedThreadIds.contains(conv.threadId) ? .accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            // Avatar Circle
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                Text(String(conv.contactName?.first ?? conv.displayRecipient.first ?? "?"))
                                    .font(.headline)
                                    .foregroundColor(.accentColor)
                            }

                            // Thread Details
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(conv.contactName ?? conv.displayRecipient)
                                        .font(.headline)
                                        .lineLimit(1)

                                    if let attr = conv.attribution, !attr.isEmpty, attr != "未知" {
                                        Text("• \(attr)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Text(Date(timeIntervalSince1970: conv.latestTimestamp).formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                HStack {
                                    Text(conv.latestText)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)

                                    Spacer()

                                    if conv.unreadCount > 0 {
                                        Text("\(conv.unreadCount)")
                                            .font(.system(size: 11, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red)
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("信息")
            .navigationDestination(for: String.self) { threadId in
                MobileChatThreadView(threadId: threadId)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectingThreads {
                        Button("完成") {
                            isSelectingThreads = false
                            selectedThreadIds.removeAll()
                        }
                    } else {
                        Button("选择") {
                            isSelectingThreads = true
                            selectedThreadIds.removeAll()
                        }
                        .disabled(appState.conversations.isEmpty)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSelectingThreads {
                        Button(action: {
                            if !selectedThreadIds.isEmpty {
                                showDeleteThreadsAlert = true
                            }
                        }) {
                            Text("删除(\(selectedThreadIds.count))")
                                .foregroundColor(.red)
                        }
                        .disabled(selectedThreadIds.isEmpty)
                    } else {
                        Button(action: {
                            client.requestSync()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .alert("确认批量删除 \(selectedThreadIds.count) 个会话？", isPresented: $showDeleteThreadsAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    client.deleteThreadsBatch(threadIds: Array(selectedThreadIds))
                    selectedThreadIds.removeAll()
                    isSelectingThreads = false
                }
            } message: {
                Text("将彻底删除选中会话中的所有短信，此操作不可恢复。")
            }
        }
    }
}

@MainActor
public struct MobileChatThreadView: View {
    public let threadId: String
    @ObservedObject var appState = MobileAppState.shared
    @ObservedObject var client = MobileGatewayClient.shared

    @State private var inputText: String = ""
    @State private var isSelectingMessages: Bool = false
    @State private var selectedMessageIds: Set<String> = []
    @State private var showDeleteMessagesAlert: Bool = false

    public init(threadId: String) {
        self.threadId = threadId
    }

    public var body: some View {
        let conv = appState.conversations.first { $0.threadId == threadId }
        let msgs = appState.messages(for: threadId)
        let displayTitle = conv?.contactName ?? conv?.displayRecipient ?? threadId
        let attribution = conv?.attribution ?? PhoneAttributionLookup.shared.lookup(threadId).displayString

        VStack(spacing: 0) {
            // Header Info Bar
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.headline)
                    if !attribution.isEmpty && attribution != "未知" {
                        Text(attribution)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: {
                    client.dial(number: threadId)
                }) {
                    Image(systemName: "phone.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))

            Divider()

            // Message Bubble Scroll
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(msgs) { msg in
                            HStack(alignment: .bottom, spacing: 6) {
                                if isSelectingMessages {
                                    Button(action: {
                                        if selectedMessageIds.contains(msg.id) {
                                            selectedMessageIds.remove(msg.id)
                                        } else {
                                            selectedMessageIds.insert(msg.id)
                                        }
                                    }) {
                                        Image(systemName: selectedMessageIds.contains(msg.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selectedMessageIds.contains(msg.id) ? .accentColor : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.bottom, 6)
                                }

                                if !msg.isIncoming { Spacer(minLength: 40) }

                                VStack(alignment: msg.isIncoming ? .leading : .trailing, spacing: 3) {
                                    Text(msg.text)
                                        .font(.body)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(msg.isIncoming ? Color(.secondarySystemBackground) : Color.accentColor)
                                        .foregroundColor(msg.isIncoming ? .primary : .white)
                                        .cornerRadius(18)

                                    Text(Date(timeIntervalSince1970: msg.timestamp).formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }

                                if msg.isIncoming { Spacer(minLength: 40) }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: msgs.count) { _ in
                    if let last = msgs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input Bar
            HStack(spacing: 8) {
                TextField("发送短信...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(client.isSendingSMS)

                Button(action: {
                    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    client.sendSMS(destination: threadId, text: text)
                    inputText = ""
                }) {
                    if client.isSendingSMS {
                        ProgressView()
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(inputText.isEmpty ? .secondary : .accentColor)
                    }
                }
                .disabled(
                    inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    client.isSendingSMS
                )
            }
            .padding(10)
            .background(Color(.systemBackground))

            if let error = client.lastSMSSendError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelectingMessages {
                    HStack {
                        Button("删除(\(selectedMessageIds.count))") {
                            if !selectedMessageIds.isEmpty {
                                showDeleteMessagesAlert = true
                            }
                        }
                        .foregroundColor(.red)
                        .disabled(selectedMessageIds.isEmpty)

                        Button("完成") {
                            isSelectingMessages = false
                            selectedMessageIds.removeAll()
                        }
                    }
                } else {
                    Button("选择") {
                        isSelectingMessages = true
                        selectedMessageIds.removeAll()
                    }
                    .disabled(msgs.isEmpty)
                }
            }
        }
        .alert("确认批量删除 \(selectedMessageIds.count) 条短信？", isPresented: $showDeleteMessagesAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                client.deleteSMSBatch(ids: Array(selectedMessageIds))
                selectedMessageIds.removeAll()
                isSelectingMessages = false
            }
        } message: {
            Text("将从 Mac 数据库与模块存储彻底删除选中的短信，不可恢复。")
        }
    }
}
