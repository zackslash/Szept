// swift-tools-version:6.0
import PackageDescription

// Unit tests live in Tests/SzeptTests for Xcode builds; the CLT-only
// toolchain has no XCTest, so there is no SPM test target here.
let package = Package(
    name: "Szept",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Szept",
            resources: [.process("Assets.xcassets")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
