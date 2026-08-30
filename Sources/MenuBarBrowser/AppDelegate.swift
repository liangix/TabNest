import AppKit
import Combine
import ServiceManagement
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 全局共享设置（供菜单等处直接读取）
    static let sharedSettings = SettingsStore()

    private let pinStore = PinStore.shared
    private var formWindow: FormWindowController!
    private var windowManager: WindowManager!
    private var statusItemManager: StatusItemManager!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不显示 Dock 图标
        installEditMenu()                        // 让 ⌘C/⌘V 在网页输入框中生效

        formWindow = FormWindowController(pinStore: pinStore)
        windowManager = WindowManager(pinStore: pinStore, formWindow: formWindow)

        statusItemManager = StatusItemManager(pinStore: pinStore, favicon: .shared)
        statusItemManager.attach(registry: windowManager)
        windowManager.statusItemManager = statusItemManager

        // 预设变化 → 同步全局快捷键；关闭的预设也可通过快捷键重新打开。
        pinStore.$presets
            .removeDuplicates()
            .sink { presets in
                HotkeyManager.shared.update(pins: presets)
            }
            .store(in: &cancellables)

        // 打开的 Tab 变化 → 同步图标与窗口。
        pinStore.$pins
            .removeDuplicates()
            .sink { [weak self] pins in
                guard let self else { return }
                self.windowManager.sync(with: pins)
                self.statusItemManager.sync(with: pins)
            }
            .store(in: &cancellables)

        // 首次启动引导：无站点时直接打开添加窗口
        let launchedKey = "MenuBarBrowser.hasLaunchedBefore"
        if !UserDefaults.standard.bool(forKey: launchedKey) {
            UserDefaults.standard.set(true, forKey: launchedKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if self.pinStore.pins.isEmpty {
                    self.formWindow.presentAdd()
                } else if let first = self.pinStore.pins.first {
                    self.windowManager.show(pinID: first.id)
                }
                mbbTrace("首次启动引导完成")
            }
        }
        mbbTrace("启动完成，菜单栏图标就绪（站点数 \(pinStore.pins.count)）")
    }

    static func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            sharedSettings.settings.launchAtLogin = enabled
        } catch {
            NSLog("TabNest: 设置登录自启失败 \(error.localizedDescription)")
        }
    }

    // MARK: - Edit 菜单（保证网页/表单中复制粘贴快捷键可用）

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager?.stopMonitoring()
    }
}
