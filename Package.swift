// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskMapCore", targets: ["DiskMapCore"]),
        .executable(name: "DiskMapApp", targets: ["DiskMapApp"]),
        .executable(name: "DiskMapScanBench", targets: ["DiskMapScanBench"]),
        .executable(name: "AttrProbe", targets: ["AttrProbe"]),
        .executable(name: "SharingProbe", targets: ["SharingProbe"]),
    ],
    targets: [
        .target(name: "DiskMapCore", resources: [.process("quick-wins-patterns.json"), .process("file-type-categories.json")]),
        .executableTarget(
            name: "DiskMapApp",
            dependencies: ["DiskMapCore"],
            linkerSettings: [.linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing")]
        ),
        .testTarget(name: "DiskMapCoreTests", dependencies: ["DiskMapCore"]),
        // App-layer tests (ScanModel caches and state). Added with TASK-041;
        // the app target had no coverage before.
        .testTarget(name: "DiskMapAppTests", dependencies: ["DiskMapApp", "DiskMapCore"]),
        .executableTarget(name: "DiskMapScanBench", dependencies: ["DiskMapCore"]),
        .executableTarget(name: "AttrProbe"),
        .executableTarget(name: "SharingProbe"),
    ]
)
