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
        .library(name: "FramebaseMedia", targets: ["FramebaseMedia"]),
        .library(name: "FramebaseAPIClient", targets: ["FramebaseAPIClient"]),
        .library(name: "FramebaseSync", targets: ["FramebaseSync"]),
        .library(name: "FramebaseFileProviderCore", targets: ["FramebaseFileProviderCore"]),
        .library(name: "FramebaseCLI", targets: ["FramebaseCLI"]),
        .executable(name: "framebase", targets: ["framebase"])
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
            name: "FramebaseAPIClient",
            dependencies: ["FramebaseDomain"]
        ),
        .target(
            name: "FramebaseSync",
            dependencies: ["FramebaseDomain", "FramebaseCatalog", "FramebaseMedia", "FramebaseAPIClient"]
        ),
        .target(
            name: "FramebaseFileProviderCore",
            dependencies: ["FramebaseDomain"]
        ),
        .target(
            name: "FramebaseCLI",
            dependencies: ["FramebaseDomain", "FramebaseCatalog"]
        ),
        .target(
            name: "FramebaseTestSupport",
            dependencies: ["FramebaseDomain"]
        ),
        // Development-only bulk folder-tree importer. Not part of the app target.
        .executableTarget(
            name: "framebase-import",
            dependencies: ["FramebaseDomain", "FramebaseCatalog", "FramebaseMedia"]
        ),
        .executableTarget(
            name: "framebase",
            dependencies: ["FramebaseCLI"]
        ),
        .testTarget(
            name: "FramebaseDomainTests",
            dependencies: ["FramebaseDomain", "FramebaseTestSupport"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "FramebaseCatalogTests",
            dependencies: ["FramebaseCatalog", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseMediaTests",
            dependencies: ["FramebaseMedia", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseAPIClientTests",
            dependencies: ["FramebaseAPIClient", "FramebaseDomain"]
        ),
        .testTarget(
            name: "FramebaseSyncTests",
            dependencies: ["FramebaseSync", "FramebaseCatalog", "FramebaseMedia", "FramebaseAPIClient", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseFileProviderCoreTests",
            dependencies: ["FramebaseFileProviderCore", "FramebaseDomain"]
        ),
        .testTarget(
            name: "FramebaseCLITests",
            dependencies: ["FramebaseCLI", "FramebaseCatalog", "FramebaseDomain", "FramebaseTestSupport"]
        )
    ]
)
