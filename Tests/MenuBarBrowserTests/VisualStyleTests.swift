import AppKit
import SwiftUI
import ScreenCaptureKit
import XCTest
@testable import MenuBarBrowser

final class VisualStyleTests: XCTestCase {
    func testMaterialPolicyPreservesLegacyAndAccessibilityFallbacks() {
        for modern in [false, true] {
            for legacy in [false, true] {
                XCTAssertEqual(TabNestVisualPolicy.surface(modernSystem: modern, reduceTransparency: true,
                                                          increasedContrast: false, forceLegacy: legacy), .opaque)
                XCTAssertEqual(TabNestVisualPolicy.surface(modernSystem: modern, reduceTransparency: false,
                                                          increasedContrast: true, forceLegacy: legacy), .opaque)
                XCTAssertEqual(TabNestVisualPolicy.surface(modernSystem: modern, reduceTransparency: false,
                                                          increasedContrast: false, forceLegacy: legacy),
                               modern && !legacy ? .glass : .material)
            }
        }
    }

    @MainActor
    func testVisualSurfacesInLightDarkLegacyAndAccessibilityModes() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_INTEGRATION"] == "1",
                          "Requires a native macOS desktop session")
        let modes: [(String, ColorScheme, Bool, Bool, ColorSchemeContrast)] = [
            ("light", .light, false, false, .standard),
            ("dark", .dark, false, false, .standard),
            ("legacy-light", .light, true, false, .standard),
            ("legacy-dark", .dark, true, false, .standard),
            ("opaque", .light, false, true, .standard),
            ("contrast", .dark, false, false, .increased),
        ]
        for (name, scheme, legacy, reduceTransparency, contrast) in modes {
            let request = WebNotificationPermissionRequest(origin: "https://example.com")
            let view = VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("TabNest", systemImage: "bell.fill").font(.caption.weight(.semibold))
                    Text("Task completed").font(.headline)
                    Text("Click to open this Tab.").font(.subheadline)
                }
                .padding(12).padding(.top, PopoverGeometry.topInset)
                .frame(width: 310, alignment: .leading)
                .tabNestFloatingSurface(in: PopoverOutline(arrowX: 155))
                NotificationPermissionBar(request: request) { _, _ in }
                    .frame(width: 560)
                PinFormView(mode: .edit(Pin(name: "Example", urlString: "https://example.com")),
                            onSave: { _ in true }, onCancel: {})
                    .frame(width: 440)
            }
            .padding(16)
            .environment(\.colorScheme, scheme)
            .environment(\.tabNestLegacyAppearance, legacy)
            .environment(\.tabNestAccessibilityPreview,
                         TabNestAccessibilityPreview(reduceTransparency: reduceTransparency,
                                                     increasedContrast: contrast == .increased))
            let host = NSHostingView(rootView: view)
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            panel.backgroundColor = scheme == .dark ? .darkGray : .lightGray
            panel.center()
            panel.orderFrontRegardless()
            defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.width, 592, accuracy: 1)
            XCTAssertLessThan(host.frame.height, 650)
            if ProcessInfo.processInfo.environment["TABNEST_NOTIFICATION_PREVIEW"] == "1" {
                // Glass is composited by WindowServer. cacheDisplay captures its intermediate
                // refraction texture rather than the final material or foreground text.
                try await Self.captureWindow(panel, path: "/tmp/tabnest-style-\(name).png")
            }
        }
    }

    @MainActor
    static func captureWindow(_ panel: NSWindow, path: String) async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("Composited window previews require macOS 14+") }
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "Window previews require existing screen capture permission")
        let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let window = try XCTUnwrap(shareable.windows.first { $0.windowID == CGWindowID(panel.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(panel.frame.width * 2)
        config.height = Int(panel.frame.height * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bitmap = NSBitmapImageRep(cgImage: captured)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
