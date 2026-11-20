// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TouchTiles",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TouchTiles", targets: ["TouchTiles"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "TouchBridge", publicHeadersPath: "include"),
        .executableTarget(name: "TouchTiles", dependencies: ["TouchBridge", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(
            name: "TouchTilesTests",
            dependencies: ["TouchTiles"],
            // SwiftPM places Sparkle.framework beside the XCTest bundle.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
    ]
)
