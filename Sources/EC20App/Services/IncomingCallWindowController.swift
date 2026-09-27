import AppKit
import SwiftUI
import EC20Core
import EC20BridgeProtocol

private final class CallWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

@MainActor
public final class IncomingCallWindowController: ObservableObject {
    public static let shared = IncomingCallWindowController()

    private var window: NSWindow?
    private var windowDelegate: CallWindowDelegate?
    private var actionHandled: Bool = false

    public init() {}

    public func show(
        callerNumber: String,
        contactName: String?,
        onAnswer: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        if window != nil {
            dismiss()
        }

        self.actionHandled = false

        let contentView = IncomingCallBannerView(
            callerNumber: callerNumber,
            contactName: contactName,
            onAnswer: { [weak self] in
                guard let self = self, !self.actionHandled else { return }
                self.actionHandled = true
                onAnswer()
                self.dismiss()
            },
            onReject: { [weak self] in
                guard let self = self, !self.actionHandled else { return }
                self.actionHandled = true
                onReject()
                self.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 170),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.contentView = hostingView

        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = screenRect.midX - 260
            let y = screenRect.maxY - 190
            win.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            win.center()
        }

        let delegate = CallWindowDelegate()
        delegate.onClose = { [weak self] in
            guard let self = self, !self.actionHandled else { return }
            self.actionHandled = true
            onReject()
            self.window = nil
            self.windowDelegate = nil
        }
        win.delegate = delegate
        self.windowDelegate = delegate
        self.window = win
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        actionHandled = true
        window?.delegate = nil
        window?.close()
        window = nil
        windowDelegate = nil
    }
}

private struct IncomingCallBannerView: View {
    let callerNumber: String
    let contactName: String?
    let onAnswer: () -> Void
    let onReject: () -> Void

    var body: some View {
        ZStack {
            // Dark Frosted Glass Banner Background
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 10)

            // Keep the banner dark in both Light and Dark appearances so the
            // white caller text and red/green call actions stay legible.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.58))

            // Main Content Layout
            HStack(spacing: 20) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.85), Color.purple.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)

                    if let name = contactName, let firstChar = name.first {
                        Text(String(firstChar))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 46))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }

                // Caller Information
                VStack(alignment: .leading, spacing: 4) {
                    Text(contactName ?? PhoneNumberNormalizer.displayFormat(callerNumber))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if contactName != nil {
                            Text(PhoneNumberNormalizer.displayFormat(callerNumber))
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                        } else {
                            Text("蜂窝移动网络来电")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white.opacity(0.75))
                        }

                        let attribution = PhoneAttributionLookup.shared.lookup(callerNumber).displayString
                        if !attribution.isEmpty && attribution != "未知" {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.5))
                            Text(attribution)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.yellow.opacity(0.9))
                        }
                    }

                    Text("正在呼叫...")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer(minLength: 16)

                // Circular Reject & Answer Buttons
                HStack(spacing: 22) {
                    // Reject Button (Red circle with white phone icon)
                    Button(action: onReject) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 52, height: 52)
                                    .shadow(color: Color.red.opacity(0.4), radius: 6, x: 0, y: 3)
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            Text("挂断")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("挂断 / 拒绝来电")

                    // Answer Button (Green circle with white phone icon)
                    Button(action: onAnswer) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 52, height: 52)
                                    .shadow(color: Color.green.opacity(0.4), radius: 6, x: 0, y: 3)
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            Text("接听")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("接听来电")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 520, height: 170)
    }
}
