import Foundation

/// 标签页状态快照，供面板渲染进度条等反馈。
struct TabState: Equatable {
    var title: String = "正在加载…"
    var urlString: String = ""
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
}

enum UserAgentMode: String, Codable, CaseIterable, Identifiable {
    case system
    case desktop
    case mobile
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "系统默认"
        case .desktop: return "桌面"
        case .mobile: return "移动端"
        case .custom: return "自定义"
        }
    }
}

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case custom
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .custom: return "自定义"
        case .disabled: return "关闭"
        }
    }
}

enum StatusIconMode: String, Codable, CaseIterable, Identifiable {
    case collapsed
    case expanded

    var id: String { rawValue }
}

/// 与 Carbon 常量解耦的快捷键持久化格式。
struct SiteHotkey: Codable, Equatable {
    static let command: UInt32 = 1 << 0
    static let option: UInt32 = 1 << 1
    static let control: UInt32 = 1 << 2
    static let shift: UInt32 = 1 << 3

    var keyCode: UInt32
    var modifiers: UInt32
    var keyDisplay: String

    var displayName: String {
        var result = ""
        if modifiers & Self.control != 0 { result += "⌃" }
        if modifiers & Self.option != 0 { result += "⌥" }
        if modifiers & Self.shift != 0 { result += "⇧" }
        if modifiers & Self.command != 0 { result += "⌘" }
        return result + keyDisplay.uppercased()
    }
}

struct Pin: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var urlString: String
    var userAgentMode: UserAgentMode = .system
    var customUserAgent: String = ""
    var refreshInterval: TimeInterval = 0   // 0 = 关闭自动刷新
    var isMuted: Bool = false
    var iconURLString: String = ""
    var hotkeyMode: HotkeyMode = .automatic
    var customHotkey: SiteHotkey?

    var url: URL? {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") {
            // 常见搜索词处理：无点号或含中文时走搜索
            if !s.contains(".") || s.range(of: "[\\u4e00-\\u9fff]") != nil {
                var comps = URLComponents(string: "https://www.bing.com/search")!
                comps.queryItems = [URLQueryItem(name: "q", value: s)]
                return comps.url
            }
            s = "https://" + s
        }
        return URL(string: s)
    }

    var host: String {
        url?.host ?? ""
    }

    /// 用于判重与识别编辑时地址是否真正发生变化。
    var canonicalURLString: String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" { components.path = "" }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, urlString, userAgentMode, customUserAgent, refreshInterval
        case isMuted, iconURLString, hotkeyMode, customHotkey
    }

    init(id: UUID = UUID(), name: String, urlString: String,
         userAgentMode: UserAgentMode = .system, customUserAgent: String = "",
         refreshInterval: TimeInterval = 0, isMuted: Bool = false,
         iconURLString: String = "", hotkeyMode: HotkeyMode = .automatic,
         customHotkey: SiteHotkey? = nil) {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.userAgentMode = userAgentMode
        self.customUserAgent = customUserAgent
        self.refreshInterval = refreshInterval
        self.isMuted = isMuted
        self.iconURLString = iconURLString
        self.hotkeyMode = hotkeyMode
        self.customHotkey = customHotkey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        urlString = try c.decode(String.self, forKey: .urlString)
        userAgentMode = try c.decodeIfPresent(UserAgentMode.self, forKey: .userAgentMode) ?? .system
        customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent) ?? ""
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        iconURLString = try c.decodeIfPresent(String.self, forKey: .iconURLString) ?? ""
        hotkeyMode = try c.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .automatic
        customHotkey = try c.decodeIfPresent(SiteHotkey.self, forKey: .customHotkey)
    }
}

struct AppSettings: Codable, Equatable {
    var hideOnOutsideClick: Bool = true
    var rememberPanelFrame: Bool = true
    var launchAtLogin: Bool = false
    var statusIconMode: StatusIconMode = .expanded

    static let defaultsKey = "MenuBarBrowser.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case hideOnOutsideClick, rememberPanelFrame, launchAtLogin, statusIconMode
    }

    init(hideOnOutsideClick: Bool = true, rememberPanelFrame: Bool = true,
         launchAtLogin: Bool = false, statusIconMode: StatusIconMode = .expanded) {
        self.hideOnOutsideClick = hideOnOutsideClick
        self.rememberPanelFrame = rememberPanelFrame
        self.launchAtLogin = launchAtLogin
        self.statusIconMode = statusIconMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideOnOutsideClick = try c.decodeIfPresent(Bool.self, forKey: .hideOnOutsideClick) ?? true
        rememberPanelFrame = try c.decodeIfPresent(Bool.self, forKey: .rememberPanelFrame) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        statusIconMode = try c.decodeIfPresent(StatusIconMode.self, forKey: .statusIconMode) ?? .expanded
    }
}
