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
    @State private var notificationsEnabled = true
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                labeledRow(L10n.text(.formURL)) {
                    TextField(L10n.text(.formURLPlaceholder), text: $urlString)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
                labeledRow(L10n.text(.formName)) {
                    TextField(L10n.text(.formNamePlaceholder), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }

                labeledRow(L10n.text(.formBrowserIdentity)) {
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
                            TextField(L10n.text(.formCustomUAPlaceholder), text: $customUA)
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

                labeledRow(L10n.text(.formAutoRefresh)) {
                    Picker("", selection: $refreshInterval) {
                        Text(L10n.text(.formRefreshOff)).tag(TimeInterval(0))
                        Text(L10n.text(.formRefresh30Seconds)).tag(TimeInterval(30))
                        Text(L10n.text(.formRefresh1Minute)).tag(TimeInterval(60))
                        Text(L10n.text(.formRefresh5Minutes)).tag(TimeInterval(300))
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                labeledRow(L10n.text(.notificationMenu)) {
                    Toggle(L10n.text(.notificationEnabled), isOn: $notificationsEnabled)
                        .toggleStyle(.checkbox)
                }

                labeledRow(L10n.text(.formHotkey)) {
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
                                Text(L10n.text(.hotkeyAutomaticDescription))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if hotkeyMode == .custom {
                                HStack(spacing: 8) {
                                    HotkeyRecorder(shortcut: $customHotkey)
                                    if customHotkey != nil {
                                        Button(L10n.text(.commonClear)) { customHotkey = nil }
                                            .buttonStyle(.link)
                                    }
                                }
                            } else {
                                Text(L10n.text(.hotkeyDisabledDescription))
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
                Button(L10n.text(.commonCancel), action: onCancel).keyboardShortcut(.cancelAction)
                Button(isEditing ? L10n.text(.commonSave) : L10n.text(.commonAdd), action: submit)
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
                .frame(width: L10n.language == .english ? 88 : 64, alignment: .trailing)
            content()
        }
    }

    // MARK: - 逻辑

    private var uaDescription: String {
        switch uaMode {
        case .system: return L10n.text(.uaSystemDescription)
        case .desktop: return L10n.text(.uaDesktopDescription)
        case .mobile: return L10n.text(.uaMobileDescription)
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
        notificationsEnabled = pin.notificationsEnabled
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
        candidate.notificationsEnabled = notificationsEnabled
        candidate.notificationPermissions = editingPin?.notificationPermissions ?? [:]
        guard let resolvedURL = candidate.url,
              ["http", "https"].contains(resolvedURL.scheme?.lowercased() ?? "") else {
            errorMessage = L10n.text(.formErrorInvalidURL)
            return
        }
        if uaMode == .custom && candidate.customUserAgent.isEmpty {
            errorMessage = L10n.text(.formErrorCustomUA)
            return
        }
        if hotkeyMode == .custom && customHotkey == nil {
            errorMessage = L10n.text(.formErrorCustomHotkey)
            return
        }

        candidate.urlString = resolvedURL.absoluteString
        if candidate.name.isEmpty {
            candidate.name = resolvedURL.host ?? L10n.text(.formUnnamedSite)
        }
        if let original = editingPin,
           original.canonicalURLString != candidate.canonicalURLString {
            candidate.iconURLString = ""
        }
        errorMessage = nil
        if !onSave(candidate) {
            errorMessage = L10n.text(.formErrorDuplicateURL)
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
