import SwiftUI
import EC20Core
import EC20BridgeProtocol

@MainActor
public struct MessagesView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState

    @State private var threadMessages: [SMSMessage] = []

    // SMS Deletion State
    @State private var isShowingDeleteThreadAlert = false
    @State private var deleteErrorMessage: String? = nil
    @State private var messagePendingDeletion: SMSMessage? = nil
    @State private var isShowingDeleteMessageAlert = false
    @State private var hoveredMessageId: UUID? = nil

    // Batch Deletion State
    @State private var isSelectingThreads: Bool = false
    @State private var selectedThreadIds: Set<String> = []
    @State private var isShowingDeleteBatchThreadsAlert: Bool = false

    @State private var isSelectingMessages: Bool = false
    @State private var selectedMessageIds: Set<UUID> = []
    @State private var isShowingDeleteBatchMessagesAlert: Bool = false

    // Contact Save / Edit State
    @State private var isShowingContactSheet = false
    @State private var contactFormPhone: String = ""
    @State private var contactFormName: String = ""
    @State private var contactFormNotes: String = ""
    @State private var contactToEdit: Contact? = nil

    public init(controller: EC20Controller, uiState: AppUIState) {
        self.controller = controller
        self.uiState = uiState
    }

    public var body: some View {
        HSplitView {
            // Left: Conversation List
            conversationList
                .frame(minWidth: 260, maxWidth: 360)

            // Right: Conversation Chat Thread
            if let threadId = uiState.selectedThreadId {
                chatThreadView(threadId: threadId)
                    .frame(minWidth: 360)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $uiState.isShowingNewMessageSheet) {
            newMessageSheet
        }
        .sheet(isPresented: $isShowingContactSheet) {
            contactEditorSheet
        }
        .alert("确认删除整个会话？", isPresented: $isShowingDeleteThreadAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let currentThread = uiState.selectedThreadId {
                    Task {
                        do {
                            try await controller.deleteThread(threadId: currentThread)
                            NotificationManager.shared.clearNotifications(for: currentThread)
                            uiState.selectedThreadId = controller.conversations.first?.threadId
                        } catch {
                            deleteErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        } message: {
            Text("将从 SIM/模块存储与本地数据库彻底删除此会话的所有短信，此操作不可恢复。")
        }
        .alert("确认删除此条短信？", isPresented: $isShowingDeleteMessageAlert) {
            Button("取消", role: .cancel) {
                messagePendingDeletion = nil
            }
            Button("删除", role: .destructive) {
                if let msg = messagePendingDeletion {
                    messagePendingDeletion = nil
                    Task {
                        do {
                            try await controller.deleteSMS(id: msg.id)
                            if let currentThread = uiState.selectedThreadId {
                                loadThreadMessages(currentThread)
                                NotificationManager.shared.clearNotifications(for: currentThread)
                            }
                        } catch {
                            deleteErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        } message: {
            Text("将从模块存储及本地记录彻底删除该条短信，不可恢复。")
        }
        .alert("确认批量删除 \(selectedThreadIds.count) 个会话？", isPresented: $isShowingDeleteBatchThreadsAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let toDelete = selectedThreadIds
                Task {
                    let result = await controller.deleteThreadsBatch(threadIds: Array(toDelete))
                    for tid in toDelete {
                        NotificationManager.shared.clearNotifications(for: tid)
                    }
                    if toDelete.contains(uiState.selectedThreadId ?? "") {
                        uiState.selectedThreadId = controller.conversations.first?.threadId
                    }
                    if result.failedCount > 0 {
                        deleteErrorMessage = "部分会话删除失败 (\(result.failedCount) 个)"
                    }
                    selectedThreadIds.removeAll()
                    isSelectingThreads = false
                }
            }
        } message: {
            Text("将从 SIM/模块存储与本地数据库彻底删除选中会话中的所有短信，此操作不可恢复。")
        }
        .alert("确认批量删除 \(selectedMessageIds.count) 条短信？", isPresented: $isShowingDeleteBatchMessagesAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let toDelete = selectedMessageIds
                Task {
                    let result = await controller.deleteSMSBatch(ids: Array(toDelete))
                    if let currentThread = uiState.selectedThreadId {
                        loadThreadMessages(currentThread)
                        NotificationManager.shared.clearNotifications(for: currentThread)
                    }
                    if result.failedCount > 0 {
                        deleteErrorMessage = "部分短信删除失败 (\(result.failedCount) 条)"
                    }
                    selectedMessageIds.removeAll()
                    isSelectingMessages = false
                }
            }
        } message: {
            Text("将从模块存储及本地记录彻底删除选中的短信，不可恢复。")
        }
        .alert(isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Alert(
                title: Text("删除操作提示"),
                message: Text(deleteErrorMessage ?? ""),
                dismissButton: .default(Text("好的"))
            )
        }
        .onChange(of: uiState.selectedThreadId) { newId in
            if let id = newId {
                loadThreadMessages(id)
                controller.markConversationRead(threadId: id)
                NotificationManager.shared.clearNotifications(for: id)
            } else {
                threadMessages = []
            }
        }
        .onReceive(controller.$conversations) { _ in
            if let id = uiState.selectedThreadId {
                loadThreadMessages(id)
            }
        }
        .onAppear {
            if uiState.selectedThreadId == nil, let first = controller.conversations.first {
                uiState.selectedThreadId = first.threadId
            }
        }
    }

    private func loadThreadMessages(_ threadId: String) {
        self.threadMessages = controller.fetchMessagesForThread(threadId)
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        VStack(spacing: 0) {
            // Header Toolbar
            HStack(spacing: 8) {
                Text("信息")
                    .font(.headline)

                if controller.totalUnreadCount > 0 {
                    Text("\(controller.totalUnreadCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }

                Spacer()

                if isSelectingThreads {
                    Button(selectedThreadIds.count == controller.conversations.count ? "取消全选" : "全选") {
                        if selectedThreadIds.count == controller.conversations.count {
                            selectedThreadIds.removeAll()
                        } else {
                            selectedThreadIds = Set(controller.conversations.map { $0.threadId })
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Button(action: {
                        if !selectedThreadIds.isEmpty {
                            isShowingDeleteBatchThreadsAlert = true
                        }
                    }) {
                        Text("删除(\(selectedThreadIds.count))")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(selectedThreadIds.isEmpty)

                    Button("完成") {
                        isSelectingThreads = false
                        selectedThreadIds.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Button(action: {
                        isSelectingThreads = true
                        selectedThreadIds.removeAll()
                    }) {
                        Label("选择", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(controller.conversations.isEmpty)

                    Button(action: {
                        Task { await controller.syncModemSMS() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("从模块同步短信")

                    Button(action: {
                        uiState.isShowingNewMessageSheet = true
                    }) {
                        Image(systemName: "square.and.pencil")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("写新短信")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if controller.conversations.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无短信会话")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("收发短信将自动按联系人归类在此")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $uiState.selectedThreadId) {
                    ForEach(controller.conversations) { conv in
                        let attribution = PhoneAttributionLookup.shared.lookup(conv.displayRecipient).displayString

                        HStack(alignment: .top, spacing: 10) {
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
                                .padding(.top, 4)
                            }

                            // Avatar / Icon
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Text(conv.title.prefix(1))
                                    .font(.headline)
                                    .foregroundColor(.accentColor)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(conv.title)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)

                                    if !attribution.isEmpty && attribution != "未知" {
                                        Text("• \(attribution)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                    Text(conv.latestMessage.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                HStack {
                                    Text(conv.latestMessage.text)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)

                                    Spacer()

                                    if conv.unreadCount > 0 {
                                        Text("\(conv.unreadCount)")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.red)
                                            .foregroundColor(.white)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(conv.threadId)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Chat Thread View

    private func chatThreadView(threadId: String) -> some View {
        let conv = controller.conversations.first(where: { $0.threadId == threadId })
        let contact = controller.database.findContact(forPhone: threadId)
        let displayTitle = contact?.name ?? PhoneNumberNormalizer.displayFormat(conv?.displayRecipient ?? threadId)
        let rawPhone = conv?.displayRecipient ?? threadId

        return VStack(spacing: 0) {
            // Thread Header
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.title3.bold())
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if contact != nil {
                            Text(PhoneNumberNormalizer.displayFormat(rawPhone))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        let attr = PhoneAttributionLookup.shared.lookup(rawPhone).displayString
                        if !attr.isEmpty && attr != "未知" {
                            Text("• \(attr)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if isSelectingMessages {
                    Button(selectedMessageIds.count == threadMessages.count ? "取消全选" : "全选") {
                        if selectedMessageIds.count == threadMessages.count {
                            selectedMessageIds.removeAll()
                        } else {
                            selectedMessageIds = Set(threadMessages.map { $0.id })
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Button(action: {
                        if !selectedMessageIds.isEmpty {
                            isShowingDeleteBatchMessagesAlert = true
                        }
                    }) {
                        Text("删除(\(selectedMessageIds.count))")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(selectedMessageIds.isEmpty)

                    Button("完成") {
                        isSelectingMessages = false
                        selectedMessageIds.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Button(action: {
                        isSelectingMessages = true
                        selectedMessageIds.removeAll()
                    }) {
                        Label("选择短信", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(threadMessages.isEmpty)

                    // Save Contact or Edit Contact
                    if let existing = contact {
                        Button(action: {
                            contactToEdit = existing
                            contactFormPhone = rawPhone
                            contactFormName = existing.name
                            contactFormNotes = existing.notes
                            isShowingContactSheet = true
                        }) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("编辑联系人")
                    } else {
                        Button(action: {
                            contactToEdit = nil
                            contactFormPhone = rawPhone
                            contactFormName = ""
                            contactFormNotes = ""
                            isShowingContactSheet = true
                        }) {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("存为联系人")
                    }

                    // Quick Call Button
                    Button(action: {
                        uiState.dialNumber = rawPhone
                        uiState.selectedTab = .phone
                    }) {
                        Image(systemName: "phone.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("拨打电话")

                    // Mark Read Button
                    Button(action: {
                        controller.markConversationRead(threadId: threadId)
                    }) {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("标为已读")

                    // Delete Conversation Button
                    Button(action: {
                        isShowingDeleteThreadAlert = true
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("删除会话")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Messages Bubble Scroll
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(threadMessages) { msg in
                            messageBubble(msg, threadId: threadId)
                                .id(msg.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: threadMessages.count) { _ in
                    if let last = threadMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = threadMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Inline Message Composer
            inlineComposer(threadId: threadId, destination: rawPhone)
        }
    }

    // MARK: - Message Bubble

    private func messageBubble(_ msg: SMSMessage, threadId: String) -> some View {
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

            if !msg.isIncoming {
                Spacer(minLength: 40)

                // Hover delete button for outgoing messages
                if hoveredMessageId == msg.id {
                    Button(action: {
                        messagePendingDeletion = msg
                        isShowingDeleteMessageAlert = true
                    }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此短信")
                    .transition(.opacity)
                }
            }

            VStack(alignment: msg.isIncoming ? .leading : .trailing, spacing: 4) {
                // Bubble Text
                Text(msg.text)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(msg.isIncoming ? Color(NSColor.controlBackgroundColor) : Color.accentColor)
                    .foregroundColor(msg.isIncoming ? .primary : .white)
                    .cornerRadius(16)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button(role: .destructive) {
                            messagePendingDeletion = msg
                            isShowingDeleteMessageAlert = true
                        } label: {
                            Label("删除此短信", systemImage: "trash")
                        }
                    }

                // Timestamp & Status
                HStack(spacing: 4) {
                    Text(msg.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    if !msg.isIncoming {
                        switch msg.sendStatus {
                        case .sending:
                            ProgressView()
                                .scaleEffect(0.5)
                        case .sent:
                            Image(systemName: "checkmark")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        case .failed:
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                                Button("重试") {
                                    Task { try? await controller.retrySMS(id: msg.id) }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.red)
                            }
                            .font(.system(size: 9))
                        }
                    }
                }
            }

            if msg.isIncoming {
                // Hover delete button for incoming messages
                if hoveredMessageId == msg.id {
                    Button(action: {
                        messagePendingDeletion = msg
                        isShowingDeleteMessageAlert = true
                    }) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此短信")
                    .transition(.opacity)
                }

                Spacer(minLength: 40)
            }
        }
        .onHover { isHovered in
            if isHovered {
                hoveredMessageId = msg.id
            } else if hoveredMessageId == msg.id {
                hoveredMessageId = nil
            }
        }
    }

    // MARK: - Inline Composer

    private func inlineComposer(threadId: String, destination: String) -> some View {
        VStack(spacing: 6) {
            if let err = uiState.inlineSMSError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $uiState.inlineReplyText)
                    .font(.body)
                    .frame(minHeight: 36, maxHeight: 90)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                VStack(spacing: 4) {
                    let isUCS2 = UCS2Codec.requiresUCS2(uiState.inlineReplyText)
                    let count = uiState.inlineReplyText.count
                    Text("\(count)字 | \(isUCS2 ? "UCS2" : "ASCII")")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)

                    Button(action: {
                        let textToSend = uiState.inlineReplyText
                        guard !textToSend.isEmpty else { return }
                        uiState.isSendingInlineSMS = true
                        uiState.inlineSMSError = nil

                        Task {
                            do {
                                try await controller.sendSMS(to: destination, text: textToSend)
                                uiState.inlineReplyText = ""
                                loadThreadMessages(threadId)
                            } catch {
                                uiState.inlineSMSError = error.localizedDescription
                            }
                            uiState.isSendingInlineSMS = false
                        }
                    }) {
                        if uiState.isSendingInlineSMS {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(uiState.inlineReplyText.isEmpty ? .secondary : .accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(uiState.inlineReplyText.isEmpty || uiState.isSendingInlineSMS)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("选择一个会话以查看聊天记录")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Compose New Message Sheet

    private var newMessageSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("新建短信")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    uiState.isShowingNewMessageSheet = false
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("收件人号码:")
                    .font(.subheadline.bold())
                HStack {
                    TextField("输入手机号 (如 13800000000 或 10010)", text: $uiState.newRecipient)
                        .textFieldStyle(.roundedBorder)

                    // Quick select from contacts
                    Menu {
                        ForEach(controller.contacts) { c in
                            Button("\(c.name) (\(c.phoneNumber))") {
                                uiState.newRecipient = c.phoneNumber
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("短信内容:")
                        .font(.subheadline.bold())
                    Spacer()
                    let isUCS2 = UCS2Codec.requiresUCS2(uiState.newText)
                    Text("\(uiState.newText.count)字 | \(isUCS2 ? "UCS2 中文长短信" : "7-bit GSM")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TextEditor(text: $uiState.newText)
                    .frame(height: 100)
                    .border(Color.secondary.opacity(0.3), width: 1)
                    .cornerRadius(6)
            }

            if let err = uiState.newMessageError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("发送短信") {
                    let dest = uiState.newRecipient
                    let txt = uiState.newText
                    uiState.isSendingNewMessage = true
                    uiState.newMessageError = nil
                    Task {
                        do {
                            try await controller.sendSMS(to: dest, text: txt)
                            uiState.newRecipient = ""
                            uiState.newText = ""
                            uiState.isShowingNewMessageSheet = false
                            uiState.selectedThreadId = PhoneNumberNormalizer.normalize(dest)
                        } catch {
                            uiState.newMessageError = error.localizedDescription
                        }
                        uiState.isSendingNewMessage = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(uiState.newRecipient.isEmpty || uiState.newText.isEmpty || uiState.isSendingNewMessage)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Save or Edit Contact Sheet

    private var contactEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(contactToEdit == nil ? "存为联系人" : "编辑联系人")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    isShowingContactSheet = false
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("电话号码:")
                    .font(.subheadline.bold())
                Text(contactFormPhone)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                Text("号码从短信自动获取，不可丢失")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("联系人姓名:")
                    .font(.subheadline.bold())
                TextField("例如：张三（必填）", text: $contactFormName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注 / 关系:")
                    .font(.subheadline.bold())
                TextField("例如：朋友、同事、客户（可选）", text: $contactFormNotes)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("保存") {
                    let trimmedName = contactFormName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedName.isEmpty else { return }
                    let c = Contact(
                        id: contactToEdit?.id ?? UUID(),
                        name: trimmedName,
                        phoneNumber: contactFormPhone,
                        notes: contactFormNotes
                    )
                    controller.database.saveContact(c)
                    controller.loadLocalData()
                    isShowingContactSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(contactFormName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
