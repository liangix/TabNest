import SwiftUI

/// 添加 / 编辑固定站点的表单。
struct PinFormView: View {
    enum Mode {
        case add
        case edit(Pin)
    }

    let mode: Mode
    let onSave: (Pin) -> Bool
    let onCancel: () -> Void

    @State private var urlString: String = ""
    @State private var name: String = ""
    @State private var uaMode: UserAgentMode = .system
    @State private var customUA: String = ""
    @State private var refreshInterval: TimeInterval = 0
    @State private var hotkeyMode: HotkeyMode = .automatic
    @State private var customHotkey: SiteHotkey?
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                labeledRow("网址") {
                    TextField("example.com 或 https://…", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
                labeledRow("名称") {
                    TextField("可选，默认使用域名", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }

                labeledRow("浏览器标识") {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("", selection: $uaMode) {
                            ForEach(UserAgentMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        Group {
                            if uaMode == .custom {
                            TextField("输入完整的 User-Agent", text: $customUA)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            } else {
                                Text(uaDescription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(height: 24)
                    }
                    .frame(maxWidth: .infinity)
                }

                labeledRow("自动刷新") {
                    Picker("", selection: $refreshInterval) {
                        Text("关闭").tag(TimeInterval(0))
                        Text("每 30 秒").tag(TimeInterval(30))
                        Text("每 1 分钟").tag(TimeInterval(60))
                        Text("每 5 分钟").tag(TimeInterval(300))
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                labeledRow("快捷键") {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("", selection: $hotkeyMode) {
                            ForEach(HotkeyMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        Group {
                            if hotkeyMode == .automatic {
                                Text("按预设顺序使用 ⌥⇧1–9")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if hotkeyMode == .custom {
                                HStack(spacing: 8) {
                                    HotkeyRecorder(shortcut: $customHotkey)
                                    if customHotkey != nil {
                                        Button("清除") { customHotkey = nil }
                                            .buttonStyle(.link)
                                    }
                                }
                            } else {
                                Text("不注册全局快捷键")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(height: 28)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .onAppear(perform: loadInitialValues)
    }

    // MARK: - 子视图

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.subheadline)
                .frame(width: 64, alignment: .trailing)
            content()
        }
    }

    // MARK: - 逻辑

    private var uaDescription: String {
        switch uaMode {
        case .system: return "使用当前系统 Safari 版本 UA，随系统更新（推荐）"
        case .desktop: return "使用固定 Safari 18.6 UA，兼容限制内嵌浏览器的网站"
        case .mobile: return "模拟移动端 Safari 18.6"
        case .custom: return ""
        }
    }

    private func loadInitialValues() {
        guard case .edit(let pin) = mode else { return }
        urlString = pin.urlString
        name = pin.name
        uaMode = pin.userAgentMode
        customUA = pin.customUserAgent
        refreshInterval = pin.refreshInterval
        hotkeyMode = pin.hotkeyMode
        customHotkey = pin.customHotkey
    }

    private func submit() {
        var candidate = Pin(
            id: editingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            urlString: urlString.trimmingCharacters(in: .whitespacesAndNewlines),
            userAgentMode: uaMode,
            customUserAgent: customUA.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshInterval: refreshInterval,
            pageZoom: editingPageZoom,
            isMuted: editingMuted,
            iconURLString: editingIconURL,
            hotkeyMode: hotkeyMode,
            customHotkey: customHotkey
        )
        guard let resolvedURL = candidate.url,
              ["http", "https"].contains(resolvedURL.scheme?.lowercased() ?? "") else {
            errorMessage = "无法识别的网址，请检查格式"
            return
        }
        if uaMode == .custom && candidate.customUserAgent.isEmpty {
            errorMessage = "请输入自定义 User-Agent"
            return
        }
        if hotkeyMode == .custom && customHotkey == nil {
            errorMessage = "请录入自定义快捷键，或选择自动/关闭"
            return
        }

        candidate.urlString = resolvedURL.absoluteString
        if candidate.name.isEmpty {
            candidate.name = resolvedURL.host ?? "未命名站点"
        }
        if let original = editingPin,
           original.canonicalURLString != candidate.canonicalURLString {
            candidate.iconURLString = ""
        }
        errorMessage = nil
        if !onSave(candidate) {
            errorMessage = "该网址已存在"
        }
    }

    private var editingID: UUID? {
        if case .edit(let pin) = mode { return pin.id }
        return nil
    }

    private var editingPin: Pin? {
        if case .edit(let pin) = mode { return pin }
        return nil
    }

    private var editingMuted: Bool {
        if case .edit(let pin) = mode { return pin.isMuted }
        return false
    }

    private var editingPageZoom: Double {
        if case .edit(let pin) = mode { return pin.pageZoom }
        return PageZoom.defaultValue
    }

    private var editingIconURL: String {
        if case .edit(let pin) = mode { return pin.iconURLString }
        return ""
    }
}
