import AppKit
import Combine
import WebKit
import XCTest
@testable import MenuBarBrowser

final class BrowserLinkTests: XCTestCase {
    @MainActor
    func testNewTabMenuReplacesOnlyNewWindowActionAndUsesSelectedLink() throws {
        let view = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var opened: [URL] = []
        view.openNewTab = { opened.append($0) }
        let menu = NSMenu()
        let native = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
        native.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        menu.addItem(native)
        let ordinary = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        menu.addItem(ordinary)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        view.willOpenMenu(menu, with: event)
        XCTAssertEqual(native.title, L10n.text(.menuOpenLinkInNewTab))
        XCTAssertEqual(ordinary.title, "Open Link")
        XCTAssertNil(ordinary.action)
        XCTAssertFalse(view.validateUserInterfaceItem(native))
        let url = try XCTUnwrap(URL(string: "https://example.com/path?q=1#fragment"))
        view.setContextLink(url)
        XCTAssertTrue(view.validateUserInterfaceItem(native))
        XCTAssertEqual(native.action, #selector(BrowserWebView.openInNewTab(_:)))
        view.openInNewTab(native)
        XCTAssertEqual(opened, [url])
        view.setContextLink(nil)
        XCTAssertFalse(view.validateUserInterfaceItem(native))
        view.openInNewTab(native)
        XCTAssertEqual(opened, [url])
        view.didCloseMenu(menu, with: nil)
    }

    @MainActor
    func testLinkTabsAllowDuplicatesPersistAndCloseWithoutChangingPresets() throws {
        let suite = "TabNest.LinkTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinStore(defaults: defaults)
        var source = try XCTUnwrap(store.pins.first)
        source.userAgentMode = .custom
        source.customUserAgent = "Test Agent"
        source.pageZoom = PageZoom.normalized(1.2)
        source.isMuted = true
        source.notificationPermissions = ["https://example.com": .granted]
        XCTAssertTrue(store.update(source))
        let originalPresets = store.presets
        let url = try XCTUnwrap(source.url)
        let first = try XCTUnwrap(store.openLink(url, from: source))
        let second = try XCTUnwrap(store.openLink(url, from: source))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.url, url)
        XCTAssertEqual(first.userAgentMode, source.userAgentMode)
        XCTAssertEqual(first.customUserAgent, source.customUserAgent)
        XCTAssertEqual(first.pageZoom, source.pageZoom)
        XCTAssertEqual(first.isMuted, source.isMuted)
        XCTAssertEqual(first.hotkeyMode, .disabled)
        XCTAssertTrue(first.notificationPermissions.isEmpty)
        XCTAssertEqual(store.selectedPinID, second.id)
        XCTAssertEqual(store.pin(with: source.id), source)
        XCTAssertEqual(store.presets, originalPresets)
        var updated = first
        updated.isMuted = false
        XCTAssertTrue(store.update(updated))
        let reopened = PinStore(defaults: defaults)
        XCTAssertEqual(reopened.presets, originalPresets)
        XCTAssertEqual(reopened.pin(with: first.id), updated)
        XCTAssertEqual(reopened.pin(with: second.id), second)
        reopened.close(first.id)
        XCTAssertNil(reopened.pin(with: first.id))
        XCTAssertNil(reopened.preset(with: first.id))
        XCTAssertEqual(reopened.pin(with: second.id), second)
        XCTAssertNil(store.openLink(try XCTUnwrap(URL(string: "file:///tmp/test")), from: source))
    }

