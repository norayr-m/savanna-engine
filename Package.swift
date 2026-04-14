// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SavannaEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Savanna", targets: ["Savanna"]),
        .executable(name: "savanna-cli", targets: ["SavannaCLI"]),
        .executable(name: "savanna-play", targets: ["SavannaPlay"]),
        .executable(name: "savanna-bench", targets: ["SavannaBench"]),
    ],
    targets: [
        .target(
            name: "Savanna",
            path: "Sources/Savanna",
            resources: [.process("Shaders")]
        ),
        .executableTarget(
            name: "SavannaCLI",
            dependencies: ["Savanna"],
            path: "Sources/SavannaCLI"
        ),
        .executableTarget(
            name: "SavannaPlay",
            dependencies: ["Savanna"],
            path: "Sources/SavannaPlay"
        ),
        .executableTarget(
            name: "SavannaBench",
            dependencies: ["Savanna"],
            path: "Sources/SavannaBench"
        ),
        .testTarget(
            name: "SavannaTests",
            dependencies: ["Savanna"],
            path: "Tests/SavannaTests"
        ),
    ]
)
