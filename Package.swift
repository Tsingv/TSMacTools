// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacTools", targets: ["MacToolsApp"]),
        .library(name: "MacToolsCore", targets: ["MacToolsCore"]),
        .library(name: "MacToolsScripting", targets: ["MacToolsScripting"])
    ],
    targets: [
        .executableTarget(
            name: "MacToolsApp",
            dependencies: ["MacToolsCore", "MacToolsScripting"],
            exclude: ["Info.plist"]
        ),
        .target(name: "MacToolsCore"),
        .target(
            name: "MacToolsScripting",
            dependencies: ["MacToolsCore"]
        ),
        .testTarget(
            name: "MacToolsCoreTests",
            dependencies: ["MacToolsCore", "MacToolsScripting"]
        )
    ]
)
