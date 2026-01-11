// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MarmotIM",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MarmotIM", targets: ["MarmotIM"]),
    ],
    dependencies: [
        // SQLite wrapper (optional - we're using raw SQLite3 for now)
        // .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.14.0"),
    ],
    targets: [
        .executableTarget(
            name: "MarmotIM",
            dependencies: [],
            path: "MarmotIM",
            exclude: ["Info.plist", "en.lproj", "zh-Hans.lproj"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("InputMethodKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "MarmotIMTests",
            dependencies: ["MarmotIM"],
            path: "MarmotIMTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
