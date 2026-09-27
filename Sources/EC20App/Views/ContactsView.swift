import SwiftUI
import EC20Core

@MainActor
public struct ContactsView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState

    @State private var newName: String = ""
    @State private var newPhone: String = ""
    @State private var newNotes: String = ""
    @State private var editingId: UUID? = nil

    public init(controller: EC20Controller, uiState: AppUIState) {
        self.controller = controller
        self.uiState = uiState
    }

    private var filteredContacts: [Contact] {
        if uiState.contactSearchText.isEmpty {
            return controller.contacts
        }
        let q = uiState.contactSearchText.lowercased()
        return controller.contacts.filter {
            $0.name.lowercased().contains(q) || $0.phoneNumber.contains(q) || $0.notes.lowercased().contains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Text("通讯录 (\(controller.contacts.count))")
                    .font(.headline)

                Spacer()

                Button(action: {
                    uiState.isImportingContacts = true
                    Task {
                        do {
                            let count = try await controller.importContactsFromSIM()
                            uiState.importContactsAlert = "成功从 SIM 卡/模块导入 \(count) 个联系人"
                        } catch {
                            uiState.importContactsAlert = "导入失败: \(error.localizedDescription)"
                        }
                        uiState.isImportingContacts = false
                    }
                }) {
                    if uiState.isImportingContacts {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Label("从 SIM 导入", systemImage: "arrow.down.doc.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(uiState.isImportingContacts)

                Button(action: {
                    newName = ""
                    newPhone = ""
                    newNotes = ""
                    editingId = nil
                    uiState.isShowingAddContactSheet = true
                }) {
                    Label("添加联系人", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))

            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索联系人姓名或电话号码...", text: $uiState.contactSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            if filteredContacts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无联系人")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("点击右上角添加新联系人，或直接一键从 SIM 卡导入电话簿。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredContacts) { contact in
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Text(contact.name.prefix(1))
                                    .font(.headline)
                                    .foregroundColor(.blue)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(contact.name)
                                    .font(.headline)
                                Text(PhoneNumberNormalizer.displayFormat(contact.phoneNumber))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if !contact.notes.isEmpty {
                                    Text(contact.notes)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            // Send SMS Action
                            Button(action: {
                                uiState.selectThread(contact.normalizedPhone)
                            }) {
                                Image(systemName: "message.fill")
                                    .font(.title3)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("发送短信")

                            // Call Action
                            Button(action: {
                                uiState.dialNumber = contact.phoneNumber
                                uiState.selectedTab = .phone
                            }) {
                                Image(systemName: "phone.fill")
                                    .font(.title3)
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                            .help("拨打电话")

                            // Edit Action
                            Button(action: {
                                newName = contact.name
                                newPhone = contact.phoneNumber
                                newNotes = contact.notes
                                editingId = contact.id
                                uiState.isShowingAddContactSheet = true
                            }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)

                            // Delete Action
                            Button(action: {
                                controller.deleteContact(id: contact.id)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $uiState.isShowingAddContactSheet) {
            contactEditorSheet
        }
        .alert(isPresented: Binding(
            get: { uiState.importContactsAlert != nil },
            set: { if !$0 { uiState.importContactsAlert = nil } }
        )) {
            Alert(
                title: Text("通讯录导入结果"),
                message: Text(uiState.importContactsAlert ?? ""),
                dismissButton: .default(Text("好的"))
            )
        }
    }

    private var contactEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editingId == nil ? "添加联系人" : "编辑联系人")
                    .font(.headline)
                Spacer()
                Button("取消") {
                    uiState.isShowingAddContactSheet = false
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("姓名:")
                    .font(.subheadline.bold())
                TextField("例如：张三", text: $newName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("电话号码:")
                    .font(.subheadline.bold())
                TextField("例如：13800000000 或 +8613800000000", text: $newPhone)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("备注 / 关系:")
                    .font(.subheadline.bold())
                TextField("例如：朋友、同事、客户", text: $newNotes)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("保存") {
                    let c = Contact(
                        id: editingId ?? UUID(),
                        name: newName,
                        phoneNumber: newPhone,
                        notes: newNotes
                    )
                    controller.database.saveContact(c)
                    controller.loadLocalData()
                    uiState.isShowingAddContactSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.isEmpty || newPhone.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
