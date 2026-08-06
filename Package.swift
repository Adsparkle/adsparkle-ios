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
            path: "Sources/AdSparkle",
            // App Store zorunlu Privacy Manifest'i kaynak jarinin/bundle'in icine
            // kopyala (islenmeden, aynen).
            resources: [
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        // Test target — yayin artefaktina girmez. Testler gercek bir localhost
        // HTTP sunucusuna karsi URLSession'in TAM yolunu kosar (mock URLProtocol yok).
        .testTarget(
            name: "AdSparkleTests",
            dependencies: ["AdSparkle"],
            path: "Tests/AdSparkleTests"
        )
    ]
)
