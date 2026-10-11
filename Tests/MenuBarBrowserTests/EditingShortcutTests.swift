import AppKit
import WebKit
import XCTest
@testable import MenuBarBrowser

final class EditingShortcutTests: XCTestCase {
    @MainActor
    func testNativeEditingShortcutsInBrowserPanel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_LINK_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for native editing commands")
        _ = NSApplication.shared
        let originalMenu = NSApp.mainMenu
        let pasteboard = NSPasteboard.general
        let originalClipboard = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []
        let tab = WebTabController(pin: Pin(name: "Editing test", urlString: ""))
        let view = try XCTUnwrap(tab.webView as? BrowserWebView)
        let panel = BrowserPanel(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        defer {
            tab.stop()
            panel.close()
            NSApp.mainMenu = originalMenu
            pasteboard.clearContents()
            let restored = originalClipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        pasteboard.clearContents()
        pasteboard.setString("TabNest clipboard sentinel", forType: .string)
        let mainMenu = NSMenu()
        let root = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        root.submenu = editMenu
        mainMenu.addItem(root)
        for (title, action, key) in [("Copy", "copy:", "c"), ("Cut", "cut:", "x"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
                                     ("Undo", "undo:", "z"), ("Redo", "redo:", "Z")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        NSApp.mainMenu = mainMenu
        view.loadHTMLString("<textarea id='editor' style='width:400px;height:200px'>TabNest shortcut test</textarea>",
                            baseURL: URL(string: "https://example.com/editing-test"))
        for _ in 0..<100 {
            if !view.isLoading, (try? await view.evaluateJavaScript("!!document.getElementById('editor')")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        panel.makeFirstResponder(view)
        _ = try await view.evaluateJavaScript("editor.focus(); editor.setSelectionRange(0, 0)")
        try await Task.sleep(nanoseconds: 100_000_000)

        func shortcut(_ key: String, code: UInt16, shift: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            editMenu.update()
            XCTAssertTrue(mainMenu.performKeyEquivalent(with: event), "Editing shortcut Command+\(key) must be enabled and handled")
        }
        func waitForValue(_ expected: String) async throws {
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript("editor.value")) as? String == expected { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let value = try await view.evaluateJavaScript("editor.value") as? String
            XCTAssertEqual(value, expected)
        }
        try shortcut("a", code: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        let selectionLength = try await view.evaluateJavaScript("editor.selectionEnd - editor.selectionStart") as? Int
        XCTAssertEqual(selectionLength, 21)
        try shortcut("c", code: 8)
        for _ in 0..<100 {
            if pasteboard.string(forType: .string) == "TabNest shortcut test" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "TabNest shortcut test")
        try shortcut("x", code: 7)
        try await waitForValue("")
        try shortcut("v", code: 9)
        try await waitForValue("TabNest shortcut test")
        try shortcut("z", code: 6)
        try await waitForValue("")
        try shortcut("Z", code: 6, shift: true)
        try await waitForValue("TabNest shortcut test")
    }
}
