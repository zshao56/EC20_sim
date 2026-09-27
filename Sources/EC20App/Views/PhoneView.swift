import SwiftUI
import AppKit
import EC20Core
import EC20BridgeProtocol

@MainActor
public struct PhoneView: View {
    @ObservedObject var controller: EC20Controller
    @ObservedObject var uiState: AppUIState

    @State private var callDurationTimer: Timer? = nil
    @State private var callSeconds: Int = 0
    @State private var keyEventMonitor: Any? = nil

    // Batch Selection State
    @State private var isSelectingCalls: Bool = false
    @State private var selectedCallIds: Set<UUID> = []
    @State private var isShowingDeleteBatchAlert: Bool = false
    @State private var batchDeleteErrorMessage: String? = nil

    public init(controller: EC20Controller, uiState: AppUIState) {
        self.controller = controller
        self.uiState = uiState
    }

    public var body: some View {
        HSplitView {
            // Left: Dialpad & Active Call Area
            VStack(spacing: 16) {
                // Active Call Card
                if let activeCall = controller.activeCalls.first {
                    activeCallCard(activeCall)
                }

                // Keypad Area
                dialpadSection

                Spacer(minLength: 10)
            }
            .padding(20)
            .frame(minWidth: 320, maxWidth: 440)

            // Right: Recent Calls History
            recentCallsSection
                .frame(minWidth: 300)
        }
        .alert("确认批量删除 \(selectedCallIds.count) 条通话记录？", isPresented: $isShowingDeleteBatchAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let result = controller.deleteCallHistoryBatch(ids: Array(selectedCallIds))
                if result.failedCount > 0 {
                    batchDeleteErrorMessage = "部分删除失败 (\(result.failedCount) 条)"
                }
                selectedCallIds.removeAll()
                isSelectingCalls = false
            }
        } message: {
            Text("将从本地记录与模块索引彻底删除选中的通话历史，不可恢复。")
        }
        .alert(isPresented: Binding(
            get: { batchDeleteErrorMessage != nil },
            set: { if !$0 { batchDeleteErrorMessage = nil } }
        )) {
            Alert(
                title: Text("批量删除提示"),
                message: Text(batchDeleteErrorMessage ?? ""),
                dismissButton: .default(Text("好的"))
            )
        }
        .onReceive(controller.$activeCalls) { calls in
            if calls.contains(where: { $0.status == .active }) {
                startDurationTimer()
            } else {
                stopDurationTimer()
            }
        }
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - Keyboard Handling

