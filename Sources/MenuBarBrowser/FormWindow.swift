import AppKit
import SwiftUI

/// 承载「添加/编辑站点」「关于」的独立小窗口（替代面板内 sheet）。
@MainActor
final class FormWindowController {
    private var window: NSWindow?
    private let pinStore: PinStore

    init(pinStore: PinStore) {
        self.pinStore = pinStore
    }

    func presentAdd() {
        let form = PinFormView(mode: .add) { [weak self] newPin in
            if self?.pinStore.add(newPin) == true {
                self?.pinStore.select(newPin.id)
                self?.close()
                return true
            }
            return false
        } onCancel: { [weak self] in
            self?.close()
        }

        present(view: form.frame(width: 440), title: L10n.text(.windowAddSite))
    }

    func presentEdit(_ pin: Pin) {
        let form = PinFormView(mode: .edit(pin)) { [weak self] updated in
            guard self?.pinStore.update(updated) == true else { return false }
            // 包括关闭状态的预设；刷新期间继续显示旧图标。
            FaviconCache.shared.refresh(pinID: updated.id)
            self?.close()
            return true
        } onCancel: { [weak self] in
            self?.close()
        }

        present(view: form.frame(width: 440), title: L10n.text(.windowEditSite))
    }

    func presentAbout() {
        present(view: AboutView().frame(width: 360, height: 280), title: L10n.text(.windowAbout))
    }

    func presentPresetManager() {
        let view = PresetManagerView(store: pinStore) { [weak self] in
            self?.presentAdd()
        } onEdit: { [weak self] pin in
            self?.presentEdit(pin)
        }
        present(view: view, title: L10n.text(.windowPresets))
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    private func present(view: some View, title: String) {
        close()

        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.contentView = hosting

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
