import AppKit
import WebKit
import XCTest
@testable import MenuBarBrowser

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object?) { self.value = value }
}

final class ModelStoreTests: XCTestCase {
    func testLanguageResolutionUsesChineseAndFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh_Hant_TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-FR", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: []), .english)
    }

    func testEveryLocalizedKeyHasEnglishAndChineseValues() {
        for key in L10nKey.allCases {
            XCTAssertNotEqual(L10n.text(key, language: .english), key.rawValue, "Missing English: \(key)")
            XCTAssertNotEqual(L10n.text(key, language: .simplifiedChinese), key.rawValue,
                              "Missing Chinese: \(key)")
        }
        XCTAssertEqual(L10n.text(.commonCancel, language: .english), "Cancel")
        XCTAssertEqual(L10n.text(.commonCancel, language: .simplifiedChinese), "取消")
        XCTAssertEqual(L10n.text(.statusTabsCount, language: .english, 3), "TabNest (3 tabs)")
        XCTAssertEqual(L10n.text(.statusTabsCount, language: .simplifiedChinese, 3),
                       "TabNest（3 个 Tab）")
    }

    @MainActor
    func testInitialTabsSurviveRelaunch() throws {
        let suiteName = "MenuBarBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = PinStore(defaults: defaults)
        let initialIDs = first.pins.map(\.id)

        XCTAssertFalse(initialIDs.isEmpty)
        XCTAssertEqual(PinStore(defaults: defaults).pins.map(\.id), initialIDs)
    }

    @MainActor
    func testRemovingEveryPinPersistsEmptyList() throws {
        let suiteName = "MenuBarBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PinStore(defaults: defaults)
        let presetCount = store.presets.count
        for pin in store.pins {
            store.remove(pin.id)
        }

        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertEqual(store.presets.count, presetCount)
        let reloaded = PinStore(defaults: defaults)
        XCTAssertTrue(reloaded.pins.isEmpty)
        XCTAssertEqual(reloaded.presets.count, presetCount)
    }

    @MainActor
    func testClosedPresetCanBeOpenedAgain() throws {
        let suiteName = "MenuBarBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PinStore(defaults: defaults)
        let preset = try XCTUnwrap(store.presets.first)

        store.close(preset.id)
        XCTAssertNil(store.pin(with: preset.id))
        XCTAssertNotNil(store.preset(with: preset.id))
        XCTAssertTrue(store.openPreset(preset.id))
        XCTAssertNotNil(store.pin(with: preset.id))
    }

    func testLegacyPinDecodingUsesSafeDefaults() throws {
        let json = """
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "name":"Example",
          "urlString":"https://example.com"
        }
        """
        let pin = try JSONDecoder().decode(Pin.self, from: Data(json.utf8))

        XCTAssertEqual(pin.userAgentMode, .system)
        XCTAssertEqual(pin.hotkeyMode, .automatic)
        XCTAssertNil(pin.customHotkey)
        XCTAssertFalse(pin.isMuted)
        XCTAssertEqual(pin.pageZoom, PageZoom.defaultValue)
    }

    func testPageZoomIsSteppedAndClamped() {
        XCTAssertEqual(PageZoom.increased(0.9), 1.0)
        XCTAssertEqual(PageZoom.decreased(0.9), 0.8)
        XCTAssertEqual(PageZoom.normalized(0.94), 0.9)
        XCTAssertEqual(PageZoom.normalized(4), PageZoom.maximum)
        XCTAssertEqual(PageZoom.normalized(0.1), PageZoom.minimum)
        XCTAssertEqual(PageZoom.percent(0.9), 90)
    }

    @MainActor
    func testFreshInstallDefaultPresetNames() throws {
        let suiteName = "MenuBarBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(PinStore(defaults: defaults).presets.map(\.name), [
            "Bing", "GitHub", "YouTube Music", "ChatGPT",
        ])
    }

    func testCanonicalURLNormalizesHostCaseAndRootSlash() {
        let first = Pin(name: "A", urlString: "HTTPS://EXAMPLE.COM/")
        let second = Pin(name: "B", urlString: "https://example.com")
        XCTAssertEqual(first.canonicalURLString, second.canonicalURLString)
    }

    func testSiteHotkeyDisplayName() {
        let shortcut = SiteHotkey(
            keyCode: 8,
            modifiers: SiteHotkey.control | SiteHotkey.option | SiteHotkey.command,
            keyDisplay: "c"
        )
        XCTAssertEqual(shortcut.displayName, "⌃⌥⌘C")
    }

    func testSystemUserAgentContainsParseableSafariVersion() {
        let userAgent = UserAgentStrings.system
        XCTAssertTrue(userAgent.contains("Version/"))
        XCTAssertTrue(userAgent.contains(" Safari/605.1.15"))
        XCTAssertFalse(userAgent.hasSuffix(" TabNest"))
    }

    func testSafariUserAgentNormalizesPatchVersion() {
        XCTAssertEqual(UserAgentStrings.normalizedSafariVersion("27.0.1"), "27.0")
        XCTAssertNil(UserAgentStrings.normalizedSafariVersion("Technology Preview"))
        XCTAssertTrue(UserAgentStrings.desktopSafari(version: "27.0.1").contains("Version/27.0"))
    }

    func testUserAgentResolutionForEveryMode() {
        XCTAssertEqual(
            UserAgentStrings.userAgent(for: Pin(name: "System", urlString: "https://example.com")),
            UserAgentStrings.system
        )
        XCTAssertEqual(
            UserAgentStrings.userAgent(for: Pin(name: "Desktop", urlString: "https://example.com",
                                                userAgentMode: .desktop)),
            UserAgentStrings.desktop
        )
        XCTAssertEqual(
            UserAgentStrings.userAgent(for: Pin(name: "Mobile", urlString: "https://example.com",
                                                userAgentMode: .mobile)),
            UserAgentStrings.mobile
        )
        XCTAssertEqual(
            UserAgentStrings.userAgent(for: Pin(name: "Custom", urlString: "https://example.com",
                                                userAgentMode: .custom,
                                                customUserAgent: "  TabNest-Test-UA/1.0  ")),
            "TabNest-Test-UA/1.0"
        )
        XCTAssertNil(
            UserAgentStrings.userAgent(for: Pin(name: "Empty", urlString: "https://example.com",
                                                userAgentMode: .custom,
                                                customUserAgent: "   "))
        )
    }

    @MainActor
    func testFreshNavigationRequestBypassesCaches() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path"))
        let request = WebTabController.freshRequest(for: url)
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(request.timeoutInterval, 60)
    }

    @MainActor
    func testSingleSiteCacheMatchingIncludesParentAndChildDomainsOnly() {
        XCTAssertTrue(WebTabController.websiteDataRecordMatches("example.com", host: "www.example.com"))
        XCTAssertTrue(WebTabController.websiteDataRecordMatches("cdn.example.com", host: "example.com"))
        XCTAssertTrue(WebTabController.websiteDataRecordMatches("localhost", host: "localhost"))
        XCTAssertFalse(WebTabController.websiteDataRecordMatches("notexample.com", host: "example.com"))
        XCTAssertFalse(WebTabController.websiteDataRecordMatches("example.org", host: "example.com"))
    }

    @MainActor
    func testSingleSiteCacheClearPreservesLoginDataTypes() {
        let types = WebTabController.reloadCacheDataTypes
        XCTAssertTrue(types.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeMemoryCache))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeFetchCache))
        XCTAssertTrue(types.contains(WKWebsiteDataTypeServiceWorkerRegistrations))
        XCTAssertFalse(types.contains(WKWebsiteDataTypeCookies))
        XCTAssertFalse(types.contains(WKWebsiteDataTypeLocalStorage))
        XCTAssertFalse(types.contains(WKWebsiteDataTypeIndexedDBDatabases))
    }

    @MainActor
    func testFaviconDiscoveryResolvesRelativeURL() throws {
        let html = #"""
        <html><head>
          <link href='/assets/pinned-tab.svg' rel='mask-icon' color='#111111'>
          <link href='/assets/touch.png' rel='apple-touch-icon' sizes='180x180'>
          <link href='/assets/tab.svg' rel='icon' type='image/svg+xml' sizes='any'>
        </head></html>
        """#
        let url = FaviconCache.iconURL(
            fromHTML: Data(html.utf8),
            baseURL: try XCTUnwrap(URL(string: "https://example.com/path"))
        )
        XCTAssertEqual(url?.absoluteString, "https://example.com/assets/tab.svg")
    }

    @MainActor
    func testFaviconDiscoveryIgnoresMaskIcon() throws {
        let html = #"""
        <html><head>
          <link href='/assets/pinned-tab.svg' rel='mask-icon'>
          <link href='/assets/touch.png' rel='apple-touch-icon'>
        </head></html>
        """#
        let url = FaviconCache.iconURL(
            fromHTML: Data(html.utf8),
            baseURL: try XCTUnwrap(URL(string: "https://example.com"))
        )
        XCTAssertEqual(url?.absoluteString, "https://example.com/assets/touch.png")
    }

    @MainActor
    func testRasterFaviconIsPreferredOverSVG() throws {
        let html = #"""
        <html><head>
          <link href='/assets/vector.svg' rel='icon' type='image/svg+xml' sizes='any'>
          <link href='/assets/tab.png' rel='icon' type='image/png' sizes='32x32'>
        </head></html>
        """#
        let urls = FaviconCache.iconURLs(
            fromHTML: Data(html.utf8),
            baseURL: try XCTUnwrap(URL(string: "https://example.com"))
        )
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/assets/tab.png",
            "https://example.com/assets/vector.svg",
        ])
    }

    @MainActor
    func testCSSFilledSVGRendersVisibleTemplateIcon() throws {
        let svg = #"""
        <svg xmlns="http://www.w3.org/2000/svg" width="180" height="180"
             viewBox="0 0 180 180" fill="none">
          <style>:root { fill: #000; }</style>
          <circle cx="90" cy="90" r="70"/>
        </svg>
        """#
        let image = try XCTUnwrap(FaviconCache.renderedIcon(
            from: Data(svg.utf8),
            url: try XCTUnwrap(URL(string: "https://example.com/favicon.svg"))
        ))
        XCTAssertTrue(FaviconCache.hasVisiblePixels(image))
        XCTAssertTrue(image.isTemplate)
    }

    @MainActor
    func testRoundedTabIconKeepsTransparentCorners() throws {
        let source = NSImage(size: NSSize(width: 18, height: 18))
        source.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        source.unlockFocus()

        let icon = FaviconCache.roundedTabIcon(from: source, side: 18)
        let data = try XCTUnwrap(icon.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertLessThan(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0.01)
        XCTAssertGreaterThan(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                             y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0, 0.9)
        XCTAssertGreaterThan(bitmap.colorAt(x: 1,
                                             y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0, 0.9)
    }

    @MainActor
    func testRoundedTabIconPreservesTemplateBehavior() {
        let source = NSImage(size: NSSize(width: 18, height: 18))
        source.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()
        source.unlockFocus()
        source.isTemplate = true

        XCTAssertTrue(FaviconCache.roundedTabIcon(from: source, side: 18).isTemplate)
    }

    @MainActor
    func testExternalAppSchemesAreBlocked() throws {
        XCTAssertTrue(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "mailto:test@example.com"))))
        XCTAssertFalse(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "itms-apps://example"))))
        XCTAssertFalse(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "bilibili:/"))))
        XCTAssertFalse(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "bilibili://video/123"))))
        XCTAssertFalse(WebTabController.isAllowedWebURL(try XCTUnwrap(URL(string: "intent://video/123"))))
    }

    @MainActor
    func testMuteToggleKeepsExternalSchemeGuardInstalled() {
        let controller = WebTabController(pin: Pin(name: "Test", urlString: ""))
        defer { controller.stop() }

        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 2)
        controller.setMuted(true)
        let scripts = controller.webView.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.contains { $0.source.contains("__tabNestExternalSchemeGuardInstalled") })
    }

    @MainActor
    func testClosingTabStopsWebViewAndReleasesController() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true",
                      "NSStatusItem 生命周期测试需要登录的 macOS WindowServer 会话")
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        var controller: PinWindowController? = PinWindowController(
            pin: Pin(name: "Media", urlString: ""),
            statusItem: statusItem
        )
        let releasedController = WeakReference(controller)

        controller?.closeForRemoval()
        XCTAssertTrue(controller?.webTab.isStopped == true)
        XCTAssertNil(controller?.panel.contentView)

        controller = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(releasedController.value)
    }
}
