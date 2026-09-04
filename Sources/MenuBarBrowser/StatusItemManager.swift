import AppKit
import Combine
import ServiceManagement

/// 支持每个 Tab 独立图标，或把全部 Tab 收拢到一个应用图标。
@MainActor
final class StatusItemManager: NSObject {
    private var items: [UUID: NSStatusItem] = [:]
    private var pinIDsByButton: [ObjectIdentifier: UUID] = [:]
    private var placeholderItem: NSStatusItem?
    private var collapsedItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var unreadPins: Set<UUID> = []
    private let notificationToast = NotificationToast()

    func setUnreadPins(_ pinIDs: Set<UUID>) {
        unreadPins = pinIDs
        notificationToast.retainTabs(pinIDs)
        refreshUnreadDots()
    }

    func dismissNotification(for pinID: UUID) {
        if notificationToast.notice?.pinID == pinID { notificationToast.dismiss() }
    }

    func showNotification(_ notice: WebNotice) {
        guard let pin = pinStore.pin(with: notice.pinID),
              let button = statusItem(for: notice.pinID)?.button else { return }
        notificationToast.show(notice, siteName: pin.name, anchor: button,
                               onOpen: { [weak self] in self?.registry?.openNotification(notice) },
                               onDisable: { [weak self] in self?.disableNotifications(for: notice.pinID) })
    }

    private func disableNotifications(for id: UUID) {
        guard var pin = pinStore.pin(with: id) else { return }
        pin.notificationsEnabled = false
        _ = pinStore.update(pin)
        registry?.markNotificationsRead(id)
    }

    private func refreshUnreadDots() {
        func update(_ button: NSStatusBarButton?, unread: Bool) {
            guard let button else { return }
            let old = button.subviews.first { $0 is UnreadDotView }
            if unread && old == nil {
                let dot = UnreadDotView(frame: UnreadDotView.badgeFrame(in: button.bounds,
                                                                       isFlipped: button.isFlipped))
                dot.autoresizingMask = [.minXMargin, button.isFlipped ? .minYMargin : .maxYMargin]
                dot.setAccessibilityElement(false)
                button.addSubview(dot)
            } else if !unread { old?.removeFromSuperview() }
            button.setAccessibilityValue(unread ? L10n.text(.notificationUnread) : nil)
        }
        for (id, item) in items { update(item.button, unread: unreadPins.contains(id)) }
        update(collapsedItem?.button, unread: !unreadPins.isEmpty)
    }

    private let pinStore: PinStore
    private weak var registry: WindowManager?
    private let settingsProvider: @MainActor () -> AppSettings

    init(pinStore: PinStore, favicon: FaviconCache,
         settingsProvider: @escaping @MainActor () -> AppSettings = { AppDelegate.sharedSettings.settings }) {
        self.pinStore = pinStore
        self.favicon = favicon
        self.settingsProvider = settingsProvider
        super.init()

        favicon.imageDidChange
            .sink { [weak self] pinID in self?.refreshIcon(pinID: pinID) }
            .store(in: &cancellables)
    }

    private let favicon: FaviconCache

    func statusItem(for pinID: UUID) -> NSStatusItem? {
        settingsRead.statusIconMode == .collapsed ? collapsedItem : items[pinID]
    }

    func attach(registry: WindowManager) {
        self.registry = registry
        sync(with: pinStore.pins)
    }

    // MARK: - 同步

