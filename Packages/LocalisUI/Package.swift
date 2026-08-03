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
            dependencies: ["LocalisUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
