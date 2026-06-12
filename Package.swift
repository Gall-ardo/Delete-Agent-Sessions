// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "delses",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "delses",
            targets: [
                "delses",
            ]
        ),
    ],
    targets: [
        .target(
            name: "DelsesCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "delses",
            dependencies: [
                "DelsesCore",
            ]
        ),
        .testTarget(
            name: "DelsesCoreTests",
            dependencies: [
                "DelsesCore",
            ]
        ),
    ]
)
