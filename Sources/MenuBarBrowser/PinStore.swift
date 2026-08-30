import Foundation
import Combine

/// 管理所有固定站点（Pins），并持久化到 UserDefaults。
@MainActor
final class PinStore: ObservableObject {
    /// 当前已打开的 Tab。
    @Published private(set) var pins: [Pin]
    /// 用户保存的站点预设；关闭 Tab 不会删除这里的数据。
    @Published private(set) var presets: [Pin]
    @Published var selectedPinID: UUID?

    static let shared = PinStore()

    private static let pinsKey = "MenuBarBrowser.pins"
    private static let presetsKey = "MenuBarBrowser.presets"
    private static let selectedKey = "MenuBarBrowser.selectedPin"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedTabs: [Pin]?
        if let data = defaults.data(forKey: Self.pinsKey) {
            do {
                savedTabs = try JSONDecoder().decode([Pin].self, from: data)
            } catch {
                NSLog("TabNest: 站点数据解码失败，保留原数据并载入默认站点：\(error)")
                savedTabs = nil
            }
        } else {
            savedTabs = nil
        }

        if let data = defaults.data(forKey: Self.presetsKey),
           let savedPresets = try? JSONDecoder().decode([Pin].self, from: data) {
            presets = savedPresets
            pins = savedTabs ?? []
            for tab in pins where !presets.contains(where: { $0.id == tab.id }) {
                presets.append(tab)
            }
        } else if let savedTabs {
            // 从旧版本迁移：原站点列表同时视为预设和已打开 Tab。
            presets = savedTabs
            pins = savedTabs
        } else {
            let defaults = Self.defaultPins()
            presets = defaults
            pins = defaults
        }
        selectedPinID = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        if selectedPinID == nil || !pins.contains(where: { $0.id == selectedPinID }) {
            selectedPinID = pins.first?.id
        }
        if defaults.data(forKey: Self.presetsKey) == nil {
            persistPresets()
        }
        if defaults.data(forKey: Self.pinsKey) == nil {
            persistTabs()
        }
    }

    func select(_ id: UUID?) {
        selectedPinID = id ?? pins.first?.id
        if let id = selectedPinID {
            defaults.set(id.uuidString, forKey: Self.selectedKey)
        }
    }

    @discardableResult
    func add(_ pin: Pin) -> Bool {
        guard !presets.contains(where: { $0.canonicalURLString == pin.canonicalURLString }) else { return false }
        presets.append(pin)
        pins.append(pin)
        persistAll()
        return true
    }

    @discardableResult
    func update(_ pin: Pin) -> Bool {
        guard let presetIndex = presets.firstIndex(where: { $0.id == pin.id }) else { return false }
        guard !presets.contains(where: {
            $0.id != pin.id && $0.canonicalURLString == pin.canonicalURLString
        }) else { return false }
        presets[presetIndex] = pin
        if let tabIndex = pins.firstIndex(where: { $0.id == pin.id }) {
            pins[tabIndex] = pin
        }
        persistAll()
        return true
    }

    /// 关闭 Tab，但保留站点预设。
    func close(_ id: UUID) {
        pins.removeAll { $0.id == id }
        if selectedPinID == id {
            select(pins.first?.id)
        }
        persistTabs()
    }

    /// 兼容旧调用；语义已改为关闭 Tab。
    func remove(_ id: UUID) {
        close(id)
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        pins.removeAll { $0.id == id }
        if selectedPinID == id { select(pins.first?.id) }
        persistAll()
    }

    @discardableResult
    func openPreset(_ id: UUID) -> Bool {
        guard !pins.contains(where: { $0.id == id }),
              let preset = preset(with: id) else { return false }
        pins.append(preset)
        select(id)
        persistTabs()
        return true
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        pins.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistTabs()
    }

    func pin(with id: UUID?) -> Pin? {
        guard let id else { return nil }
        return pins.first { $0.id == id }
    }

    func preset(with id: UUID?) -> Pin? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    /// 更新图标地址（由 WebView 抓取 favicon 后回调）
    func setIconURL(_ urlString: String, for pinID: UUID) {
        var changed = false
        if let idx = presets.firstIndex(where: { $0.id == pinID }),
           presets[idx].iconURLString != urlString {
            presets[idx].iconURLString = urlString
            changed = true
        }
        if let idx = pins.firstIndex(where: { $0.id == pinID }),
           pins[idx].iconURLString != urlString {
            pins[idx].iconURLString = urlString
            changed = true
        }
        if changed { persistAll() }
    }

    private func persistTabs() {
        if let data = try? JSONEncoder().encode(pins) {
            defaults.set(data, forKey: Self.pinsKey)
        }
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: Self.presetsKey)
        }
    }

    private func persistAll() {
        persistPresets()
        persistTabs()
    }

    private static func defaultPins() -> [Pin] {
        [
            Pin(name: "Bing", urlString: "https://www.bing.com"),
            Pin(name: "GitHub", urlString: "https://github.com"),
            Pin(name: "YouTube Music", urlString: "https://music.youtube.com",
                userAgentMode: .desktop, refreshInterval: 0),
            Pin(name: "ChatGPT", urlString: "https://chatgpt.com"),
        ]
    }
}
