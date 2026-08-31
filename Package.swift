// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuBarBrowser",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MenuBarBrowser",
            path: "Sources/MenuBarBrowser",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MenuBarBrowserTests",
            dependencies: ["MenuBarBrowser"]
        ),
    ]
)
