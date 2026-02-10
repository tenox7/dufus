// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dufus",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CWipefs",
            linkerSettings: [
                .linkedLibrary("util"),
            ]
        ),
        .target(
            name: "CDecompressors",
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("lzma"),
            ]
        ),
        .executableTarget(
            name: "Dufus",
            dependencies: ["CWipefs", "CDecompressors"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
