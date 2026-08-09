// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dodoma",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "DodomaCore",
            path: "Sources/DodomaCore"
        ),
        .executableTarget(
            name: "Dodoma",
            dependencies: ["DodomaCore"],
            path: "Sources/DodomaApp"
        ),
        .testTarget(
            name: "DodomaCoreTests",
            dependencies: ["DodomaCore"],
            path: "Tests/DodomaCoreTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
