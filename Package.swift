// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuBarBrowser",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MenuBarBrowser",
            path: "Sources/MenuBarBrowser"
        ),
        .testTarget(
            name: "MenuBarBrowserTests",
            dependencies: ["MenuBarBrowser"]
        ),
    ]
)
