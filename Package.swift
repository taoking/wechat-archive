// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatArchive",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WeChatArchiveCore", targets: ["WeChatArchiveCore"]),
        .executable(name: "WeChatArchive", targets: ["WeChatArchiveApp"]),
        .executable(name: "WeChatArchiveCLI", targets: ["WeChatArchiveCLI"])
    ],
    targets: [
        .target(name: "WeChatArchiveCore", path: "Sources/Core"),
        .executableTarget(
            name: "WeChatArchiveApp",
            dependencies: ["WeChatArchiveCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "WeChatArchiveCLI",
            dependencies: ["WeChatArchiveCore"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "WeChatArchiveCoreTests",
            dependencies: ["WeChatArchiveCore"],
            path: "Tests/WeChatArchiveCoreTests"
        )
    ]
)
