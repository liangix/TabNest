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

    private let pinStore: PinStore
    private weak var registry: WindowManager?

    init(pinStore: PinStore, favicon: FaviconCache) {
        self.pinStore = pinStore
        self.favicon = favicon
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
        if settingsRead.statusIconMode == .collapsed {
            removeExpandedItems()
            syncCollapsedItem(visible: true)
            collapsedItem?.button?.toolTip = "TabNest（\(pins.count) 个 Tab）"
            syncPlaceholder(pinsNeedPlaceholder: false)
            registry?.rebindStatusItems()
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
        registry?.rebindStatusItems()
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
            item.button?.toolTip = "TabNest（\(pinStore.pins.count) 个 Tab）"
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
        button.toolTip = hotkey.map { "\(pin.name)（\($0) 全局唤起）" } ?? pin.name
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
                                             accessibilityDescription: "TabNest 菜单栏浏览器")
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
                popUpMenu(for: collapsedItem, menu: buildMenu(for: nil))
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
            let empty = NSMenuItem(title: "没有打开的 Tab", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for pin in pinStore.pins {
                let hotkey = HotkeyManager.shared.label(for: pin.id)
                let item = NSMenuItem(title: compactMenuName(pin.name), action: #selector(menuSelectTab(_:)), keyEquivalent: "")
                if let hotkey { item.attributedTitle = siteMenuTitle(name: pin.name, hotkey: hotkey) }
                item.target = self
                item.representedObject = pin.id.uuidString
                item.state = panelVisible(pin.id) ? .on : .off
                item.image = displayImage(for: pin, side: 16)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let presets = NSMenuItem(title: "预设站点…", action: #selector(menuManagePresets(_:)), keyEquivalent: "")
        presets.target = self
        menu.addItem(presets)
        return menu
    }

    private func siteMenuTitle(name: String, hotkey: String) -> NSAttributedString {
        let compactName = compactMenuName(name)
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
        let shortcutRange = (text as NSString).range(of: hotkey, options: .backwards)
        result.addAttribute(.foregroundColor,
                            value: NSColor.secondaryLabelColor.withAlphaComponent(0.72),
                            range: shortcutRange)
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
            add("重新载入", action: #selector(menuReload(_:)), represented: pin.id)
            add(pin.isMuted ? "取消静音" : "静音",
                action: #selector(menuToggleMute(_:)), represented: pin.id)
            add("在默认浏览器打开", action: #selector(menuOpenExternal(_:)), represented: pin.id)
            add("编辑站点…", action: #selector(menuEditPin(_:)), represented: pin.id)

            if let hotkey = HotkeyManager.shared.label(for: pin.id) {
                add("全局唤起 \(hotkey)", enabled: false)
            }
            add("关闭「\(pin.name)」", action: #selector(menuCloseTab(_:)), represented: pin.id)
            menu.addItem(.separator())
        }

        add("新建站点…", action: #selector(menuNewPin(_:)))
        menu.addItem(buildPresetsMenuItem())
        add("管理预设站点…", action: #selector(menuManagePresets(_:)))
        add(settingsRead.statusIconMode == .expanded ? "收拢为一个图标" : "展开为每个 Tab 图标",
            action: #selector(menuToggleIconMode(_:)))
        menu.addItem(.separator())
        add("点击面板外部时自动隐藏",
            action: #selector(menuToggleHideOnOutside(_:)),
            state: settingsRead.hideOnOutsideClick)
        add("登录时启动",
            action: #selector(menuToggleLaunchAtLogin(_:)),
            state: launchAtLoginEnabled)
        menu.addItem(.separator())
        add("关于 TabNest", action: #selector(menuAbout(_:)))
        add("退出", action: #selector(menuQuit(_:)), key: "q")
        return menu
    }

    private func buildPresetsMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "预设站点", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "预设站点")
        submenu.autoenablesItems = false

        if pinStore.presets.isEmpty {
            let empty = NSMenuItem(title: "没有预设站点", action: nil, keyEquivalent: "")
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
        AppDelegate.sharedSettings.settings
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - 菜单动作（转发给注册表）

    @objc private func menuSelectTab(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.toggle(pinID: id)
    }
    @objc private func menuReload(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.reload()
    }
    @objc private func menuToggleMute(_ sender: NSMenuItem) {
        guard let id = uuid(from: sender) else { return }
        registry?.controller(for: id)?.toggleMute()
        sync(with: pinStore.pins)
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
