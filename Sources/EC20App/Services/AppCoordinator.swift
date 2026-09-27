import SwiftUI
import AppKit
import Combine
import EC20Core
import EC20Transport

@MainActor
public final class AudioBridgeStore: ObservableObject {
    public let real = EC20AudioBridge()
    public let mock = EC20AudioBridge()
    public init() {}
}

@MainActor
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    public let realController: EC20Controller
    public let mockController: EC20Controller
    public let audioStore = AudioBridgeStore()
    public let uiState = AppUIState()

    public weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    public var activeController: EC20Controller {
        uiState.useSimulation ? mockController : realController
    }

    public var activeAudioBridge: EC20AudioBridge {
        uiState.useSimulation ? audioStore.mock : audioStore.real
    }

    private init() {
        let realTransport = LibusbATTransport()
        let mockTransport = MockATTransport()
        self.realController = EC20Controller(transport: realTransport)
        self.mockController = EC20Controller(transport: mockTransport)

        setupHooks()
        setupMenuBarAndNotifications()
        setupBindings()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationManager.shared.requestAuthorization()

        Task {
            await activeController.connect()
        }
    }

    // MARK: - Window Presentation

    public func registerMainWindow(_ window: NSWindow) {
        self.mainWindow = window
    }

    public func showMainWindow(selectThreadId: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        if let threadId = selectThreadId {
            uiState.selectThread(threadId)
        }

        if let win = mainWindow {
            win.setIsVisible(true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            return
        }

        // Find existing non-panel window
        for win in NSApplication.shared.windows where !(win is NSPanel) && win.canBecomeMain {
            self.mainWindow = win
            win.setIsVisible(true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            return
        }
    }

    // MARK: - Hooks & Integration

    private func setupBindings() {
        // Microphone Mute Binding
        uiState.$isMicMuted
            .sink { [weak self] muted in
                self?.activeAudioBridge.setMicrophoneMuted(muted)
            }
            .store(in: &cancellables)

        // Simulation Toggle Binding
        uiState.$useSimulation
            .removeDuplicates()
            .sink { [weak self] isSim in
                guard let self = self, self.isStarted else { return }
                Task {
                    if isSim {
                        await self.realController.disconnect()
                    } else {
                        await self.mockController.disconnect()
                    }
                    self.setupHooks()
                    MenuBarController.shared.setup(controller: self.activeController)
                    if EC20GatewayServer.shared.isRunning {
                        EC20GatewayServer.shared.configure(with: self.activeController)
                    }
                    await self.activeController.connect()
                }
            }
            .store(in: &cancellables)

        // Unread Badge Bindings
        realController.$totalUnreadCount
            .sink { [weak self] count in
                guard let self = self, !self.uiState.useSimulation else { return }
                MenuBarController.shared.updateBadge(unreadCount: count)
                NotificationManager.shared.updateBadgeCount(count)
            }
            .store(in: &cancellables)

        mockController.$totalUnreadCount
            .sink { [weak self] count in
                guard let self = self, self.uiState.useSimulation else { return }
                MenuBarController.shared.updateBadge(unreadCount: count)
                NotificationManager.shared.updateBadgeCount(count)
            }
            .store(in: &cancellables)
    }

    private func setupHooks() {
        let realAudioBridge = audioStore.real
        let mockAudioBridge = audioStore.mock

        // Real Controller Call & Audio Bridge Hooks
        realController.onCallStarted = { [weak self, weak realController, weak realAudioBridge] in
            guard let self = self, let realController = realController, let realAudioBridge = realAudioBridge else { return }
            guard realAudioBridge.state == .stopped, realController.audioAssessment.qpcmvSupported else { return }
            guard let response = try? await realController.executeAT("AT+QPCMV=1,0"), response.isOK else {
                realController.setAudioBridgeStatus("QPCMV 激活失败")
                return
            }
            realAudioBridge.setMicrophoneMuted(self.uiState.isMicMuted)
            realAudioBridge.start(deviceHandle: realController.transport.rawDeviceHandle, loopbackOnly: false)
            realController.setAudioBridgeStatus(realAudioBridge.state.rawValue)
        }
        realController.onCallEnded = { [weak realController, weak realAudioBridge] in
            IncomingCallWindowController.shared.dismiss()
            guard let realController = realController, let realAudioBridge = realAudioBridge else { return }
            realAudioBridge.stop()
            _ = try? await realController.executeAT("AT+QPCMV=0")
            realController.setAudioBridgeStatus(realAudioBridge.state.rawValue)
        }

        // Mock Controller Call & Audio Bridge Hooks
        mockController.onCallStarted = { [weak self, weak mockController, weak mockAudioBridge] in
            guard let self = self, let mockController = mockController, let mockAudioBridge = mockAudioBridge else { return }
            mockAudioBridge.setMicrophoneMuted(self.uiState.isMicMuted)
            mockAudioBridge.start(deviceHandle: nil, loopbackOnly: true)
            mockController.setAudioBridgeStatus(mockAudioBridge.state.rawValue)
        }
        mockController.onCallEnded = { [weak mockController, weak mockAudioBridge] in
            IncomingCallWindowController.shared.dismiss()
            guard let mockController = mockController, let mockAudioBridge = mockAudioBridge else { return }
            mockAudioBridge.stop()
            mockController.setAudioBridgeStatus(mockAudioBridge.state.rawValue)
        }

        // Incoming SMS Notification Handler
        let handleIncomingSMS: @MainActor @Sendable (SMSMessage) -> Void = { [weak self] msg in
            guard let self = self else { return }
            let contact = self.activeController.database.findContact(forPhone: msg.senderOrRecipient)
            NotificationManager.shared.sendSMSNotification(message: msg, contactName: contact?.name)
            let gateway = EC20GatewayServer.shared
            if gateway.isRunning, gateway.controller === self.activeController {
                gateway.broadcastSMSReceived(msg)
            }
        }
        realController.onIncomingSMSNotification = handleIncomingSMS
        mockController.onIncomingSMSNotification = handleIncomingSMS

        // Incoming Call Alert Floating Window Handler
        let handleIncomingCall: @MainActor @Sendable (String, String?) -> Void = { [weak self] callerNumber, contactName in
            guard let self = self else { return }
            IncomingCallWindowController.shared.show(
                callerNumber: callerNumber,
                contactName: contactName,
                onAnswer: { [weak self] in
                    guard let self = self else { return }
                    Task {
                        try? await self.activeController.answerCall()
                        self.showMainWindow()
                        self.uiState.selectedTab = .phone
                    }
                },
                onReject: { [weak self] in
                    guard let self = self else { return }
                    Task {
                        try? await self.activeController.rejectCall()
                    }
                }
            )
        }
        realController.onIncomingCallAlertWithDetails = handleIncomingCall
        mockController.onIncomingCallAlertWithDetails = handleIncomingCall
    }

    private func setupMenuBarAndNotifications() {
        let notif = NotificationManager.shared

        // Notification Actions
        notif.onDirectReply = { [weak self] threadId, recipient, text in
            guard let self = self else { return }
            try? await self.activeController.sendSMS(to: recipient, text: text)
        }
        notif.onSelectThread = { [weak self] threadId in
            self?.showMainWindow(selectThreadId: threadId)
        }

        // Menu Bar Actions
        let menu = MenuBarController.shared
        menu.setup(controller: activeController)
        menu.onOpenMainWindow = { [weak self] in
            self?.showMainWindow()
        }
        menu.onSelectConversation = { [weak self] threadId in
            self?.showMainWindow(selectThreadId: threadId)
        }
    }
}
