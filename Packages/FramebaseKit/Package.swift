// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FramebaseKit",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "FramebaseDomain", targets: ["FramebaseDomain"]),
        .library(name: "FramebaseCatalog", targets: ["FramebaseCatalog"]),
        .library(name: "FramebaseMedia", targets: ["FramebaseMedia"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        )
    ],
    targets: [
        .target(name: "FramebaseDomain"),
        .target(
            name: "FramebaseCatalog",
            dependencies: [
                "FramebaseDomain",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "FramebaseMedia",
            dependencies: ["FramebaseDomain"]
        ),
        .target(
            name: "FramebaseTestSupport",
            dependencies: ["FramebaseDomain"]
        ),
        .testTarget(
            name: "FramebaseDomainTests",
            dependencies: ["FramebaseDomain", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseCatalogTests",
            dependencies: ["FramebaseCatalog", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseMediaTests",
            dependencies: ["FramebaseMedia", "FramebaseTestSupport"]
        )
    ]
)
