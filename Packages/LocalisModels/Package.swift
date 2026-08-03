// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalisModels",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LocalisModels", targets: ["LocalisModels"])
    ],
    targets: [
        .target(
            name: "LocalisModels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LocalisModelsTests",
            dependencies: ["LocalisModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
