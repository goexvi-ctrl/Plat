// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Plat", targets: ["PlatApp"]),
        .executable(name: "plat-bench", targets: ["PlatBench"]),
        .library(name: "PlatCore", targets: ["PlatCore"]),
    ],
    targets: [
        .target(name: "PlatCore"),
        .executableTarget(name: "PlatApp", dependencies: ["PlatCore"]),
        .executableTarget(name: "PlatBench", dependencies: ["PlatCore"]),
        .testTarget(name: "PlatCoreTests", dependencies: ["PlatCore"]),
    ]
)
