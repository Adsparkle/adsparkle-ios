// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AdSparkle",
    platforms: [
        .iOS(.v13)
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
            path: "Sources/AdSparkle"
        )
    ]
)
