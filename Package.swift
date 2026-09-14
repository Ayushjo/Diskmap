// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
        .executable(name: "DiskMapApp", targets: ["DiskMapApp"]),
        .executable(name: "DiskMapScanBench", targets: ["DiskMapScanBench"]),
    ],
    targets: [
        .target(name: "DiskMapCore", resources: [.process("quick-wins-patterns.json"), .process("file-type-categories.json")]),
        .executableTarget(
            name: "DiskMapApp",
            dependencies: ["DiskMapCore"],
            linkerSettings: [.linkedFramework("Quartz")]
        ),
        .testTarget(name: "DiskMapCoreTests", dependencies: ["DiskMapCore"]),
        .executableTarget(name: "DiskMapScanBench", dependencies: ["DiskMapCore"]),
    ]
)
