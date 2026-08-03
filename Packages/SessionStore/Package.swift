// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionStore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SessionStore", targets: ["SessionStore"])
    ],
    dependencies: [
        .package(path: "../LocalisModels")
    ],
    targets: [
        .target(
            name: "SessionStore",
            dependencies: ["LocalisModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SessionStoreTests",
            dependencies: ["SessionStore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
