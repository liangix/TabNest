import AppKit
import Combine
import Network
import SwiftUI
import WebKit
import XCTest
@testable import MenuBarBrowser

final class WebNotificationTests: XCTestCase {
    @MainActor
    func testPermissionBarPrefersOneLineAndWrapsWhenNeeded() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for native SwiftUI layout")
        for language in [AppLanguage.english, .simplifiedChinese] {
            for (name, origin) in [("normal", "https://example.com"),
                                   ("long", "https://notifications.long-example-domain.com:8443")] {
                for width in [340.0, 560.0] {
                    let request = WebNotificationPermissionRequest(origin: origin)
                    let bar = NotificationPermissionBar(request: request, language: language) { _, _ in }
                    let host = NSHostingView(rootView: bar.frame(width: width).fixedSize(horizontal: false, vertical: true))
                    let size = host.fittingSize
                    XCTAssertEqual(size.width, width, accuracy: 0.5)
                    if width == 560 && name == "normal" {
                        XCTAssertLessThanOrEqual(size.height, 36, "Default-width panels should use one row")
                    } else if width == 340 {
                        XCTAssertGreaterThanOrEqual(size.height, 40, "Narrow panels should wrap to two rows")
                    }
                    XCTAssertGreaterThanOrEqual(size.height, 28)
                    XCTAssertLessThanOrEqual(size.height, 60, "Two compact rows should fit within 60pt")
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    if ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_PREVIEW"] == "1" {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: "/tmp/tabnest-permission-\(language.rawValue)-\(Int(width))-\(name).png"))
                    }
                }
            }
        }
    }

    func testSecureOriginNormalization() {
        XCTAssertEqual(WebNotificationPolicy.origin(for: URL(string: "https://EXAMPLE.com:443/path")), "https://example.com")
        XCTAssertEqual(WebNotificationPolicy.origin(for: URL(string: "https://example.com:8443/path")), "https://example.com:8443")
        XCTAssertEqual(WebNotificationPolicy.origin(for: URL(string: "http://localhost:8123")), "http://localhost:8123")
        for value in ["http://example.com", "file:///tmp/test.html", "about:blank", "bilibili://test"] {
            XCTAssertNil(WebNotificationPolicy.origin(for: URL(string: value)))
        }
    }

    func testPermissionIsPerPinAndExactOriginAndCanBeDisabled() {
        var pin = Pin(name: "A", urlString: "https://example.com")
        XCTAssertEqual(WebNotificationPolicy.permission(for: pin, origin: "https://example.com"), .ask)
        pin.notificationPermissions["https://example.com"] = .granted
        XCTAssertEqual(WebNotificationPolicy.permission(for: pin, origin: "https://example.com"), .granted)
        for origin in ["https://child.example.com", "https://example.com:8443", "https://other.com"] {
            XCTAssertEqual(WebNotificationPolicy.permission(for: pin, origin: origin), .ask)
        }
        XCTAssertEqual(WebNotificationPolicy.permission(for: Pin(name: "B", urlString: pin.urlString),
                                                       origin: "https://example.com"), .ask)
        pin.notificationsEnabled = false
        XCTAssertEqual(WebNotificationPolicy.permission(for: pin, origin: "https://example.com"), .denied)
        XCTAssertEqual(WebNotificationPolicy.permission(for: pin, origin: nil), .denied)
    }

    @MainActor
    func testPermissionsPersistAcrossClosingAndReopeningAndReset() throws {
        let suite = "TabNest.NotificationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinStore(defaults: defaults)
        var pin = Pin(name: "Notifications", urlString: "https://example.com")
        pin.notificationsEnabled = false
        pin.notificationPermissions = ["https://example.com": .granted, "https://other.com": .denied]
        XCTAssertTrue(store.add(pin))
        store.close(pin.id)
        let loaded = PinStore(defaults: defaults)
        XCTAssertTrue(loaded.openPreset(pin.id))
        XCTAssertEqual(loaded.pin(with: pin.id), pin)
        pin.notificationPermissions = [:]
        pin.notificationsEnabled = true
        XCTAssertTrue(loaded.update(pin))
        XCTAssertEqual(PinStore(defaults: defaults).pin(with: pin.id), pin)
    }

    func testInboxReplacesAndDoesNotLetOldCloseEraseNewNotice() throws {
        let pinID = UUID()
        let first = try makeNotice(pinID: pinID, id: "1")
        let second = try makeNotice(pinID: pinID, id: "2")
        var inbox = WebNotificationInbox()
        inbox.receive(first)
        inbox.receive(second)
        XCTAssertEqual(inbox.latest.count, 1)
        inbox.close(pinID: pinID, id: first.id, documentID: first.documentID)
        XCTAssertEqual(inbox.latest[pinID], second)
        inbox.close(pinID: pinID, id: second.id, documentID: "old-document")
        XCTAssertEqual(inbox.unreadPinIDs, [pinID])
        inbox.markRead(pinID)
        XCTAssertTrue(inbox.unreadPinIDs.isEmpty)
        inbox.receive(first)
        inbox.retain([])
        XCTAssertTrue(inbox.latest.isEmpty)
    }

    func testPayloadIsBoundedAndMalformedMessagesAreRejected() throws {
        let pinID = UUID()
        XCTAssertNil(WebNotice(pinID: pinID, origin: "https://example.com", payload: [:]))
        let notice = try XCTUnwrap(WebNotice(pinID: pinID, origin: "https://example.com", payload: [
            "id": "1", "documentID": "doc", "title": String(repeating: "a", count: 200),
            "body": String(repeating: "b", count: 900), "tag": String(repeating: "c", count: 200)
        ]))
        XCTAssertEqual(notice.title.count, 120)
        XCTAssertEqual(notice.body.count, 500)
        XCTAssertEqual(notice.tag.count, 120)
    }

    @MainActor
    func testUnreadDotIsLargerAndAtBottomRightInBothCoordinateSystems() {
        let bounds = NSRect(x: 0, y: 0, width: 24, height: 24)
        for flipped in [true, false] {
            let frame = UnreadDotView.badgeFrame(in: bounds, isFlipped: flipped)
            XCTAssertEqual(frame.size, NSSize(width: 8, height: 8))
            XCTAssertEqual(frame.maxX, bounds.maxX - 1)
            XCTAssertEqual(flipped ? frame.maxY : frame.minY,
                           flipped ? bounds.maxY - 1 : bounds.minY + 1)
            XCTAssertTrue(bounds.contains(frame))
        }
        XCTAssertEqual(NotificationToast.displayDuration, 3)
    }

    @MainActor
    func testToastAnchorsUnderIconAndStaysOnScreen() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: -700, y: 875, width: 24, height: 25)
        let frame = NotificationToast.anchoredFrame(size: NSSize(width: 310, height: 130), anchor: anchor, visibleFrame: screen)
        XCTAssertEqual(frame.midX, anchor.midX)
        XCTAssertEqual(frame.maxY, anchor.minY + PopoverGeometry.visualApexInset + 6, accuracy: 0.001)
        for x in [-1440.0, -24.0] {
            let edge = NotificationToast.anchoredFrame(size: frame.size,
                anchor: NSRect(x: x, y: 875, width: 24, height: 25), visibleFrame: screen)
            XCTAssertGreaterThanOrEqual(edge.minX, screen.minX + 8)
            XCTAssertLessThanOrEqual(edge.maxX, screen.maxX - 8)
            XCTAssertGreaterThanOrEqual(edge.minY, screen.minY)
            XCTAssertLessThanOrEqual(edge.maxY, anchor.maxY)
        }
    }

    private func makeNotice(pinID: UUID, id: String) throws -> WebNotice {
        try XCTUnwrap(WebNotice(pinID: pinID, origin: "https://example.com", payload: [
            "id": id, "documentID": "doc", "title": "Test", "body": "Message"
        ]))
    }

    @MainActor
    func testToastArrowTracksAnchorWhenCardIsClamped() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        for x in [-1400.0, -700.0, -70.0] {
            let anchor = NSRect(x: x, y: 875, width: 24, height: 25)
            let frame = NotificationToast.anchoredFrame(size: NSSize(width: 310, height: 130),
                                                        anchor: anchor, visibleFrame: screen)
            let arrow = PopoverGeometry.arrowPosition(anchorX: anchor.midX, frame: frame)
            XCTAssertEqual(frame.minX + arrow, anchor.midX)
            let path = PopoverOutline(arrowX: arrow).path(in: NSRect(origin: .zero, size: frame.size))
            XCTAssertTrue(path.contains(NSPoint(x: arrow, y: 8)))
            XCTAssertFalse(path.contains(NSPoint(x: arrow > 155 ? 30 : 280, y: 8)))
        }
        let frame = NSRect(x: 0, y: 0, width: 310, height: 130)
        XCTAssertEqual(PopoverGeometry.arrowPosition(anchorX: -50, frame: frame), 24)
        XCTAssertEqual(PopoverGeometry.arrowPosition(anchorX: 400, frame: frame), 286)
    }

    @MainActor
    func testReminderAndBrowserUseIdenticalPopoverOutline() throws {
        func elements(_ path: CGPath) -> [(CGPathElementType, [CGPoint])] {
            var result: [(CGPathElementType, [CGPoint])] = []
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                let count: Int
                switch element.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint: count = 2
                case .addCurveToPoint: count = 3
                case .closeSubpath: count = 0
                @unknown default: count = 0
                }
                result.append((element.type, Array(UnsafeBufferPointer(start: element.points, count: count))))
            }
            return result
        }
        for width in [310.0, 560.0] {
            let frame = NSRect(x: 0, y: 0, width: width, height: 130)
            for arrowX in [24.0, width / 2, width - 24] {
                let root = GlassPanelRootView(frame: frame)
                root.arrowX = arrowX
                let mask = try XCTUnwrap(root.layer?.mask as? CAShapeLayer)
                let maskPath = try XCTUnwrap(mask.path)
                let outline = PopoverOutline(arrowX: arrowX).path(in: frame)
                // Compare actual curve control points, not contains() rounding at curve boundaries.
                var flip = CGAffineTransform(translationX: 0, y: frame.height).scaledBy(x: 1, y: -1)
                let native = elements(try XCTUnwrap(maskPath.copy(using: &flip)))
                let swiftUI = elements(outline.cgPath)
                XCTAssertEqual(native.count, swiftUI.count)
                for (lhs, rhs) in zip(native, swiftUI) {
                    XCTAssertEqual(lhs.0, rhs.0)
                    XCTAssertEqual(lhs.1.count, rhs.1.count)
                    for (a, b) in zip(lhs.1, rhs.1) {
                        XCTAssertEqual(a.x, b.x, accuracy: 0.000001)
                        XCTAssertEqual(a.y, b.y, accuracy: 0.000001)
                    }
                }
            }
        }
    }

    /// Real WebKit + loopback HTTP, opt-in because WebContent needs a non-sandboxed desktop session.
    @MainActor
    func testWebKitNotificationDeliveryClickRevocationAndFrameIsolation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Set TABNEST_NOTIFICATION_INTEGRATION=1 in a macOS desktop session")
        let server = try NotificationTestServer()
        let url = try await server.start()
        defer { server.stop() }
        let suite = "TabNest.NotificationIntegration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinStore(defaults: defaults)
        var pin = Pin(name: "Notification Test", urlString: url.absoluteString)
        let origin = try XCTUnwrap(WebNotificationPolicy.origin(for: url))
        pin.notificationPermissions[origin] = .granted
        XCTAssertTrue(store.add(pin))
        let tab = WebTabController(pin: pin, notificationStore: store)
        defer { tab.stop() }
        let received = expectation(description: "Notification arrived at native bridge")
        var notice: WebNotice?
        tab.notificationBridge.onNotice = { value in notice = value; received.fulfill() }
        try await waitUntilLoaded(tab.webView)
        let value = try await runJS(tab.webView, """
            await new Promise(resolve => setTimeout(resolve, 50));
            window.testNotice = new Notification('Finished', {body: 'Your task is complete', tag: 'job'});
            window.clickCount = 0;
            testNotice.onclick = () => window.clickCount++;
            return Notification.permission;
            """)
        XCTAssertEqual(value as? String, "granted")
        await fulfillment(of: [received], timeout: 5)
        let delivered = try XCTUnwrap(notice)
        XCTAssertEqual(delivered.body, "Your task is complete")
        tab.notificationBridge.dispatch("click", for: delivered)
        let clicks = try await tab.webView.evaluateJavaScript("window.clickCount")
        XCTAssertEqual(clicks as? Int, 1)

        // Closing through the JS Notification object reaches native, with the correct document identity.
        let closed = expectation(description: "JS close")
        tab.notificationBridge.onClose = { id, doc in
            XCTAssertEqual(id, delivered.id); XCTAssertEqual(doc, delivered.documentID); closed.fulfill()
        }
        _ = try await tab.webView.evaluateJavaScript("testNotice.close()")
        await fulfillment(of: [closed], timeout: 5)

        // Iframes cannot bypass the main-frame-only user script by posting native messages themselves.
        let isolated = try await runJS(tab.webView, """
            return await new Promise(resolve => {
              window.addEventListener('message', e => resolve(e.data), {once: true});
              const frame = document.createElement('iframe');
              frame.srcdoc = `<script>window.webkit.messageHandlers.tabNestNotifications.postMessage({
                operation:'show', documentID:'forged', id:'forged', title:'forged'
              }).then(() => parent.postMessage('allowed','*')).catch(() => parent.postMessage('blocked','*'));</script>`;
              document.body.append(frame);
            });
            """)
        XCTAssertEqual(isolated as? String, "blocked")

        pin.notificationsEnabled = false
        XCTAssertTrue(store.update(pin))
        tab.updateNotificationSettings(for: pin)
        let denied = try await runJS(tab.webView, """
            try {
              await window.webkit.messageHandlers.tabNestNotifications.postMessage({operation:'show',
                documentID:'forged', id:'forged', title:'Should not appear'});
              return 'allowed';
            } catch (_) { return Notification.permission; }
            """)
        XCTAssertEqual(denied as? String, "denied")
        tab.stop()
        XCTAssertTrue(tab.isStopped)
        XCTAssertTrue(tab.webView.configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    private func runJS(_ view: WKWebView, _ body: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            var pending: CheckedContinuation<Any, Error>? = continuation
            let finish: (Result<Any, Error>) -> Void = { result in
                guard let current = pending else { return }
                pending = nil
                current.resume(with: result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                finish(.failure(URLError(.timedOut)))
            }
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                finish(result)
            }
        }
    }

    @MainActor
    func testNativePermissionPromptAndMenuBarReminderLifecycle() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires an interactive macOS desktop session")
        let server = try NotificationTestServer()
        let url = try await server.start()
        defer { server.stop() }
        let suite = "TabNest.NotificationUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PinStore(defaults: defaults)
        for old in store.pins { store.close(old.id) }
        var pin = Pin(name: "TabNest Test", urlString: url.absoluteString)
        XCTAssertTrue(store.add(pin))
        var settings = AppSettings(statusIconMode: .expanded)
        let registry = WindowManager(pinStore: store, formWindow: FormWindowController(pinStore: store))
        let status = StatusItemManager(pinStore: store, favicon: .shared, settingsProvider: { settings })
        registry.statusItemManager = status
        status.attach(registry: registry)
        defer {
            store.close(pin.id)
            registry.sync(with: [])
            settings.statusIconMode = .expanded
            status.sync(with: [])
            registry.stopMonitoring()
        }
        let controller = try XCTUnwrap(registry.controller(for: pin.id))
        // A newly created test status item is attached to its screen on the next run-loop turn.
        for _ in 0..<50 {
            if let window = status.statusItem(for: pin.id)?.button?.window,
               window.screen != nil, window.frame.height > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(status.statusItem(for: pin.id)?.button?.window?.screen)
        XCTAssertGreaterThan(try XCTUnwrap(status.statusItem(for: pin.id)?.button?.window).frame.height, 0)
        registry.show(pinID: pin.id)
        try await waitUntilLoaded(controller.webTab.webView)
        let view = controller.webTab.webView
        // No gesture: no prompt and no accidental grant.
        let before = try await runJS(view, "return await window.webkit.messageHandlers.tabNestNotifications.postMessage({operation:'requestPermission', userGesture:false});")
        XCTAssertEqual(before as? String, "default")
        XCTAssertNil(controller.panel.attachedSheet)

        // The native permission bar must not attach a modal sheet or suspend the page.
        let deferred = Task { @MainActor in
            try await self.runJS(view, "return await window.webkit.messageHandlers.tabNestNotifications.postMessage({operation:'requestPermission', userGesture:true});")
        }
        for _ in 0..<50 {
            if controller.panelModel.permissionRequest != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let deferredPrompt = try XCTUnwrap(controller.panelModel.permissionRequest)
        XCTAssertNil(controller.panel.attachedSheet)
        let activePage = try await runJS(view, "document.body.dataset.active = 'yes'; return document.body.dataset.active;")
        XCTAssertEqual(activePage as? String, "yes")
        controller.panelModel.onPermissionDecision?(deferredPrompt.id, .ask)
        let deferredResult = try await deferred.value
        XCTAssertEqual(deferredResult as? String, "default")
        XCTAssertTrue(try XCTUnwrap(store.pin(with: pin.id)).notificationPermissions.isEmpty)

        // A request cancelled by navigation cannot later grant permission.
        let cancelled = Task { @MainActor in
            try await self.runJS(view, "return await window.webkit.messageHandlers.tabNestNotifications.postMessage({operation:'requestPermission', userGesture:true});")
        }
        for _ in 0..<50 {
            if controller.panelModel.permissionRequest != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let stale = try XCTUnwrap(controller.panelModel.permissionRequest)
        controller.webTab.notificationBridge.invalidateDocument()
        controller.panelModel.onPermissionDecision?(stale.id, .granted)
        let cancelledResult = try await cancelled.value
        XCTAssertEqual(cancelledResult as? String, "default")
        XCTAssertTrue(try XCTUnwrap(store.pin(with: pin.id)).notificationPermissions.isEmpty)

        let request = Task { @MainActor in
            try await self.runJS(view, "return await window.webkit.messageHandlers.tabNestNotifications.postMessage({operation:'requestPermission', userGesture:true});")
        }
        for _ in 0..<50 {
            if controller.panelModel.permissionRequest != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let prompt = try XCTUnwrap(controller.panelModel.permissionRequest)
        XCTAssertNil(controller.panel.attachedSheet)
        if ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_PREVIEW"] == "1",
           let content = controller.panel.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/tabnest-permission-preview.png"))
        }
        controller.panelModel.onPermissionDecision?(prompt.id, .granted)
        let permission = try await request.value
        XCTAssertEqual(permission as? String, "granted")
        let origin = try XCTUnwrap(WebNotificationPolicy.origin(for: url))
        pin = try XCTUnwrap(store.pin(with: pin.id))
        XCTAssertEqual(pin.notificationPermissions[origin], .granted)
        registry.sync(with: store.pins)

        // Direct menu decisions update both persistence and the existing page without reloading.
        for (title, expected) in [(L10nKey.notificationDenyOrigin, "denied"), (.notificationAllowOrigin, "granted")] {
            let menu = try XCTUnwrap(status.buildNotificationMenu(for: pin).submenu)
            let item = try XCTUnwrap(menu.items.first { $0.title == L10n.text(title) })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            let value = try await runJS(view, "return Notification.permission;")
            XCTAssertEqual(value as? String, expected)
            pin = try XCTUnwrap(store.pin(with: pin.id))
            XCTAssertEqual(pin.notificationPermissions[origin]?.rawValue, expected)
        }
        controller.hide()

        var uiNotice: WebNotice?
        controller.webTab.notificationBridge.onNotice = { notice in
            uiNotice = notice
            registry.receiveNotification(notice)
        }
        _ = try await runJS(view, """
            window.uiNotice = new Notification('Task completed', {body: 'Your results are ready. Click to open this Tab.'});
            window.uiClicks = 0;
            uiNotice.onclick = () => window.uiClicks++;
            return true;
            """)
        for _ in 0..<50 {
            if NSApp.windows.contains(where: { $0.identifier?.rawValue == "TabNest.notification-\(pin.id)" && $0.isVisible }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let banner = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "TabNest.notification-\(pin.id)" && $0.isVisible })
        XCTAssertFalse(banner.isKeyWindow)
        let button = try XCTUnwrap(status.statusItem(for: pin.id)?.button)
        XCTAssertTrue(button.subviews.contains { $0 is UnreadDotView })
        let dot = try XCTUnwrap(button.subviews.first { $0 is UnreadDotView })
        XCTAssertEqual(dot.frame, UnreadDotView.badgeFrame(in: button.bounds, isFlipped: button.isFlipped))
        XCTAssertTrue(banner.frame.width >= 300 && banner.frame.width < 350)
        XCTAssertTrue(banner.frame.height > 80 && banner.frame.height < 220)
        let anchor = try XCTUnwrap(button.window).frame
        // NSWindow aligns frames to display pixels; allow at most one point of rounding.
        XCTAssertEqual(banner.frame.maxY, anchor.minY + PopoverGeometry.visualApexInset + 6, accuracy: 1)
        XCTAssertEqual(banner.frame.maxY, controller.panel.frame.maxY, accuracy: 1,
                       "Reminder and browser arrows must have the same distance from their icon")

        if ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_PREVIEW"] == "1", let content = banner.contentView {
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/tabnest-notification-preview.png"))
        }
        settings.statusIconMode = .collapsed
        status.sync(with: store.pins)
        let collapsedButton = try XCTUnwrap(status.statusItem(for: pin.id)?.button)
        let collapsedWindow = try XCTUnwrap(collapsedButton.window)
        let collapsedScreen = try XCTUnwrap(collapsedWindow.screen)
        let collapsedFrame = PopoverGeometry.anchoredFrame(size: banner.frame.size, anchor: collapsedWindow.frame,
                                                          visibleFrame: collapsedScreen.visibleFrame)
        XCTAssertEqual(banner.frame, collapsedFrame, "Collapsing must reanchor the same reminder with the shared spacing")
        try await Task.sleep(nanoseconds: 3_400_000_000)
        XCTAssertFalse(banner.isVisible, "The banner must disappear after three seconds")
        XCTAssertTrue(collapsedButton.subviews.contains { $0 is UnreadDotView }, "Auto-dismiss must not mark the Tab read")
        settings.statusIconMode = .collapsed
        status.sync(with: store.pins)
        XCTAssertTrue(status.statusItem(for: pin.id)?.button?.subviews.contains { $0 is UnreadDotView } == true)
        registry.openNotification(try XCTUnwrap(uiNotice))
        XCTAssertTrue(controller.isVisible)
        let clicked = try await view.evaluateJavaScript("window.uiClicks")
        XCTAssertEqual(clicked as? Int, 1)
        XCTAssertFalse(status.statusItem(for: pin.id)?.button?.subviews.contains { $0 is UnreadDotView } == true)

        // Revoking from settings cancels the visible reminder and removes the badge immediately.
        controller.hide()
        settings.statusIconMode = .expanded
        status.sync(with: store.pins)
        let sent = expectation(description: "Second UI notification")
        controller.webTab.notificationBridge.onNotice = { notice in registry.receiveNotification(notice); sent.fulfill() }
        _ = try await runJS(view, "new Notification('Another update'); return true;")
        await fulfillment(of: [sent], timeout: 5)
        pin.notificationsEnabled = false
        XCTAssertTrue(store.update(pin))
        registry.sync(with: store.pins)
        XCTAssertFalse(status.statusItem(for: pin.id)?.button?.subviews.contains { $0 is UnreadDotView } == true)

        pin.notificationsEnabled = true
        XCTAssertTrue(store.update(pin))
        settings.statusIconMode = .collapsed
        let subscription = store.$pins.sink { pins in
            registry.sync(with: pins)
            status.sync(with: pins)
        }
        store.close(pin.id)
        XCTAssertNil(registry.controller(for: pin.id), "Closing in collapsed mode must not recreate an authorized Tab from a stale publisher value")
        subscription.cancel()
    }

    @MainActor
    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func waitUntilLoaded(_ view: WKWebView) async throws {
        for _ in 0..<100 {
            if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("WebKit test page did not finish loading")
        throw URLError(.timedOut)
    }
}

private final class NotificationTestServer {
    private let listener: NWListener
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let html = "<!doctype html><html><head><title>Notification Test</title></head><body>Local notification test</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel() }
}
