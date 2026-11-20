// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchTiles",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TouchTiles", targets: ["TouchTiles"])],
    targets: [
        .target(name: "TouchBridge", publicHeadersPath: "include"),
        .executableTarget(name: "TouchTiles", dependencies: ["TouchBridge"]),
        .testTarget(name: "TouchTilesTests", dependencies: ["TouchTiles"]),
    ]
)
