// swift-tools-version: 6.0
import PackageDescription

// `localis-bridge` — the Mac-side gateway (ADR-0001).
//
// Deliberately **not** under `Packages/`: it is not an SPM package of the iOS
// app, is linked by no iOS target, and takes no part in `xcodegen generate`
// (constitution §VII). The only thing shared with the app is the contract at
// `specs/001-localis-core/contracts/bridge-protocol.md`, which both sides
// implement and neither side imports from the other.
//
// macOS-only by construction: it spawns local CLI processes and advertises over
// Bonjour, neither of which exists in an iOS sandbox — that impossibility is
// the whole reason this process exists.
let package = Package(
    name: "localis-bridge",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "localis-bridge", targets: ["LocalisBridgeCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ],
    targets: [
        // The protocol surface: wire encoding, routing, SSE. Knows nothing
        // about any particular backend — that is what makes constitution IV
        // ("a sixth backend needs no iOS release") true on this side too.
        .target(
            name: "BridgeCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // One adapter per backend. Everything backend-specific lives here and
        // is absorbed before it reaches BridgeCore.
        .target(
            name: "BridgeAdapters",
            dependencies: ["BridgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LocalisBridgeCLI",
            dependencies: ["BridgeCore", "BridgeAdapters"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BridgeAdaptersTests",
            dependencies: ["BridgeAdapters", "BridgeCore"],
            // Captured CLI output, reduced to the frame shapes the decoders
            // read. Real captures rather than invented ones: a dialect change
            // upstream should land as a red test, which only works if the
            // fixture came off the real program.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