    func sync(with pins: [Pin]) {
        defer {
            refreshUnreadDots()
            if let notice = notificationToast.notice, let button = statusItem(for: notice.pinID)?.button {
                notificationToast.reanchor(to: button)
            }
        }
        if settingsRead.statusIconMode == .collapsed {
            removeExpandedItems()
            syncCollapsedItem(visible: true)
            collapsedItem?.button?.toolTip = L10n.text(.statusTabsCount, pins.count)
            syncPlaceholder(pinsNeedPlaceholder: false)
            registry?.rebindStatusItems(with: pins)
            return
        }

        syncCollapsedItem(visible: false)
        // 移除已删除站点的图标
        for dead in items.keys where !pins.contains(where: { $0.id == dead }) {
            if let item = items[dead] {
                if let button = item.button {
                    pinIDsByButton.removeValue(forKey: ObjectIdentifier(button))
                }
                NSStatusBar.system.removeStatusItem(item)
            }
            items[dead] = nil
        }
        // 新建缺失的图标（按 pins 顺序）
        for pin in pins where items[pin.id] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "MenuBarBrowser.pin.\(pin.id)"
            configure(button: item.button, pin: pin, updateImage: true)
            if let button = item.button {
                pinIDsByButton[ObjectIdentifier(button)] = pin.id
                button.target = self
                button.action = #selector(handleClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            items[pin.id] = item
        }
        // 更新标题/提示/图标
        for pin in pins {
            if let button = items[pin.id]?.button {
                // PinStore 也会持久化 favicon URL；普通数据同步不重复替换图像。
                configure(button: button, pin: pin, updateImage: false)
            }
        }
        syncPlaceholder(pinsNeedPlaceholder: pins.isEmpty)
        registry?.rebindStatusItems(with: pins)
    }

    private func removeExpandedItems() {
        for item in items.values {
            if let button = item.button {
                pinIDsByButton.removeValue(forKey: ObjectIdentifier(button))
            }
            NSStatusBar.system.removeStatusItem(item)
        }
        items.removeAll()
    }

