import AppKit
import WebKit
import XCTest
@testable import MenuBarBrowser

final class ArrowAppearanceTests: XCTestCase {
    @MainActor
    func testMediaMutationsDoNotRescanDocument() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a macOS desktop session")
        let tab = WebTabController(pin: Pin(name: "Media", urlString: "about:blank"))
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 560, height: 400),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = tab.webView
        panel.orderFrontRegardless()
        defer { tab.stop(); panel.contentView = nil; panel.close() }
        tab.webView.loadHTMLString("<div id='editor' contenteditable>hello</div><video id='existing'></video>", baseURL: nil)
        for _ in 0..<100 {
            let ready = try? await tab.webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('editor')")
            if ready as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        tab.setMuted(true)
        _ = try await tab.webView.evaluateJavaScript("""
        window.fullScans = 0;
        const originalDocumentQuery = document.querySelectorAll.bind(document);
        document.querySelectorAll = function(selector) { fullScans++; return originalDocumentQuery(selector); };
        const originalRootQuery = document.documentElement.querySelectorAll.bind(document.documentElement);
        document.documentElement.querySelectorAll = function(selector) { fullScans++; return originalRootQuery(selector); };
        for (let i = 0; i < 200; i++) document.getElementById('editor').appendChild(document.createTextNode('字'));
        const wrapper = document.createElement('div');
        wrapper.innerHTML = '<video id="added"></video><audio id="audio"></audio>';
        document.body.appendChild(wrapper);
        true;
        """)
        try await Task.sleep(nanoseconds: 100_000_000)
        let scans = try await tab.webView.evaluateJavaScript("fullScans")
        XCTAssertEqual(scans as? Int, 0, "Typing and new media must not scan the whole page")
        let muted = try await tab.webView.evaluateJavaScript("['existing','added','audio'].every(id => document.getElementById(id).muted)")
        XCTAssertEqual(muted as? Bool, true)
        tab.setMuted(false)
        let unmuted = try await tab.webView.evaluateJavaScript("['existing','added','audio'].every(id => !document.getElementById(id).muted)")
        XCTAssertEqual(unmuted as? Bool, true)
    }

    @MainActor
    func testArrowUsesSystemMaterial() {
        let arrow = ArrowBackdropView(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        XCTAssertEqual(arrow.material, .popover)
        XCTAssertEqual(arrow.blendingMode, .behindWindow)
        XCTAssertEqual(arrow.state, .active)
    }
}
