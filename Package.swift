// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-mcp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacMCP", targets: ["MacMCP"]),
        .library(name: "MacMCPCore", targets: ["MacMCPCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "MacMCP",
            dependencies: [
                "MacMCPCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/MacMCP",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("OSAKit")
            ]
        ),
        .target(
            name: "MacMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/MacMCPCore"
        ),
        .testTarget(
            name: "MacMCPCoreTests",
            dependencies: ["MacMCPCore"],
            path: "Tests/MacMCPCoreTests"
        )
    ]
)
