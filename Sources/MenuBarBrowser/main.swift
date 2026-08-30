import AppKit
import OSLog

private let mbbLogger = Logger(subsystem: "com.menubar.browser", category: "application")

func mbbTrace(_ msg: String) {
    mbbLogger.debug("\(msg, privacy: .public)")
}

let app = NSApplication.shared

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
    app.run()
}