    @MainActor
    func testNewTabActionCreatesAndShowsIndependentController() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_LINK_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for menu bar windows")
        _ = NSApplication.shared
        let suite = "TabNest.LinkWindowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinStore(defaults: defaults)
        let registry = WindowManager(pinStore: store, formWindow: FormWindowController(pinStore: store))
        let status = StatusItemManager(pinStore: store, favicon: .shared)
        status.attach(registry: registry)
        registry.statusItemManager = status
        let subscription = store.$pins.sink { pins in registry.sync(with: pins); status.sync(with: pins) }
        defer {
            subscription.cancel()
            registry.sync(with: [])
            registry.stopMonitoring()
            var removed = Set<ObjectIdentifier>()
            for pin in store.pins {
                if let item = status.statusItem(for: pin.id), removed.insert(ObjectIdentifier(item)).inserted {
                    NSStatusBar.system.removeStatusItem(item)
                }
            }
        }
        let source = try XCTUnwrap(store.pins.first)
        let original = try XCTUnwrap(registry.controller(for: source.id))
        let view = try XCTUnwrap(original.webTab.webView as? BrowserWebView)
        let sourceURL = view.url
        let url = try XCTUnwrap(URL(string: "https://example.com/new-tab"))
        let menuItem = NSMenuItem()
        menuItem.representedObject = url
        view.openInNewTab(menuItem)
        let tab = try XCTUnwrap(store.pins.last)
        XCTAssertEqual(tab.url, url)
        XCTAssertTrue(tab.isTemporary)
        XCTAssertEqual(registry.selectedPinID, tab.id)
        let created = try XCTUnwrap(registry.controller(for: tab.id))
        XCTAssertTrue(created.wantsVisible)
        XCTAssertFalse(original.webTab.webView === created.webTab.webView)
        XCTAssertEqual(view.url, sourceURL)
        XCTAssertEqual(store.pin(with: source.id), source)
        store.close(tab.id)
        XCTAssertTrue(created.webTab.isStopped)
        XCTAssertNil((created.webTab.webView as? BrowserWebView)?.openNewTab)
    }

    @MainActor
    func testNativeRightClickMenuOpensSelectedLinkInNewTab() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_LINK_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for native context menus")
        _ = NSApplication.shared
        let tab = WebTabController(pin: Pin(name: "Test", urlString: ""))
        let view = try XCTUnwrap(tab.webView as? BrowserWebView)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { tab.stop(); window.close() }
        let url = try XCTUnwrap(URL(string: "https://example.com/context?q=1#fragment"))
        var opened: [URL] = []
        view.openNewTab = { opened.append($0) }
        view.loadHTMLString("<a id='link' style='display:block;padding:30px' href='\(url.absoluteString)'>Link</a>",
                            baseURL: URL(string: "https://example.com/fixture"))
        for _ in 0..<100 {
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('link')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let original = view.url
        let checked = expectation(description: "Native context menu opened")
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                               object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    defer { menu.cancelTracking(); checked.fulfill() }
                    guard let item = menu.items.first(where: {
                        $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                    }) else {
                        XCTFail("Native link menu must contain the new Tab action")
                        return
                    }
                    XCTAssertEqual(item.title, L10n.text(.menuOpenLinkInNewTab))
                    XCTAssertEqual(item.representedObject as? URL, url)
                    XCTAssertTrue(item.isEnabled)
                    if let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let point = NSPoint(x: 50, y: view.isFlipped ? 40 : view.bounds.height - 40)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        try XCTUnwrap(view.hitTest(point)).rightMouseDown(with: event)
        await fulfillment(of: [checked], timeout: 5)
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(view.url, original)
    }

    @MainActor
    func testContextMenuKeepsNativeItemsAndOpensClickedLink() throws {
        let view = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        var opened: [URL] = []
        view.openExternalURL = { opened.append($0) }
        let url = try XCTUnwrap(URL(string: "https://example.com/path?q=1#anchor"))
        view.setContextLink(url)
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
                                                   modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        view.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.first?.title, "Copy")
        let item = try XCTUnwrap(menu.items.first { ($0.representedObject as? URL) == url })
        XCTAssertEqual(item.title, L10n.text(.menuOpenLinkInDefaultBrowser))
        view.openInBrowser(item)
        XCTAssertEqual(opened, [url])
        // Late context messages update the displayed item instead of using an old link.
        view.setContextLink(nil)
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(view.validateUserInterfaceItem(item))
        view.didCloseMenu(menu, with: nil)
        let nextMenu = NSMenu()
        view.willOpenMenu(nextMenu, with: event)
        XCTAssertTrue(nextMenu.items.first { $0.title == L10n.text(.menuOpenLinkInDefaultBrowser) }?.isHidden == true)
    }

    @MainActor
    func testOnlyWebPagesAreOpenedExternallyAndHandlerIsRemovedOnStop() throws {
        let tab = WebTabController(pin: Pin(name: "Test", urlString: ""))
        defer { tab.stop() }
        let view = try XCTUnwrap(tab.webView as? BrowserWebView)
        var opened = false
        view.openExternalURL = { _ in opened = true }
        for raw in ["javascript:alert(1)", "file:///tmp/test", "about:blank", "bilibili://test", "data:text/html,test"] {
            let item = NSMenuItem()
            item.action = #selector(BrowserWebView.openInBrowser(_:))
            item.representedObject = URL(string: raw)
            view.openInBrowser(item)
            XCTAssertFalse(opened)
            XCTAssertFalse(view.validateUserInterfaceItem(item))
        }
        XCTAssertTrue(view.configuration.userContentController.userScripts.contains {
            $0.source.contains("event.metaKey") && !$0.isForMainFrameOnly
        })
        tab.stop()
        XCTAssertTrue(view.configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    func testNativeCommandClickKeepsPageAndOpensDefaultBrowserURL() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_LINK_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for native WebKit mouse events")
        _ = NSApplication.shared
        let tab = WebTabController(pin: Pin(name: "Test", urlString: ""))
        let view = try XCTUnwrap(tab.webView as? BrowserWebView)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { tab.stop(); window.close() }
        let external = try XCTUnwrap(URL(string: "https://example.com/command?q=1#section"))
        var opened: [URL] = []
        view.openExternalURL = { opened.append($0) }
        view.loadHTMLString("""
            <a id="link" style="display:block;padding:30px" href="\(external.absoluteString)" target="_blank">Link</a>
            """, baseURL: URL(string: "https://example.com/fixture"))
        for _ in 0..<100 {
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('link')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let original = view.url
        let point = NSPoint(x: 50, y: view.isFlipped ? 40 : view.bounds.height - 40)
        let location = view.convert(point, to: nil)
        let receiver = try XCTUnwrap(view.hitTest(point))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { receiver.mouseDown(with: event) }
            else { receiver.mouseUp(with: event) }
        }
        for _ in 0..<100 {
            if !opened.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(opened, [external], "Command click must open once, including target=_blank")
        XCTAssertEqual(view.url, original)

        _ = try await view.evaluateJavaScript("link.target = '_self'; link.href = '#inside'")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { receiver.mouseDown(with: event) }
            else { receiver.mouseUp(with: event) }
        }
        for _ in 0..<100 {
            if view.url?.fragment == "inside" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(view.url?.fragment, "inside", "Ordinary clicks must navigate within the floating page")
        XCTAssertEqual(opened, [external])
    }
}
