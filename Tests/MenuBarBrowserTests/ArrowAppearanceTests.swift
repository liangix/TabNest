import AppKit
import WebKit
import XCTest
@testable import MenuBarBrowser

final class ArrowAppearanceTests: XCTestCase {
    @MainActor
    func testVisiblePanelAutomaticallyUpdatesArrow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a macOS desktop session")
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.button?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let controller = PinWindowController(pin: Pin(name: "Arrow preview", urlString: "about:blank"),
                                             statusItem: item)
        defer {
            controller.closeForRemoval()
            NSStatusBar.system.removeStatusItem(item)
        }
        controller.webTab.webView.loadHTMLString("""
        <style>html{background:rgb(24,44,70);color:white;font:20px system-ui}
        body{padding:32px}h1{font-size:28px}</style><h1>TabNest</h1><p>Adaptive arrow</p>
        """, baseURL: nil)
        controller.show()
        let root = try XCTUnwrap(controller.panel.contentView?.subviews.first as? GlassPanelRootView)
        let arrow = try XCTUnwrap(root.subviews.compactMap { $0 as? AdaptiveArrowBackdropView }.first)
        for _ in 0..<100 {
            if controller.isVisible, arrow.pageColor != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.isVisible)
        assertColor(arrow.pageColor, red: 24, green: 44, blue: 70)
        if ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_PREVIEW"] == "1" {
            try await VisualStyleTests.captureWindow(controller.panel, path: "/tmp/tabnest-adaptive-arrow.png")
        }
        _ = try await controller.webTab.webView.evaluateJavaScript("document.documentElement.style.background = 'rgb(240,245,250)'")
        try await Task.sleep(nanoseconds: 300_000_000)
        assertColor(arrow.pageColor, red: 240, green: 245, blue: 250)
        _ = try await controller.webTab.webView.evaluateJavaScript("document.documentElement.style.background = 'linear-gradient(#182c46, #597fa0)'")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(arrow.pageColor)
        if ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_PREVIEW"] == "1" {
            try await VisualStyleTests.captureWindow(controller.panel, path: "/tmp/tabnest-material-arrow.png")
        }
    }

    @MainActor
    func testAppearanceEventsAreThrottledAndStopWhenHidden() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a macOS desktop session")
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.button?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let controller = PinWindowController(pin: Pin(name: "Events", urlString: "about:blank"), statusItem: item)
        let tab = controller.webTab
        defer { controller.closeForRemoval(); NSStatusBar.system.removeStatusItem(item) }
        var colors: [NSColor?] = []
        tab.onPageBackgroundColor = { colors.append($0) }
        tab.webView.loadHTMLString("""
        <style id="theme">html{background:rgb(20,40,60)}html.dark{background:rgb(30,50,90)}
        body{margin:0;height:3000px}header{height:100px;background:rgb(230,100,40)}</style><header></header>
        """, baseURL: nil)
        controller.show()
        for _ in 0..<100 {
            if controller.isVisible, colors.last.flatMap({ $0 }) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        assertColor(colors.last.flatMap { $0 }, red: 230, green: 100, blue: 40)
        _ = try await tab.webView.evaluateJavaScript("scrollTo(0, 200)")
        try await Task.sleep(nanoseconds: 300_000_000)
        assertColor(colors.last.flatMap { $0 }, red: 20, green: 40, blue: 60)
        _ = try await tab.webView.evaluateJavaScript("document.documentElement.className = 'dark'")
        try await Task.sleep(nanoseconds: 300_000_000)
        assertColor(colors.last.flatMap { $0 }, red: 30, green: 50, blue: 90)

        let beforeBurst = colors.count
        _ = try await tab.webView.evaluateJavaScript("for(let i=0;i<200;i++) window.dispatchEvent(new Event('scroll'))")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(colors.count, beforeBurst)
        XCTAssertLessThanOrEqual(colors.count - beforeBurst, 3, "A burst must not produce one native call per event")

        // CSSOM edits produce no DOM mutation; the low-frequency fallback must still catch them.
        _ = try await tab.webView.evaluateJavaScript("document.styleSheets[0].insertRule('html.dark { background: rgb(80,100,120) }', document.styleSheets[0].cssRules.length)")
        try await Task.sleep(nanoseconds: 3_600_000_000)
        assertColor(colors.last.flatMap { $0 }, red: 80, green: 100, blue: 120)
        controller.hide()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(tab.backgroundTrackingEnabled)
        let active: Any = try await withCheckedThrowingContinuation { continuation in
            tab.webView.evaluateJavaScript("window.__tabNestPageAppearance.active", in: nil, in: .defaultClient) {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(active as? Bool, false)
        let beforeHidden = colors.count
        _ = try await tab.webView.evaluateJavaScript("document.documentElement.style.background = 'rgb(1,2,3)'; window.dispatchEvent(new Event('scroll'))")
        try await Task.sleep(nanoseconds: 3_600_000_000)
        XCTAssertEqual(colors.count, beforeHidden, "Hidden panels must stop both events and the fallback timer")
        controller.show()
        try await Task.sleep(nanoseconds: 300_000_000)
        assertColor(colors.last.flatMap { $0 }, red: 1, green: 2, blue: 3)

        tab.webView.loadHTMLString("<style>html{background:rgb(5,10,15)}</style>", baseURL: nil)
        for _ in 0..<100 {
            if let color = colors.last.flatMap({ $0 })?.usingColorSpace(.sRGB), abs(color.redComponent * 255 - 5) < 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await tab.webView.evaluateJavaScript("document.documentElement.style.background = 'rgb(100,110,120)'")
        try await Task.sleep(nanoseconds: 300_000_000)
        assertColor(colors.last.flatMap { $0 }, red: 100, green: 110, blue: 120)
        controller.closeForRemoval()
        XCTAssertFalse(tab.backgroundTrackingEnabled)
    }

    @MainActor
    func testArrowSamplesPositionThemeScrollAndTranslucentLayers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for WebKit")
        let tab = WebTabController(pin: Pin(name: "Arrow", urlString: "about:blank"))
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 560, height: 400),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = tab.webView
        panel.orderFrontRegardless()
        defer {
            tab.stop()
            panel.contentView = nil
            panel.close()
        }
        tab.webView.loadHTMLString("""
        <style>
        html { background: rgb(20,40,60); }
        body { margin: 0; height: 3000px; }
        header { height: 80px; background: rgb(230,100,40); }
        #overlay { position: fixed; inset: 0 auto auto 0; width: 50%; height: 50px;
                   background: rgba(255,255,255,0.5); }
        </style><header></header><div id="overlay"></div>
        """, baseURL: nil)
        for _ in 0..<100 {
            let ready = try? await tab.webView.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('header')")
            if ready as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        tab.backgroundSampleXFraction = 0.75
        assertColor(try await sample(tab), red: 230, green: 100, blue: 40)
        tab.backgroundSampleXFraction = 0.25
        assertColor(try await sample(tab), red: 243, green: 178, blue: 148)

        _ = try await tab.webView.evaluateJavaScript("document.querySelector('header').style.background = 'rgb(30,50,90)'")
        tab.backgroundSampleXFraction = 0.75
        assertColor(try await sample(tab), red: 30, green: 50, blue: 90)
        _ = try await tab.webView.evaluateJavaScript("window.scrollTo(0, 200)")
        assertColor(try await sample(tab), red: 20, green: 40, blue: 60)

        _ = try await tab.webView.evaluateJavaScript("document.documentElement.style.backgroundImage = 'linear-gradient(red, blue)'")
        let gradient = try await sample(tab)
        XCTAssertNil(gradient, "Image/gradient backgrounds should fall back to material, not guess a flat color")
        _ = try await tab.webView.evaluateJavaScript("document.documentElement.style.background = 'transparent'; document.body.style.background = 'transparent'")
        let transparent = try await sample(tab)
        XCTAssertNil(transparent)
    }

    @MainActor
    func testArrowMaterialFallbackAndColorOverlay() throws {
        let arrow = AdaptiveArrowBackdropView(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        let overlay = try XCTUnwrap(arrow.subviews.first as? SolidBackdropView)
        XCTAssertEqual(arrow.material, .popover)
        XCTAssertEqual(arrow.blendingMode, .behindWindow)
        XCTAssertTrue(overlay.isHidden)
        arrow.pageColor = .red
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.fillColor, .red)
        arrow.pageColor = nil
        XCTAssertTrue(overlay.isHidden)
    }

    @MainActor
    private func sample(_ tab: WebTabController) async throws -> NSColor? {
        var completed = false
        var color: NSColor?
        tab.onPageBackgroundColor = { value in color = value; completed = true }
        tab.samplePageBackgroundColor()
        for _ in 0..<50 {
            if completed { return color }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Background color sampling did not complete")
        return nil
    }

    private func assertColor(_ value: NSColor?, red: Double, green: Double, blue: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let color = value?.usingColorSpace(.sRGB) else {
            XCTFail("Expected a sampled color", file: file, line: line)
            return
        }
        XCTAssertEqual(color.redComponent * 255, red, accuracy: 2, file: file, line: line)
        XCTAssertEqual(color.greenComponent * 255, green, accuracy: 2, file: file, line: line)
        XCTAssertEqual(color.blueComponent * 255, blue, accuracy: 2, file: file, line: line)
    }
}
