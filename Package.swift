// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VikingBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VikingBarCore", targets: ["VikingBarCore"]),
        .executable(name: "VikingBarApp", targets: ["VikingBarApp"]),
        .executable(name: "vikingbar", targets: ["VikingBarCLI"]),
    ],
    targets: [
        .target(name: "VikingBarCore"),
        .executableTarget(name: "VikingBarApp", dependencies: ["VikingBarCore"], path: "Sources/VikingBar"),
        .executableTarget(name: "VikingBarCLI", dependencies: ["VikingBarCore"]),
        .testTarget(name: "VikingBarTests", dependencies: ["VikingBarCore", "VikingBarApp"]),
    ]
)
