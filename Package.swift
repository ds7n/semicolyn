// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(
        name: "SemicolynKit",
        dependencies: [
            // Linux uses swift-crypto's `Crypto`; Apple uses system CryptoKit (no dep).
            .product(name: "Crypto", package: "swift-crypto",
                     condition: .when(platforms: [.linux])),
        ]
    ),
    .testTarget(name: "SemicolynKitTests", dependencies: ["SemicolynKit"]),
    // Build-time seed-ingestion tooling — never part of the shipped app product.
    .target(name: "SeedKit", dependencies: ["SemicolynKit"]),
    .executableTarget(name: "semicolyn-seedbuild", dependencies: ["SeedKit"]),
    .testTarget(name: "SeedKitTests", dependencies: ["SeedKit"]),
]

var products: [Product] = [.library(name: "SemicolynKit", targets: ["SemicolynKit"])]

// The UniFFI XCFramework exists only on Apple platforms; never reference it on Linux.
#if os(macOS)
targets += [
    .target(name: "SemicolynSSHCoreFFI", dependencies: ["SemicolynSSHCore"],
            // The UniFFI-generated bindings aren't Swift 6 strict-concurrency
            // clean (sending-closure diagnostics on the foreign-trait callbacks).
            // It's vendored generated code we don't edit, so compile it in Swift 5
            // language mode; SemicolynKit and the app stay on Swift 6.
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .binaryTarget(name: "SemicolynSSHCore", path: "SemicolynSSHCore.xcframework"),
    .testTarget(name: "BridgeTests", dependencies: ["SemicolynSSHCoreFFI"]),
]
// Expose the UniFFI bridge module as a product so the iOS app target can link it.
products += [.library(name: "SemicolynSSHCoreFFI", targets: ["SemicolynSSHCoreFFI"])]
#endif

let package = Package(
    name: "Semicolyn",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: targets
)
