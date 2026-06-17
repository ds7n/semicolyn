// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(
        name: "GlymrKit",
        dependencies: [
            // Linux uses swift-crypto's `Crypto`; Apple uses system CryptoKit (no dep).
            .product(name: "Crypto", package: "swift-crypto",
                     condition: .when(platforms: [.linux])),
        ]
    ),
    .testTarget(name: "GlymrKitTests", dependencies: ["GlymrKit"]),
]

// The UniFFI XCFramework exists only on Apple platforms; never reference it on Linux.
#if os(macOS)
targets += [
    .target(name: "GlymrSSHCoreFFI", dependencies: ["GlymrSSHCore"]),
    .binaryTarget(name: "GlymrSSHCore", path: "GlymrSSHCore.xcframework"),
    .testTarget(name: "BridgeTests", dependencies: ["GlymrSSHCoreFFI"]),
]
#endif

let package = Package(
    name: "Glymr",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GlymrKit", targets: ["GlymrKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: targets
)
