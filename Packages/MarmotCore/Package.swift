// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarmotCore",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "MarmotCore",
            targets: ["MarmotCore"]
        ),
    ],
    targets: [
        .target(
            name: "MarmotCore",
            path: "Sources",
            swiftSettings: [
                .define("MARMOT_CORE")
            ]
        ),
        .testTarget(
            name: "MarmotCoreTests",
            dependencies: ["MarmotCore"],
            path: "Tests"
        ),
    ]
)
