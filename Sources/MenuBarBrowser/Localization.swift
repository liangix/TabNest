import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// TabNest currently supports English and Chinese. The primary system/app
    /// language decides which one is used; every unsupported language falls
    /// back to English instead of inheriting a secondary preferred language.
    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        guard let primary = preferredLanguages.first else { return .english }
        let normalized = primary.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized == "zh" || normalized.hasPrefix("zh-")
            ? .simplifiedChinese
            : .english
    }
}

enum L10nKey: String, CaseIterable {
    case loading = "state.loading"

    case uaSystem = "ua.system"
    case uaDesktop = "ua.desktop"
    case uaMobile = "ua.mobile"
    case uaCustom = "ua.custom"
    case uaSystemDescription = "ua.system.description"
    case uaDesktopDescription = "ua.desktop.description"
    case uaMobileDescription = "ua.mobile.description"

    case hotkeyAutomatic = "hotkey.automatic"
    case hotkeyCustom = "hotkey.custom"
    case hotkeyDisabled = "hotkey.disabled"
    case hotkeyRecordPrompt = "hotkey.record.prompt"
    case hotkeyRecordIdle = "hotkey.record.idle"
    case hotkeyAutomaticDescription = "hotkey.automatic.description"
    case hotkeyDisabledDescription = "hotkey.disabled.description"

    case commonAdd = "common.add"
    case commonCancel = "common.cancel"
    case commonSave = "common.save"
    case commonOpen = "common.open"
    case commonClose = "common.close"
    case commonEdit = "common.edit"
    case commonClear = "common.clear"
    case commonOK = "common.ok"
    case commonAllow = "common.allow"
    case commonDeny = "common.deny"

    case editMenu = "edit.menu"
    case editUndo = "edit.undo"
    case editRedo = "edit.redo"
    case editCut = "edit.cut"
    case editCopy = "edit.copy"
    case editPaste = "edit.paste"
    case editSelectAll = "edit.selectAll"

    case windowAddSite = "window.addSite"
    case windowEditSite = "window.editSite"
    case windowAbout = "window.about"
    case windowPresets = "window.presets"

    case formURL = "form.url"
    case formURLPlaceholder = "form.url.placeholder"
    case formName = "form.name"
    case formNamePlaceholder = "form.name.placeholder"
    case formBrowserIdentity = "form.browserIdentity"
    case formCustomUAPlaceholder = "form.customUA.placeholder"
    case formAutoRefresh = "form.autoRefresh"
    case formRefreshOff = "form.refresh.off"
    case formRefresh30Seconds = "form.refresh.30seconds"
    case formRefresh1Minute = "form.refresh.1minute"
    case formRefresh5Minutes = "form.refresh.5minutes"
    case formHotkey = "form.hotkey"
    case formErrorInvalidURL = "form.error.invalidURL"
    case formErrorCustomUA = "form.error.customUA"
    case formErrorCustomHotkey = "form.error.customHotkey"
    case formErrorDuplicateURL = "form.error.duplicateURL"
    case formUnnamedSite = "form.unnamedSite"

    case presetsEmpty = "presets.empty"
    case presetsDeleteHelp = "presets.delete.help"
    case presetsCloseKeepsPreset = "presets.closeKeepsPreset"
    case presetsAddSiteEllipsis = "presets.addSite.ellipsis"

    case aboutSubtitle = "about.subtitle"
    case aboutInstructions = "about.instructions"

    case statusTabsCount = "status.tabs.count"
    case statusGlobalShortcutTooltip = "status.globalShortcut.tooltip"
    case statusAccessibilityDescription = "status.accessibilityDescription"

    case menuNoOpenTabs = "menu.noOpenTabs"
    case menuPresetsEllipsis = "menu.presets.ellipsis"
    case menuReload = "menu.reload"
    case menuMute = "menu.mute"
    case menuUnmute = "menu.unmute"
    case menuOpenInDefaultBrowser = "menu.openInDefaultBrowser"
    case menuEditSiteEllipsis = "menu.editSite.ellipsis"
    case menuGlobalShortcut = "menu.globalShortcut"
    case menuCloseSite = "menu.closeSite"
    case menuNewSiteEllipsis = "menu.newSite.ellipsis"
    case menuManagePresetsEllipsis = "menu.managePresets.ellipsis"
    case menuCollapseIcons = "menu.collapseIcons"
    case menuExpandIcons = "menu.expandIcons"
    case menuHideOutside = "menu.hideOutside"
    case menuLaunchAtLogin = "menu.launchAtLogin"
    case menuAbout = "menu.about"
    case menuQuit = "menu.quit"
    case menuPageZoomWithPercent = "menu.pageZoom.percent"
    case menuPageZoom = "menu.pageZoom"
    case menuZoomIn = "menu.zoomIn"
    case menuZoomOut = "menu.zoomOut"
    case menuZoomReset = "menu.zoomReset"
    case menuPresets = "menu.presets"
    case menuNoPresets = "menu.noPresets"

    case microphonePermissionTitle = "microphone.permission.title"
    case microphonePermissionMessage = "microphone.permission.message"
    case webMessageTitle = "web.message.title"
}

enum L10n {
    static let language = AppLanguage.resolve(preferredLanguages: Locale.preferredLanguages)
    private static let resourceBundle = locateResourceBundle()

    static func text(_ key: L10nKey, _ arguments: CVarArg...) -> String {
        text(key, language: language, arguments: arguments)
    }

    static func text(_ key: L10nKey,
                     language: AppLanguage,
                     _ arguments: CVarArg...) -> String {
        text(key, language: language, arguments: arguments)
    }

    private static func text(_ key: L10nKey,
                             language: AppLanguage,
                             arguments: [CVarArg]) -> String {
        let localized = localizedFormat(for: key, language: language)
        guard !arguments.isEmpty else { return localized }
        return String(format: localized,
                      locale: Locale(identifier: language.rawValue),
                      arguments: arguments)
    }

    private static func localizedFormat(for key: L10nKey, language: AppLanguage) -> String {
        let selected = bundle(for: language)
        let value = selected.localizedString(forKey: key.rawValue, value: nil, table: nil)
        if value != key.rawValue || language == .english { return value }

        return bundle(for: .english)
            .localizedString(forKey: key.rawValue, value: key.rawValue, table: nil)
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = resourceBundle.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return resourceBundle
        }
        return bundle
    }

    private static func locateResourceBundle() -> Bundle {
        let bundleName = "MenuBarBrowser_MenuBarBrowser.bundle"

        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent(bundleName)) {
            return bundle
        }
        if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(bundleName)) {
            return bundle
        }
        return Bundle.module
    }
}
