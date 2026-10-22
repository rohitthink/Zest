// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zest",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZestKit", targets: ["ZestKit"]),
        .executable(name: "zest", targets: ["zest"]),
        .executable(name: "ZestApp", targets: ["ZestApp"]),
    ],
    targets: [
        .target(name: "ZestKit"),
        .executableTarget(name: "zest", dependencies: ["ZestKit"]),
        .executableTarget(name: "ZestApp", dependencies: ["ZestKit"]),
        .testTarget(name: "ZestKitTests", dependencies: ["ZestKit"]),
    ]
)
