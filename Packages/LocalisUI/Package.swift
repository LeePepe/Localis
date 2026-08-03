// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalisUI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LocalisUI", targets: ["LocalisUI"])
    ],
    dependencies: [
        .package(path: "../LocalisModels"),
        .package(path: "../DesignKit"),
        .package(path: "../ChatService")
    ],
    targets: [
        .target(
            name: "LocalisUI",
            dependencies: ["LocalisModels", "DesignKit", "ChatService"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalisUITests",
            // `ChatService` is already this package's dependency; the test
            // target names it so the seam between its session mapping and this
            // layer's wording can be asserted rather than restated.
            dependencies: ["LocalisUI", "ChatService"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
