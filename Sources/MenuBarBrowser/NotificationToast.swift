import AppKit
import SwiftUI

private final class NotificationPanel: StatusPopoverPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NotificationToastLayout: ObservableObject {
    @Published var arrowX: CGFloat = 155
}

/// An app-owned, non-activating reminder. It does not request macOS notification permission.
@MainActor
final class NotificationToast {
    static let displayDuration: TimeInterval = 3
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    private(set) var notice: WebNotice?
    private var lastShown: [UUID: Date] = [:]
    private let layout = NotificationToastLayout()

    func show(_ notice: WebNotice, siteName: String, anchor: NSStatusBarButton,
              onOpen: @escaping () -> Void, onDisable: @escaping () -> Void) {
        guard anchor.window?.screen != nil else { return }
        // Update an existing card in place, but do not repeatedly reopen dismissed banners.
        let now = Date()
        if self.notice?.pinID != notice.pinID,
           let previous = lastShown[notice.pinID], now.timeIntervalSince(previous) < 3 { return }
        lastShown[notice.pinID] = now
        dismiss()
        self.notice = notice
        let view = NotificationToastView(layout: layout, siteName: siteName, notice: notice, onOpen: onOpen,
                                         onDismiss: { [weak self] in self?.dismiss() }, onDisable: onDisable)
        let hosting = NSHostingView(rootView: view)
        let panel = NotificationPanel(contentRect: NSRect(x: 0, y: 0, width: 310, height: 145),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("TabNest.notification-\(notice.pinID)")
        self.panel = panel
        reanchor(to: anchor)
        panel.orderFrontRegardless()
        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: task)
    }

    func reanchor(to button: NSStatusBarButton) {
        guard let panel, let window = button.window, let screen = window.screen else { return }
        let rect = window.frame
        let frame = Self.anchoredFrame(size: panel.frame.size, anchor: rect, visibleFrame: screen.visibleFrame)
        layout.arrowX = PopoverGeometry.arrowPosition(anchorX: rect.midX, frame: frame)
        panel.setFrame(frame, display: true)
    }

    static func anchoredFrame(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        PopoverGeometry.anchoredFrame(size: size, anchor: anchor, visibleFrame: visibleFrame)
    }

    func retainTabs(_ pinIDs: Set<UUID>) {
        lastShown = lastShown.filter { pinIDs.contains($0.key) }
        if let notice, !pinIDs.contains(notice.pinID) { dismiss() }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
        notice = nil
    }
}

private struct NotificationToastView: View {
    @ObservedObject var layout: NotificationToastLayout
    let siteName: String
    let notice: WebNotice
    let onOpen: () -> Void
    let onDismiss: () -> Void
    let onDisable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill").foregroundStyle(.secondary)
                Text(siteName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onDisable) { Image(systemName: "bell.slash") }
                    .help(L10n.text(.notificationDisable))
                    .accessibilityLabel(L10n.text(.notificationDisable))
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .help(L10n.text(.commonClose))
                    .accessibilityLabel(L10n.text(.commonClose))
            }
            .buttonStyle(.borderless)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(notice.title.isEmpty ? siteName : notice.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    if !notice.body.isEmpty {
                        Text(notice.body).font(.system(size: 12)).lineLimit(3)
                    }
                    Text(notice.origin).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text(.notificationOpen))
        }
        .padding(12)
        .padding(.top, PopoverGeometry.topInset)
        .frame(width: 310, alignment: .leading)
        .tabNestFloatingSurface(in: PopoverOutline(arrowX: layout.arrowX))
    }
}

/// Separate overlay, so favicon refreshes and template-image tinting cannot erase the badge.
final class UnreadDotView: NSView {
    static func badgeFrame(in bounds: NSRect, isFlipped: Bool) -> NSRect {
        let side: CGFloat = 8
        let inset: CGFloat = 1
        return NSRect(x: bounds.maxX - inset - side,
                      y: isFlipped ? bounds.maxY - inset - side : bounds.minY + inset,
                      width: side, height: side)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}
