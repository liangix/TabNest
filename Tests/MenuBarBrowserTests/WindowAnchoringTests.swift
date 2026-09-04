import AppKit
import XCTest
@testable import MenuBarBrowser

final class WindowAnchoringTests: XCTestCase {
    @MainActor
    func testFirstShowWaitsForAnchorThenTracksRebindingAndResize() async throws {
        try requireDesktop()
        let item = NSStatusBar.system.statusItem(withLength: 28)
        let collapsed = NSStatusBar.system.statusItem(withLength: 28)
        var anchor: StatusItemAnchor?
        var currentItem: NSStatusItem?
        let controller = PinWindowController(pin: Pin(name: "Anchor", urlString: "about:blank"),
                                             statusItem: item) { receivedItem in
            currentItem = receivedItem
            return anchor
        }
        defer {
            controller.closeForRemoval()
            NSStatusBar.system.removeStatusItem(item)
            NSStatusBar.system.removeStatusItem(collapsed)
        }
        controller.show()
        XCTAssertTrue(controller.wantsVisible)
        XCTAssertFalse(controller.isVisible, "Never show at the initial bottom-left frame")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(controller.isVisible)

        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        anchor = StatusItemAnchor(frame: NSRect(x: screen.midX, y: screen.maxY, width: 28, height: 24),
                                  visibleFrame: screen)
        for _ in 0..<40 {
            if controller.isVisible { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(controller.isVisible)
        assertAnchored(controller, to: try XCTUnwrap(anchor))
        controller.panel.setContentSize(NSSize(width: 640, height: 500))
        assertAnchored(controller, to: try XCTUnwrap(anchor))

        // Switching expanded/collapsed icons can also create an unlaid-out status item.
        anchor = nil
        controller.updateStatusItem(collapsed)
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(controller.wantsVisible)
        anchor = StatusItemAnchor(frame: NSRect(x: screen.minX + 30, y: screen.maxY, width: 28, height: 24),
                                  visibleFrame: screen)
        for _ in 0..<40 {
            if controller.isVisible { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(currentItem === collapsed)
        XCTAssertTrue(controller.isVisible)
        assertAnchored(controller, to: try XCTUnwrap(anchor))
    }

    @MainActor
    func testPendingShowIsCancelledByToggleHideAndRemoval() async throws {
        try requireDesktop()
        let item = NSStatusBar.system.statusItem(withLength: 28)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let ready = StatusItemAnchor(frame: NSRect(x: screen.midX, y: screen.maxY, width: 28, height: 24),
                                     visibleFrame: screen)
        for action in ["toggle", "hide", "close"] {
            var anchor: StatusItemAnchor?
            let controller = PinWindowController(pin: Pin(name: "Cancel", urlString: "about:blank"),
                                                 statusItem: item) { _ in anchor }
            controller.show()
            switch action {
            case "toggle": controller.toggle()
            case "hide": controller.hide()
            default: controller.closeForRemoval()
            }
            anchor = ready
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(controller.wantsVisible, action)
            XCTAssertFalse(controller.isVisible, action)
            if action != "close" {
                controller.show()
                XCTAssertTrue(controller.isVisible)
                assertAnchored(controller, to: ready)
                // An old hide-animation completion must not hide a newly reopened panel.
                controller.hide()
                controller.show()
                try await Task.sleep(nanoseconds: 200_000_000)
                XCTAssertTrue(controller.isVisible)
            } else {
                controller.show()
                XCTAssertFalse(controller.isVisible)
            }
            controller.closeForRemoval()
        }
    }

    @MainActor
    private func assertAnchored(_ controller: PinWindowController, to anchor: StatusItemAnchor,
                                file: StaticString = #filePath, line: UInt = #line) {
        let expected = PopoverGeometry.anchoredFrame(size: controller.panel.frame.size,
                                                    anchor: anchor.frame, visibleFrame: anchor.visibleFrame)
        XCTAssertEqual(controller.panel.frame.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(controller.panel.frame.maxY, expected.maxY, accuracy: 1, file: file, line: line)
    }

    private func requireDesktop() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a macOS desktop session for native windows")
    }
}
