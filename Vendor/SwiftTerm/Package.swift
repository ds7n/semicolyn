// swift-tools-version:6.2
//
// semicolyn's vendored SwiftTerm 1.99.3 (see SEMICOLYN.md). Trimmed from the upstream
// manifest to the library and its build-info plugin: no fuzzer, termcast, tests,
// WASM/Embedded traits, or the swift-png/argument-parser/docc dependencies (swift-png
// is only linked on non-Apple platforms, which this app never builds).

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: [
                "Mac/README.md",
                "Apple/Metal/Shaders.metal",
            ],
            plugins: [
                .plugin(name: "SwiftTermBuildInfoPlugin")
            ]
        ),
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
