// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransportKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TransportKit", targets: ["TransportKit"])
    ],
    dependencies: [
        .package(path: "../LocalisModels")
    ],
    targets: [
        .target(
            name: "TransportKit",
            dependencies: ["LocalisModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TransportKitTests",
            dependencies: ["TransportKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
