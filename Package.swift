// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoWindow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoWindow", targets: ["AutoWindow"]),
    ],
    targets: [
        .target(name: "AutoWindowCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "AutoWindow",
            dependencies: ["AutoWindowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "AutoWindowCoreTests", dependencies: ["AutoWindowCore"]),
    ]
)
