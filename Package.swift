// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AdSparkle",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
        .tvOS(.v13)
    ],
    products: [
        .library(
            name: "AdSparkle",
            targets: ["AdSparkle"]
        )
    ],
    targets: [
        .target(
            name: "AdSparkle",
            path: "Sources/AdSparkle",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
        .testTarget(
            name: "AdSparkleTests",
            dependencies: ["AdSparkle"],
            path: "Tests/AdSparkleTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
