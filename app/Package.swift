// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BuildThreadsPet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BuildThreadsPet", targets: ["BuildThreadsPet"]),
        .library(name: "PetCore", targets: ["PetCore"]),
    ],
    targets: [
        // Pure-Foundation logic: threads.json parsing, mood, transitions, pet manifests.
        .target(name: "PetCore", path: "Sources/PetCore"),
        // AppKit shell: floating panel, popover, menubar, hotkey, file watcher.
        .executableTarget(
            name: "BuildThreadsPet",
            dependencies: ["PetCore"],
            path: "Sources/BuildThreadsPet"
        ),
        .testTarget(
            name: "PetCoreTests",
            dependencies: ["PetCore"],
            path: "Tests/PetCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
