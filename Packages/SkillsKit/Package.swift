// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkillsKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SkillsKit", targets: ["SkillsKit"])
    ],
    dependencies: [
        .package(path: "../LocalisModels")
    ],
    targets: [
        .target(
            name: "SkillsKit",
            dependencies: ["LocalisModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SkillsKitTests",
            dependencies: ["SkillsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
