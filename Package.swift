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
        // The command-line companion (TASK-057): `swift run diskmap --help`.
        .executable(name: "diskmap", targets: ["diskmap"]),
    ],
    // Sparkle (TASK-083): the one networking dependency, used only by
    // Sources/DiskMapApp/Updates.swift and only when the user asks — automatic
    // checks are off by default. See AGENTS.md rule 2.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "DiskMapCore", resources: [.process("quick-wins-patterns.json"), .process("file-type-categories.json"), .process("developer-rules.json"), .process("cleanup-recipes.json")]),
        .target(name: "DiskMapBrand", resources: [.copy("Resources/dusty-peek-mark.svg")]),
        .executableTarget(
            name: "DiskMapApp",
            dependencies: ["DiskMapCore", "DiskMapBrand", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("Quartz"), .linkedFramework("QuickLookThumbnailing")]
        ),
        .testTarget(name: "DiskMapCoreTests", dependencies: ["DiskMapCore"]),
        // App-layer tests (ScanModel caches and state). Added with TASK-041;
        // the app target had no coverage before.
        .testTarget(name: "DiskMapAppTests", dependencies: ["DiskMapApp", "DiskMapCore"]),
        .executableTarget(name: "DiskMapScanBench", dependencies: ["DiskMapCore"]),
        .executableTarget(name: "AttrProbe"),
        .executableTarget(name: "SharingProbe"),
        // Visual regression check for scripts/render-all.sh (TASK-084).
        .executableTarget(name: "ImageDiff"),
        // Draws the app icon (TASK-083): swift run IconRender 1 build/AppIcon.iconset
        .executableTarget(name: "IconRender", dependencies: ["DiskMapBrand"]),
        .executableTarget(name: "diskmap", dependencies: ["DiskMapCore"]),
    ]
)
