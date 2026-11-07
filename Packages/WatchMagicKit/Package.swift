// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WatchMagicKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14), // macOS only so `swift test` runs on the Mac
    ],
    products: [
        .library(name: "WatchMagicKit", targets: ["WatchMagicKit"]),
    ],
    targets: [
        .target(
            name: "WatchMagicKit",
            path: "Sources/WatchMagicKit"
        ),
        .testTarget(
            name: "WatchMagicKitTests",
            dependencies: ["WatchMagicKit"],
            path: "Tests/WatchMagicKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