    private func syncCollapsedItem(visible: Bool) {
        if visible {
            guard collapsedItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "MenuBarBrowser.collapsed"
            item.button?.image = NSImage(systemSymbolName: "rectangle.stack.fill",
                                         accessibilityDescription: "TabNest")
            item.button?.image?.isTemplate = true
            item.button?.toolTip = L10n.text(.statusTabsCount, pinStore.pins.count)
            item.button?.target = self
            item.button?.action = #selector(handleClick(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            collapsedItem = item
        } else if let item = collapsedItem {
            collapsedItem = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    private func configure(button: NSStatusBarButton?, pin: Pin, updateImage: Bool) {
        guard let button else { return }
        let hotkey = HotkeyManager.shared.label(for: pin.id)
        if updateImage || button.image == nil {
            button.image = displayImage(for: pin, side: 18)
        }
        button.toolTip = hotkey.map { L10n.text(.statusGlobalShortcutTooltip, pin.name, $0) } ?? pin.name
    }

    /// favicon 抓取完成后由外部调用，刷新对应图标。
    func refreshIcon(pinID: UUID) {
        guard let pin = pinStore.pin(with: pinID), let button = items[pinID]?.button else { return }
        button.image = displayImage(for: pin, side: 18)
    }

    /// 状态栏和菜单各自使用副本，防止修改菜单图标尺寸时污染缓存和顶栏图标。
    private func displayImage(for pin: Pin, side: CGFloat) -> NSImage {
        guard let source = favicon.image(for: pin) else {
            let placeholder = FaviconCache.placeholder(for: pin)
            let image = (placeholder.copy() as? NSImage) ?? placeholder
            image.size = NSSize(width: side, height: side)
            return image
        }
        let image = FaviconCache.roundedTabIcon(from: source, side: side)
        image.size = NSSize(width: side, height: side)
        return image
    }

    private func syncPlaceholder(pinsNeedPlaceholder: Bool) {
        if pinsNeedPlaceholder {
            if placeholderItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.autosaveName = "MenuBarBrowser.placeholder"
                item.button?.image = NSImage(systemSymbolName: "menubar.dock.rectangle",
                                             accessibilityDescription: L10n.text(.statusAccessibilityDescription))
                item.button?.image?.isTemplate = true
                item.button?.toolTip = "TabNest — Menu Bar Browser"
                item.button?.target = self
                item.button?.action = #selector(handleClick(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                placeholderItem = item
            }
        } else if let item = placeholderItem {
            placeholderItem = nil
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - 点击处理

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        mbbTrace("状态栏图标被点击, event=\(NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "nil")")
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || (NSApp.currentEvent?.type == .leftMouseUp
                && NSApp.currentEvent?.modifierFlags.contains(.option) == true)

        if collapsedItem?.button === sender {
            if isRightClick {
                // 收拢态仍需能操作刚选中的单个 Tab（清缓存、静音、关闭等）。
                popUpMenu(for: collapsedItem, menu: buildMenu(for: registry?.selectedPinID))
            } else {
                popUpMenu(for: collapsedItem, menu: buildCollapsedTabsMenu())
            }
            return
        }

        guard let pinID = pinIDsByButton[ObjectIdentifier(sender)] else {
            // 占位图标：任何点击都弹菜单
            popUpMenu(for: placeholderItem)
            return
        }

        if isRightClick {
            guard let item = items[pinID] else { return }
            popUpMenu(for: item)
        } else {
            registry?.toggle(pinID: pinID)
        }
    }

    private func popUpMenu(for item: NSStatusItem?) {
        guard let item else { return }
        popUpMenu(for: item, menu: buildMenu(for: menuPinID(item)))
    }

    private func popUpMenu(for item: NSStatusItem?, menu: NSMenu) {
        guard let item else { return }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func menuPinID(_ item: NSStatusItem) -> UUID? {
        guard let button = item.button else { return nil }
        return pinIDsByButton[ObjectIdentifier(button)]
    }

    // MARK: - 菜单构建

    private func buildCollapsedTabsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if pinStore.pins.isEmpty {
            let empty = NSMenuItem(title: L10n.text(.menuNoOpenTabs), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for pin in pinStore.pins {
                let hotkey = HotkeyManager.shared.label(for: pin.id)
                let item = NSMenuItem(title: compactMenuName(pin.name), action: #selector(menuSelectTab(_:)), keyEquivalent: "")
                item.attributedTitle = siteMenuTitle(name: pin.name, hotkey: hotkey ?? "",
                                                     unread: unreadPins.contains(pin.id))
                item.target = self
                item.representedObject = pin.id.uuidString
                item.state = panelVisible(pin.id) ? .on : .off
                item.image = displayImage(for: pin, side: 16)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let presets = NSMenuItem(title: L10n.text(.menuPresetsEllipsis), action: #selector(menuManagePresets(_:)), keyEquivalent: "")
        presets.target = self
        menu.addItem(presets)
        return menu
    }

    private func siteMenuTitle(name: String, hotkey: String, unread: Bool = false) -> NSAttributedString {
        let compactName = (unread ? "● " : "") + compactMenuName(name)
        let text = "\(compactName)\t\(hotkey)"
        let result = NSMutableAttributedString(string: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 156)]
        paragraph.defaultTabInterval = 156
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ], range: fullRange)
        if !hotkey.isEmpty {
            let shortcutRange = (text as NSString).range(of: hotkey, options: .backwards)
            result.addAttribute(.foregroundColor,
                            value: NSColor.secondaryLabelColor.withAlphaComponent(0.72),
                            range: shortcutRange)
        }
        if unread { result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 1)) }
        return result
    }

    private func compactMenuName(_ name: String) -> String {
        name.count > 18 ? "\(name.prefix(17))…" : name
    }

    private func buildMenu(for pinID: UUID?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String,
                 action: Selector? = nil,
                 represented: UUID? = nil,
                 state: Bool = false,
                 enabled: Bool = true,
                 key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isEnabled = enabled
            item.state = state ? .on : .off
            if let represented { item.representedObject = represented.uuidString }
            menu.addItem(item)
        }

        if let pin = pinID.flatMap({ pinStore.pin(with: $0) }) {
            add(L10n.text(.menuReload), action: #selector(menuReload(_:)), represented: pin.id)
            add(L10n.text(.menuClearCacheAndReload),
                action: #selector(menuClearCacheAndReload(_:)), represented: pin.id)
            menu.addItem(buildPageZoomMenuItem(for: pin))
            menu.addItem(buildNotificationMenu(for: pin))
            add(pin.isMuted ? L10n.text(.menuUnmute) : L10n.text(.menuMute),
                action: #selector(menuToggleMute(_:)), represented: pin.id)
            add(L10n.text(.menuOpenInDefaultBrowser), action: #selector(menuOpenExternal(_:)), represented: pin.id)
            add(L10n.text(.menuEditSiteEllipsis), action: #selector(menuEditPin(_:)), represented: pin.id)

            if let hotkey = HotkeyManager.shared.label(for: pin.id) {
                add(L10n.text(.menuGlobalShortcut, hotkey), enabled: false)
            }
            add(L10n.text(.menuCloseSite, pin.name), action: #selector(menuCloseTab(_:)), represented: pin.id)
            menu.addItem(.separator())
        }

        add(L10n.text(.menuNewSiteEllipsis), action: #selector(menuNewPin(_:)))
        menu.addItem(buildPresetsMenuItem())
        add(L10n.text(.menuManagePresetsEllipsis), action: #selector(menuManagePresets(_:)))
        add(settingsRead.statusIconMode == .expanded
                ? L10n.text(.menuCollapseIcons)
                : L10n.text(.menuExpandIcons),
            action: #selector(menuToggleIconMode(_:)))
        menu.addItem(.separator())
        add(L10n.text(.menuHideOutside),
            action: #selector(menuToggleHideOnOutside(_:)),
            state: settingsRead.hideOnOutsideClick)
        add(L10n.text(.menuLaunchAtLogin),
            action: #selector(menuToggleLaunchAtLogin(_:)),
            state: launchAtLoginEnabled)
        menu.addItem(.separator())
        add(L10n.text(.menuAbout), action: #selector(menuAbout(_:)))
        add(L10n.text(.menuQuit), action: #selector(menuQuit(_:)), key: "q")
        return menu
    }

    private struct NotificationPermissionChoice {
        let pinID: UUID
        let origin: String
        let permission: WebNotificationPermission
    }

    func buildNotificationMenu(for pin: Pin) -> NSMenuItem {
        let root = NSMenuItem(title: L10n.text(.notificationMenu), action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let origin = registry?.notificationOrigin(for: pin.id) {
            let heading = NSMenuItem(title: origin, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            let choices: [(L10nKey, WebNotificationPermission)] = [
                (.notificationAllowOrigin, .granted), (.notificationDenyOrigin, .denied),
                (.notificationAskOrigin, .ask),
            ]
            for (title, permission) in choices {
                let item = NSMenuItem(title: L10n.text(title), action: #selector(menuSetNotificationPermission(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NotificationPermissionChoice(pinID: pin.id, origin: origin, permission: permission)
                item.state = WebNotificationPolicy.permission(for: pin, origin: origin) == permission ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let toggle = NSMenuItem(title: L10n.text(.notificationEnabled),
                                action: #selector(menuToggleNotifications(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = pin.id.uuidString
        toggle.state = pin.notificationsEnabled ? .on : .off
        menu.addItem(toggle)
        let reset = NSMenuItem(title: L10n.text(.notificationResetPermissions),
                               action: #selector(menuResetNotificationPermissions(_:)), keyEquivalent: "")
        reset.target = self
        reset.representedObject = pin.id.uuidString
        reset.isEnabled = !pin.notificationPermissions.isEmpty
        menu.addItem(reset)
        root.submenu = menu
        return root
    }

    private func buildPageZoomMenuItem(for pin: Pin) -> NSMenuItem {
        let root = NSMenuItem(
            title: L10n.text(.menuPageZoomWithPercent, PageZoom.percent(pin.pageZoom)),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu(title: L10n.text(.menuPageZoom))
        submenu.autoenablesItems = false

        func add(_ title: String, action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = pin.id.uuidString
            item.isEnabled = enabled
            submenu.addItem(item)
        }

        add(L10n.text(.menuZoomIn), action: #selector(menuZoomIn(_:)),
            enabled: pin.pageZoom < PageZoom.maximum)
        add(L10n.text(.menuZoomOut), action: #selector(menuZoomOut(_:)),
            enabled: pin.pageZoom > PageZoom.minimum)
        add(L10n.text(.menuZoomReset, PageZoom.percent(PageZoom.defaultValue)),
            action: #selector(menuResetZoom(_:)),
            enabled: PageZoom.normalized(pin.pageZoom) != PageZoom.defaultValue)
        root.submenu = submenu
        return root
    }

    private func buildPresetsMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: L10n.text(.menuPresets), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: L10n.text(.menuPresets))
        submenu.autoenablesItems = false

        if pinStore.presets.isEmpty {
            let empty = NSMenuItem(title: L10n.text(.menuNoPresets), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for preset in pinStore.presets {
                let hotkey = HotkeyManager.shared.label(for: preset.id)
                let item = NSMenuItem(title: compactMenuName(preset.name), action: #selector(menuOpenPreset(_:)), keyEquivalent: "")
                if let hotkey { item.attributedTitle = siteMenuTitle(name: preset.name, hotkey: hotkey) }
                item.target = self
                item.representedObject = preset.id.uuidString
                item.state = pinStore.pin(with: preset.id) == nil ? .off : .on
                item.image = displayImage(for: preset, side: 16)
                submenu.addItem(item)
            }
        }
        root.submenu = submenu
        return root
    }

    private func panelVisible(_ id: UUID) -> Bool {
        registry?.isVisible(id) ?? false
    }

    private var settingsRead: AppSettings {
        settingsProvider()
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - 菜单动作（转发给注册表）

    @objc private func menuSetNotificationPermission(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NotificationPermissionChoice,
              registry?.notificationOrigin(for: choice.pinID) == choice.origin,
              var pin = pinStore.pin(with: choice.pinID) else { return }
        pin.notificationsEnabled = true
        pin.notificationPermissions[choice.origin] = choice.permission == .ask ? nil : choice.permission
        _ = pinStore.update(pin)
        registry?.sync(with: pinStore.pins)
        if choice.permission != .granted { registry?.markNotificationsRead(pin.id) }
    }

    @objc private func menuToggleNotifications(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender), var pin = pinStore.pin(with: id) else { return }
        pin.notificationsEnabled.toggle()
        _ = pinStore.update(pin)
        if !pin.notificationsEnabled { registry?.markNotificationsRead(id) }
    }

    @objc private func menuResetNotificationPermissions(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender), var pin = pinStore.pin(with: id) else { return }
        pin.notificationPermissions = [:]
        _ = pinStore.update(pin)
        registry?.markNotificationsRead(id)
    }

    @objc private func menuSelectTab(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.toggle(pinID: id)
    }
    @objc private func menuReload(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.reload()
    }
    @objc private func menuClearCacheAndReload(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.clearCacheAndReload()
    }
    @objc private func menuToggleMute(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.toggleMute()
        sync(with: pinStore.pins)
    }
    @objc private func menuZoomIn(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.zoomIn()
    }
    @objc private func menuZoomOut(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.zoomOut()
    }
    @objc private func menuResetZoom(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.resetZoom()
    }
    @objc private func menuOpenExternal(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.openExternal()
    }
    @objc private func menuEditPin(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.beginEdit(pinID: id)
    }
    @objc private func menuCloseTab(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        pinStore.close(id)
    }
    @objc private func menuNewPin(_ sender: NSMenuItem) {
        registry?.beginAdd()
    }
    @objc private func menuOpenPreset(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        if pinStore.pin(with: id) == nil {
            pinStore.openPreset(id)
        }
        registry?.show(pinID: id)
    }
    @objc private func menuManagePresets(_ sender: NSMenuItem) {
        registry?.showPresetManager()
    }
    @objc private func menuToggleIconMode(_ sender: NSMenuItem) {
        var settings = AppDelegate.sharedSettings.settings
        settings.statusIconMode = settings.statusIconMode == .expanded ? .collapsed : .expanded
        AppDelegate.sharedSettings.settings = settings
        registry?.hideAll(except: nil)
        sync(with: pinStore.pins)
    }
    @objc private func menuToggleHideOnOutside(_ sender: NSMenuItem) {
        AppDelegate.sharedSettings.settings.hideOnOutsideClick.toggle()
    }
    @objc private func menuToggleLaunchAtLogin(_ sender: NSMenuItem) {
        AppDelegate.setLaunchAtLogin(!launchAtLoginEnabled)
    }
    @objc private func menuAbout(_ sender: NSMenuItem) {
        registry?.showAbout()
    }
    @objc private func menuQuit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func uuid(from sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
    }
}
