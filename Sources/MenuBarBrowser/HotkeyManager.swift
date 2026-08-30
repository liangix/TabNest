import AppKit
import Carbon.HIToolbox

/// 基于 Carbon RegisterEventHotKey 的全局快捷键（无需辅助功能权限）。
/// 约定：前 9 个站点自动分配 ⌥⇧1…⌥⇧9 唤起对应面板。
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// 快捷键触发的回调（主线程）
    var onHotkey: ((UUID) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var slotToPin: [UInt32: UUID] = [:]
    private var registeredShortcuts: [UUID: SiteHotkey] = [:]
    private var handlerInstalled = false
    private var handlerRef: EventHandlerRef?

    private static let signature: FourCharCode = 0x4D425242 // 'MBRB'
    /// 数字键 1–9 的虚拟键码（非连续）
    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func update(pins: [Pin]) {
        unregisterAll()

        guard pins.contains(where: { $0.hotkeyMode != .disabled }) else { return }
        installHandlerIfNeeded()

        for (index, pin) in pins.enumerated() {
            guard let shortcut = shortcut(for: pin, index: index) else { continue }
            let slot = UInt32(index)
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: slot)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                carbonModifiers(shortcut.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                slotToPin[slot] = pin.id
                registeredShortcuts[pin.id] = shortcut
            } else {
                NSLog("TabNest: 无法注册 \(pin.name) 的快捷键 \(shortcut.displayName)，状态码 \(status)")
            }
        }
    }

    /// 该站点对应的快捷键展示文本；未分配返回 nil。
    func label(for pinID: UUID) -> String? {
        registeredShortcuts[pinID]?.displayName
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        slotToPin.removeAll()
        registeredShortcuts.removeAll()
    }

    private func shortcut(for pin: Pin, index: Int) -> SiteHotkey? {
        switch pin.hotkeyMode {
        case .automatic:
            guard index < Self.digitKeyCodes.count else { return nil }
            return SiteHotkey(
                keyCode: Self.digitKeyCodes[index],
                modifiers: SiteHotkey.option | SiteHotkey.shift,
                keyDisplay: "\(index + 1)"
            )
        case .custom:
            return pin.customHotkey
        case .disabled:
            return nil
        }
    }

    private func carbonModifiers(_ modifiers: UInt32) -> UInt32 {
        var result: UInt32 = 0
        if modifiers & SiteHotkey.command != 0 { result |= UInt32(cmdKey) }
        if modifiers & SiteHotkey.option != 0 { result |= UInt32(optionKey) }
        if modifiers & SiteHotkey.control != 0 { result |= UInt32(controlKey) }
        if modifiers & SiteHotkey.shift != 0 { result |= UInt32(shiftKey) }
        return result
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            MainActor.assumeIsolated {
                HotkeyManager.shared.dispatch(hotKeyID)
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        if status == noErr {
            handlerInstalled = true
        } else {
            NSLog("TabNest: 全局快捷键事件处理器安装失败，状态码 \(status)")
        }
    }

    fileprivate func dispatch(_ hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == Self.signature,
              let pinID = slotToPin[hotKeyID.id] else { return }
        onHotkey?(pinID)
    }
}