    private func setupKeyboardMonitor() {
        if keyEventMonitor != nil { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Return / Enter (keyCode 36 on main keyboard, 76 on numpad)
            if event.keyCode == 36 || event.keyCode == 76 {
                self.triggerDial()
                return nil
            }
            // Backspace (keyCode 51)
            if event.keyCode == 51 {
                // If focus is not currently an editable text field
                if let window = NSApp.keyWindow, !(window.firstResponder is NSTextView) {
                    if !self.uiState.dialNumber.isEmpty {
                        self.uiState.dialNumber.removeLast()
                    }
                    return nil
                }
            }
            // If typing 0-9, +, *, # outside an active text view
            if let chars = event.charactersIgnoringModifiers, chars.count == 1,
               let ch = chars.first, DialpadInputFilter.isAllowed(ch) {
                if let window = NSApp.keyWindow, !(window.firstResponder is NSTextView) {
                    self.uiState.dialNumber.append(ch)
                    return nil
                }
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    private func triggerDial() {
        guard !uiState.dialNumber.isEmpty, !controller.isBusy else { return }
        uiState.callErrorMessage = nil
        Task {
            do {
                try await controller.dial(number: uiState.dialNumber)
            } catch {
                uiState.callErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Active Call Card

    private func activeCallCard(_ call: CallRecord) -> some View {
        let contact = controller.database.findContact(forPhone: call.phoneNumber)
        let resolvedNumber = call.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未知号码" : call.phoneNumber
        let displayName = contact?.name ?? PhoneNumberNormalizer.displayFormat(resolvedNumber)

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(call.status == .active ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: call.direction == .incoming ? "phone.down.circle.fill" : "phone.arrow.up.right.fill")
                        .font(.title2)
                        .foregroundColor(call.status == .active ? .green : .orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName.isEmpty ? "未知号码" : displayName)
                        .font(.headline)
                    Text(call.status == .active ? "通话中: \(formatDuration(callSeconds))" : "正在呼叫中...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    Task { try? await controller.hangupCall() }
                }) {
                    Label("挂断", systemImage: "phone.down.fill")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Divider()

            // Audio Controls & Voice PCM Bridge Status
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("USB PCM 语音桥: \(controller.audioBridgeStatus)")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                }

                Spacer()

                Button(action: {
                    uiState.isMicMuted.toggle()
                }) {
                    Image(systemName: uiState.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundColor(uiState.isMicMuted ? .red : .primary)
                }
                .buttonStyle(.plain)
                .help(uiState.isMicMuted ? "解除麦克风静音" : "麦克风静音")
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(call.status == .active ? Color.green.opacity(0.5) : Color.orange.opacity(0.5), lineWidth: 1.5)
        )
    }

    // MARK: - Dialpad Section

    private var dialpadSection: some View {
        VStack(spacing: 14) {
            // Number Display with AppKit NSTextField for auto-focus & keyboard events
            HStack(spacing: 8) {
                DialpadTextField(
                    text: $uiState.dialNumber,
                    placeholder: "输入电话号码...",
                    onCommit: { triggerDial() }
                )
                .frame(height: 38)

                if !uiState.dialNumber.isEmpty {
                    Button(action: {
                        uiState.dialNumber.removeLast()
                    }) {
                        Image(systemName: "delete.left.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除一位")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .frame(maxWidth: 320)

            // Keypad Grid (3x4)
            let keys: [[(String, String)]] = [
                [("1", ""), ("2", "ABC"), ("3", "DEF")],
                [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
                [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
                [("*", ""), ("0", "+"), ("#", "")]
            ]

            VStack(spacing: 10) {
                ForEach(0..<keys.count, id: \.self) { r in
                    HStack(spacing: 12) {
                        ForEach(0..<keys[r].count, id: \.self) { c in
                            let item = keys[r][c]
                            Button(action: {
                                uiState.dialNumber.append(item.0)
                            }) {
                                VStack(spacing: 1) {
                                    Text(item.0)
                                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    if !item.1.isEmpty {
                                        Text(item.1)
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 74, height: 48)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 320)

            // Action Buttons
            HStack(spacing: 16) {
                Button(action: {
                    triggerDial()
                }) {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("拨号")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(uiState.dialNumber.isEmpty || controller.isBusy)
            }
            .frame(maxWidth: 320)

            if let err = uiState.callErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Recent Calls Section

    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近通话")
                    .font(.headline)
                Spacer()

                if isSelectingCalls {
                    Button(selectedCallIds.count == controller.callHistory.count ? "取消全选" : "全选") {
                        if selectedCallIds.count == controller.callHistory.count {
                            selectedCallIds.removeAll()
                        } else {
                            selectedCallIds = Set(controller.callHistory.map { $0.id })
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Button(action: {
                        if !selectedCallIds.isEmpty {
                            isShowingDeleteBatchAlert = true
                        }
                    }) {
                        Text("删除(\(selectedCallIds.count))")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(selectedCallIds.isEmpty)

                    Button("完成") {
                        isSelectingCalls = false
                        selectedCallIds.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Button(action: {
                        isSelectingCalls = true
                        selectedCallIds.removeAll()
                    }) {
                        Label("选择", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(controller.callHistory.isEmpty)

                    Button(action: {
                        Task {
                            _ = try? await controller.importCallHistoryFromModem()
                        }
                    }) {
                        Label("导入模块通话", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("从模块 DC/MC/RC 读取呼叫记录")

                    Button(action: {
                        controller.database.clearCallHistory()
                        controller.loadLocalData()
                    }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("清空通话记录")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if controller.callHistory.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无通话记录")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("拨打或接听的通话将显示在此")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(controller.callHistory) { item in
                        let cleanPhone = item.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolvedPhone = cleanPhone.isEmpty ? "未知号码" : cleanPhone
                        let displayTitle = item.contactName ?? PhoneNumberNormalizer.displayFormat(resolvedPhone)
                        let attribution = PhoneAttributionLookup.shared.lookup(resolvedPhone).displayString

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
                                HStack(spacing: 6) {
                                    Text(displayTitle.isEmpty ? "未知号码" : displayTitle)
                                        .font(.subheadline.bold())

                                    if !attribution.isEmpty && attribution != "未知" {
                                        Text("• \(attribution)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }

                                if item.contactName != nil {
                                    Text(PhoneNumberNormalizer.displayFormat(resolvedPhone))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                HStack(spacing: 6) {
                                    if item.hasExactTimestamp, let time = item.timestamp {
                                        Text(time.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("模块存储记录 (\(item.source.rawValue))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    if let dur = item.durationSeconds, dur > 0 {
                                        Text("• \(formatDuration(dur))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            if !isSelectingCalls && resolvedPhone != "未知号码" {
                                Button(action: {
                                    uiState.dialNumber = resolvedPhone
                                }) {
                                    Image(systemName: "phone.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                                .help("填入拨号盘")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func callIcon(for type: CallHistoryType) -> some View {
        Group {
            switch type {
            case .incoming:
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundColor(.blue)
            case .outgoing:
                Image(systemName: "phone.arrow.up.right.fill")
                    .foregroundColor(.green)
            case .missed:
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundColor(.red)
            case .rejected:
                Image(systemName: "phone.down.fill")
                    .foregroundColor(.orange)
            }
        }
        .font(.subheadline)
    }

    private func startDurationTimer() {
        if callDurationTimer != nil { return }
        callSeconds = 0
        callDurationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                self.callSeconds += 1
            }
        }
    }

    private func stopDurationTimer() {
        callDurationTimer?.invalidate()
        callDurationTimer = nil
        callSeconds = 0
    }

    private func formatDuration(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - AppKit Dialpad Text Field

private struct DialpadTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = FocusAwareTextField()
        textField.placeholderString = placeholder
        textField.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        textField.alignment = .center
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.onAction(_:))
        textField.stringValue = text
        context.coordinator.textField = textField

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DialpadTextField
        weak var textField: NSTextField?

        init(_ parent: DialpadTextField) {
            self.parent = parent
        }

        @objc func onAction(_ sender: NSTextField) {
            parent.onCommit()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let filtered = DialpadInputFilter.filter(field.stringValue)
            if filtered != field.stringValue {
                field.stringValue = filtered
            }
            if parent.text != filtered {
                parent.text = filtered
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }

    private final class FocusAwareTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                DispatchQueue.main.async {
                    self.window?.makeFirstResponder(self)
                }
            }
        }
    }
}
