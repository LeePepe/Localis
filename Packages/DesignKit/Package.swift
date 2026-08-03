// swift-tools-version: 6.0
import PackageDescription

// ============================================================================
//  DesignKit — the ONE design language for Localis.
//
//  Seeded from the my-designer swiftui scaffold: a single seed color derives
//  the whole primary token set; neutral + semantic palettes are FIXED and never
//  seed-derived. Ported from the macOS/AppKit template to iOS — the color
//  bridging goes through UIColor, the seed math is unchanged so Localis stays
//  visually consistent with the web design-system port.
// ============================================================================

let package = Package(
    name: "DesignKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DesignKit", targets: ["DesignKit"])
    ],
    targets: [
        .target(
            name: "DesignKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DesignKitTests",
            dependencies: ["DesignKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
