// swift-tools-version:5.9
// UNVERIFIED — written and reviewed with no Swift toolchain available
// (no macOS host in this session). See README.md before trusting anything
// here compiles. Run `swift build` and `swift test` on a real Mac first.
import PackageDescription

let package = Package(
    name: "Bootsahi",
    platforms: [
        .macOS(.v13) // matches asahi-installer's own MIN_MACOS_VERSION
    ],
    targets: [
        .executableTarget(
            name: "Bootsahi",
            path: "Sources/Bootsahi",
            resources: [
                .copy("Resources/catalog.json"),
                .copy("Resources/supported-models.json"),
            ]
        ),
        .testTarget(
            name: "BootsahiTests",
            dependencies: ["Bootsahi"],
            path: "Tests/BootsahiTests"
        ),
    ]
)
