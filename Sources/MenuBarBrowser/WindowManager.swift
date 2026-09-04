import AppKit
import Combine

/// 站点窗口注册表：懒创建 PinWindowController、全局快捷键分发、点击外部隐藏。
@MainActor
final class WindowManager {
    private var controllers: [UUID: PinWindowController] = [:]
    private var monitor: Any?
    private(set) var selectedPinID: UUID?
    private let pinStore: PinStore
    private let formWindow: FormWindowController
    weak var statusItemManager: StatusItemManager?
    private var notificationInbox = WebNotificationInbox()

    func markNotificationsRead(_ pinID: UUID) {
        notificationInbox.markRead(pinID)
        statusItemManager?.dismissNotification(for: pinID)
        statusItemManager?.setUnreadPins(notificationInbox.unreadPinIDs)
    }

    func openNotification(_ notice: WebNotice) {
        guard pinStore.pin(with: notice.pinID) != nil,
              notificationInbox.latest[notice.pinID] == notice else { return }
        show(pinID: notice.pinID)
        controllers[notice.pinID]?.webTab.notificationBridge.dispatch("click", for: notice)
    }

    func receiveNotification(_ notice: WebNotice) {
        guard let pin = pinStore.pin(with: notice.pinID),
              WebNotificationPolicy.permission(for: pin, origin: notice.origin) == .granted else { return }
        if let old = notificationInbox.latest[notice.pinID] {
            controllers[notice.pinID]?.webTab.notificationBridge.dispatch("close", for: old)
        }
        notificationInbox.receive(notice)
        statusItemManager?.setUnreadPins(notificationInbox.unreadPinIDs)
        statusItemManager?.showNotification(notice)
    }

    init(pinStore: PinStore, formWindow: FormWindowController) {
        self.pinStore = pinStore
        self.formWindow = formWindow

        HotkeyManager.shared.onHotkey = { [weak self] pinID in
            guard let self else { return }
            if self.pinStore.pin(with: pinID) == nil {
                self.pinStore.openPreset(pinID)
            }
            self.show(pinID: pinID)
        }

        // 点击任一打开面板之外的区域 → 收起所有面板
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if AppDelegate.sharedSettings.settings.hideOnOutsideClick {
                    self.hideAll(except: nil)
                }
            }
        }
    }

    func controller(for pinID: UUID) -> PinWindowController? {
        ensureController(pinID)
        return controllers[pinID]
    }

    func isVisible(_ pinID: UUID) -> Bool {
        controllers[pinID]?.isVisible ?? false
    }

    /// Read the actual page origin without creating or loading a controller for a menu.
    func notificationOrigin(for pinID: UUID) -> String? {
        if let controller = controllers[pinID] {
            return WebNotificationPolicy.origin(for: controller.webTab.webView.url)
        }
        return WebNotificationPolicy.origin(for: pinStore.pin(with: pinID)?.url)
    }

    func toggle(pinID: UUID) {
        guard let controller = controller(for: pinID) else { return }
        selectedPinID = pinID
        mbbTrace("切换站点面板 \(pinID)")
        if controller.wantsVisible {
            controller.hide()
        } else {
            markNotificationsRead(pinID)
            if AppDelegate.sharedSettings.settings.statusIconMode == .collapsed {
                hideAll(except: pinID)
            }
            controller.show()
        }
    }

    func show(pinID: UUID) {
        markNotificationsRead(pinID)
        selectedPinID = pinID
        if AppDelegate.sharedSettings.settings.statusIconMode == .collapsed {
            hideAll(except: pinID)
        }
        controller(for: pinID)?.show()
    }

    func hideAll(except pinID: UUID?) {
        for (id, controller) in controllers where id != pinID {
            controller.hide()
        }
    }

    /// 同步站点变化：清理已删除站点的控制器。
    func sync(with pins: [Pin]) {
        notificationInbox.retain(Set(pins.filter(\.notificationsEnabled).map(\.id)))
        statusItemManager?.setUnreadPins(notificationInbox.unreadPinIDs)
        if let selectedPinID, !pins.contains(where: { $0.id == selectedPinID }) {
            self.selectedPinID = nil
        }
        for dead in controllers.keys where !pins.contains(where: { $0.id == dead }) {
            controllers[dead]?.closeForRemoval()
            controllers[dead] = nil
        }
        for pin in pins {
            controllers[pin.id]?.syncPin(pin)
        }
    }

    func rebindStatusItems(with pins: [Pin]) {
        // Previously authorized open Tabs resume notification delivery after app relaunch.
        // Use the publisher's snapshot: @Published delivers before PinStore.pins is assigned.
        for pin in pins where pin.notificationsEnabled && pin.notificationPermissions.values.contains(.granted) {
            ensureController(pin.id, pin: pin)
        }
        for (id, controller) in controllers {
            if let item = statusItemManager?.statusItem(for: id) {
                controller.updateStatusItem(item)
            }
        }
    }

    func beginAdd() {
        formWindow.presentAdd()
    }

    func beginEdit(pinID: UUID) {
        guard let pin = pinStore.preset(with: pinID) else { return }
        formWindow.presentEdit(pin)
    }

    func showPresetManager() {
        formWindow.presentPresetManager()
    }

    func showAbout() {
        formWindow.presentAbout()
    }

    func stopMonitoring() {
        statusItemManager?.setUnreadPins([])
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        HotkeyManager.shared.onHotkey = nil
    }

    /// 懒创建：首次唤起时才构建 WebView 与面板。
    private func ensureController(_ pinID: UUID, pin snapshot: Pin? = nil) {
        guard controllers[pinID] == nil,
              let pin = snapshot ?? pinStore.pin(with: pinID),
              pin.url != nil,
              let item = statusItemManager?.statusItem(for: pinID) else {
            return
        }
        let controller = PinWindowController(pin: pin, statusItem: item, pinStore: pinStore)
        controllers[pinID] = controller
        controller.webTab.notificationBridge.onNotice = { [weak self] in self?.receiveNotification($0) }
        controller.webTab.notificationBridge.onClose = { [weak self] id, documentID in
            guard let self else { return }
            self.notificationInbox.close(pinID: pinID, id: id, documentID: documentID)
            self.statusItemManager?.setUnreadPins(self.notificationInbox.unreadPinIDs)
        }
        controller.webTab.notificationBridge.onInvalidate = { [weak self] in
            self?.markNotificationsRead(pinID)
        }
    }

}
