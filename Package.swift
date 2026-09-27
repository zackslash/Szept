// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Szept",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Szept",
            resources: [.process("Assets.xcassets")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SzeptTests",
            dependencies: ["Szept"],
            path: "Tests/SzeptTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
