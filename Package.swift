// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatArchive",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WeChatArchiveCore", targets: ["WeChatArchiveCore"]),
        .executable(name: "WeChatArchive", targets: ["WeChatArchiveApp"])
    ],
    targets: [
        .target(name: "WeChatArchiveCore", path: "Sources/Core"),
        .executableTarget(
            name: "WeChatArchiveApp",
            dependencies: ["WeChatArchiveCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "WeChatArchiveCoreTests",
            dependencies: ["WeChatArchiveCore"],
            path: "Tests/WeChatArchiveCoreTests"
        )
    ]
)
