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
        .library(name: "FramebaseCatalogSync", targets: ["FramebaseCatalogSync"]),
        .library(name: "FramebaseMigration", targets: ["FramebaseMigration"])
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
            dependencies: [
                "FramebaseDomain",
                "FramebaseAPIClient",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "FramebaseCatalogSync",
            dependencies: ["FramebaseDomain", "FramebaseCatalog", "FramebaseAPIClient", "FramebaseSync"]
        ),
        .target(
            name: "FramebaseMigration",
            dependencies: ["FramebaseDomain", "FramebaseCatalog", "FramebaseMedia", "FramebaseAPIClient", "FramebaseSync", .product(name: "GRDB", package: "GRDB.swift")]
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
        ),
        .testTarget(
            name: "FramebaseAPIClientTests",
            dependencies: ["FramebaseAPIClient", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseSyncTests",
            dependencies: ["FramebaseSync", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseCatalogSyncTests",
            dependencies: ["FramebaseCatalogSync", "FramebaseTestSupport"]
        ),
        .testTarget(
            name: "FramebaseMigrationTests",
            dependencies: ["FramebaseMigration", "FramebaseTestSupport"]
        )
    ]
)
