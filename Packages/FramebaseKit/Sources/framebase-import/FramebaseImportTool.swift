import Foundation
import FramebaseCatalog
import FramebaseDomain
import FramebaseMedia

/// Development-only bulk importer.
///
/// Framebase's in-app import is deliberately flat: one batch lands in one
/// destination folder. This tool walks a source directory tree, mirrors it as
/// logical catalog folders, and runs one normal import batch per directory.
/// It uses the same `ManagedImportCoordinator`, `ManagedAssetBlobStore`, and
/// catalog repositories the app uses, so managed originals, immutable storage
/// keys, metadata extraction, and rollback behave exactly as they do in the UI.
///
/// It is not part of the shipping app and performs no filesystem mutation
/// outside the library package.
@main
struct FramebaseImportTool {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch let error as ToolError {
            FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Entry point

    private static func run(arguments: [String]) async throws {
        let options = try Options(arguments: arguments)

        if options.showHelp {
            print(Options.usage)
            return
        }

        let layout = try LibraryLayout(rootURL: options.libraryRootURL)
        let sources = try options.sources.map { try scan(source: $0) }
        let plannedFiles = sources.reduce(0) { $0 + $1.totalFileCount }
        let plannedFolders = sources.reduce(0) { $0 + $1.folderCount }

        print("Library:  \(layout.rootURL.path)")
        print("Sources:  \(sources.count)")
        print("Planned:  \(plannedFolders) folder(s), \(plannedFiles) file(s)")
        print("")

        if options.dryRun {
            for source in sources {
                printPlan(source, indent: 0)
            }
            print("")
            print("Dry run only. Nothing was written.")
            return
        }

        try layout.prepareDirectories()

        let catalog = try CatalogDatabase(catalogURL: layout.catalogDatabaseURL)
        let blobStore = try ManagedAssetBlobStore(
            originalsDirectoryURL: layout.originalsDirectoryURL,
            stagingDirectoryURL: layout.stagingDirectoryURL
        )
        let recovery = try await blobStore.recoverStaging()
        guard recovery.failedURLs.isEmpty else {
            throw ToolError("Could not safely recover \(recovery.failedURLs.count) item(s) left in Staging.")
        }
        if recovery.recoveredCount > 0 {
            print("Recovered \(recovery.recoveredCount) staged file(s) from a previous run.\n")
        }

        let coordinator = ManagedImportCoordinator(
            blobStore: blobStore,
            metadataExtractor: ImageIOMetadataExtractor(),
            insertIntoCatalog: { assets in
                try await catalog.insertAssets(assets)
            }
        )

        var importer = Importer(
            catalog: catalog,
            coordinator: coordinator,
            totalPlannedFiles: plannedFiles
        )
        try await importer.loadExistingFolders()

        for source in sources {
            try await importer.importNode(source, parentFolderID: nil)
        }

        importer.printSummary()
        if !importer.failures.isEmpty {
            exit(2)
        }
    }

    private static func printPlan(_ node: SourceNode, indent: Int) {
        let padding = String(repeating: "  ", count: indent)
        print("\(padding)\(node.name)/  (\(node.files.count) file(s))")
        for child in node.children {
            printPlan(child, indent: indent + 1)
        }
    }

    // MARK: - Source scanning

    /// One source directory that either holds importable files or leads to a
    /// descendant that does. Directories with no importable content anywhere
    /// below them are dropped so the catalog does not gain empty folders.
    struct SourceNode {
        let url: URL
        let name: String
        let files: [URL]
        let children: [SourceNode]

        var totalFileCount: Int {
            files.count + children.reduce(0) { $0 + $1.totalFileCount }
        }

        var folderCount: Int {
            1 + children.reduce(0) { $0 + $1.folderCount }
        }
    }

    private static func scan(source: Options.Source) throws -> SourceNode {
        guard let node = try scan(directoryURL: source.url, name: source.name) else {
            throw ToolError("No importable files found under \(source.url.path)")
        }
        return node
    }

    private static func scan(directoryURL: URL, name: String) throws -> SourceNode? {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var files: [URL] = []
        var children: [SourceNode] = []

        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                continue
            }
            if values.isDirectory == true {
                if let child = try scan(directoryURL: entry, name: entry.lastPathComponent) {
                    children.append(child)
                }
            } else if values.isRegularFile == true {
                files.append(entry)
            }
        }

        guard !files.isEmpty || !children.isEmpty else {
            return nil
        }
        return SourceNode(url: directoryURL, name: name, files: files, children: children)
    }

    // MARK: - Import

    struct Importer {
        let catalog: CatalogDatabase
        let coordinator: ManagedImportCoordinator
        let totalPlannedFiles: Int

        private(set) var failures: [ImportFailure] = []
        private var importedCount = 0
        private var skippedCount = 0
        private var createdFolderCount = 0
        private var reusedFolderCount = 0

        /// Keyed by parent folder id (or `""` for a root folder) plus the
        /// lowercased folder name, matching the catalog's case-insensitive
        /// sibling-name uniqueness index.
        private var folderIDsByKey: [String: FolderID] = [:]

        init(catalog: CatalogDatabase, coordinator: ManagedImportCoordinator, totalPlannedFiles: Int) {
            self.catalog = catalog
            self.coordinator = coordinator
            self.totalPlannedFiles = totalPlannedFiles
        }

        mutating func loadExistingFolders() async throws {
            let snapshot = try await catalog.folders.treeSnapshot()
            for folder in snapshot.folders where folder.systemKind == nil {
                folderIDsByKey[Self.key(parentFolderID: folder.parentFolderID, name: folder.name.rawValue)] = folder.id
            }
        }

        mutating func importNode(_ node: SourceNode, parentFolderID: FolderID?) async throws {
            let folderID = try await folder(named: node.name, in: parentFolderID)

            if !node.files.isEmpty {
                try await importFiles(node.files, into: folderID, label: node.name)
            }

            for child in node.children {
                try await importNode(child, parentFolderID: folderID)
            }
        }

        private mutating func folder(named name: String, in parentFolderID: FolderID?) async throws -> FolderID {
            let key = Self.key(parentFolderID: parentFolderID, name: name)
            if let existing = folderIDsByKey[key] {
                reusedFolderCount += 1
                return existing
            }

            let folderName = try FolderName(name)
            let folder = try await catalog.folders.createFolder(named: folderName, in: parentFolderID)
            folderIDsByKey[key] = folder.id
            createdFolderCount += 1
            return folder.id
        }

        /// Re-running the tool must not duplicate assets, so files whose exact
        /// filename already exists in the destination folder are skipped.
        private mutating func importFiles(_ files: [URL], into folderID: FolderID, label: String) async throws {
            let existingFilenames = try await existingFilenames(in: folderID)
            let pending = files.filter { !existingFilenames.contains($0.lastPathComponent) }
            let skipped = files.count - pending.count
            skippedCount += skipped

            guard !pending.isEmpty else {
                print("  \(label): \(skipped) already present, nothing to import")
                return
            }

            let result = try await coordinator.importAssets(
                ImportRequest(sourceURLs: pending, destinationFolderID: folderID),
                progress: { _ in }
            )

            if result.cancelled {
                throw ToolError("Import was cancelled while processing \(label).")
            }

            importedCount += result.importedAssetIDs.count
            failures.append(contentsOf: result.failures)

            var line = "  \(label): imported \(result.importedAssetIDs.count)"
            if skipped > 0 { line += ", skipped \(skipped)" }
            if !result.failures.isEmpty { line += ", failed \(result.failures.count)" }
            line += "  [\(importedCount + skippedCount + failures.count)/\(totalPlannedFiles)]"
            print(line)
        }

        private func existingFilenames(in folderID: FolderID) async throws -> Set<String> {
            let ids = try await catalog.assets.orderedIDs(
                matching: AssetQuery(scope: .folder(folderID)),
                sortedBy: AssetSort.defaultSort
            )
            guard !ids.isEmpty else { return [] }
            let assets = try await catalog.assets.assets(ids: Set(ids))
            return Set(assets.map(\.filename))
        }

        func printSummary() {
            print("")
            print("Imported: \(importedCount) asset(s)")
            print("Skipped:  \(skippedCount) already-present file(s)")
            print("Folders:  \(createdFolderCount) created, \(reusedFolderCount) reused")

            guard !failures.isEmpty else {
                print("Failed:   0")
                return
            }

            print("Failed:   \(failures.count)")
            for failure in failures {
                print("  - \(failure.sourceURL.path)")
                print("    \(failure.reason)")
            }
        }

        private static func key(parentFolderID: FolderID?, name: String) -> String {
            "\(parentFolderID?.description ?? "")/\(name.lowercased())"
        }
    }
}

// MARK: - Library layout

/// Mirrors the app's `LibraryPackageLayout`, which lives in the app target and
/// is not reachable from the package.
struct LibraryLayout {
    static let packageExtension = "framebase"

    let rootURL: URL

    init(rootURL: URL) throws {
        let standardized = rootURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == Self.packageExtension else {
            throw ToolError("A Framebase library must use the .framebase extension: \(standardized.lastPathComponent)")
        }
        self.rootURL = standardized
    }

    var catalogDirectoryURL: URL { rootURL.appendingPathComponent("Catalog", isDirectory: true) }
    var catalogDatabaseURL: URL { catalogDirectoryURL.appendingPathComponent("catalog.sqlite", isDirectory: false) }
    var originalsDirectoryURL: URL { rootURL.appendingPathComponent("Originals", isDirectory: true) }
    var stagingDirectoryURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    func prepareDirectories() throws {
        let fileManager = FileManager.default
        for url in [rootURL, catalogDirectoryURL, originalsDirectoryURL, stagingDirectoryURL] {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileType = attributes[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                throw ToolError("Framebase library folders cannot be symbolic links: \(url.path)")
            }
            guard fileType == .typeDirectory else {
                throw ToolError("A required Framebase library folder is not a directory: \(url.path)")
            }
        }
    }
}

// MARK: - Options

struct Options {
    struct Source {
        let url: URL
        let name: String
    }

    static let usage = """
        framebase-import — mirror a source directory tree into a Framebase library.

        usage: framebase-import --library <path.framebase> [--dry-run] <source>[=<folder name>] ...

          --library <path>   The .framebase package to import into. Created if missing.
          --dry-run          Print the folder plan without writing anything.
          -h, --help         Show this message.

        Each <source> directory becomes a top-level logical folder, and every
        subdirectory containing files becomes a nested logical folder. Append
        =<folder name> to override the top-level folder name.

        Originals are copied into the library; source files are never modified
        or moved. Re-running skips files whose filename already exists in the
        destination folder.
        """

    let libraryRootURL: URL
    let sources: [Source]
    let dryRun: Bool
    let showHelp: Bool

    init(arguments: [String]) throws {
        var libraryPath: String?
        var dryRun = false
        var showHelp = false
        var rawSources: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--library":
                index += 1
                guard index < arguments.count else {
                    throw ToolError("--library requires a path.")
                }
                libraryPath = arguments[index]
            case "--dry-run":
                dryRun = true
            case "-h", "--help":
                showHelp = true
            default:
                guard !argument.hasPrefix("--") else {
                    throw ToolError("Unknown option: \(argument)")
                }
                rawSources.append(argument)
            }
            index += 1
        }

        self.showHelp = showHelp
        self.dryRun = dryRun

        if showHelp {
            libraryRootURL = URL(fileURLWithPath: "/", isDirectory: true)
            sources = []
            return
        }

        guard let libraryPath else {
            throw ToolError("Missing --library <path.framebase>.\n\n\(Self.usage)")
        }
        guard !rawSources.isEmpty else {
            throw ToolError("Missing at least one source directory.\n\n\(Self.usage)")
        }

        libraryRootURL = URL(fileURLWithPath: (libraryPath as NSString).expandingTildeInPath, isDirectory: true)
        sources = try rawSources.map { try Self.parseSource($0) }
    }

    private static func parseSource(_ raw: String) throws -> Source {
        let fileManager = FileManager.default
        var path = raw
        var name: String?

        // `path=Name` is only split when the left side is a real directory, so
        // paths that legitimately contain "=" still resolve.
        if let separatorIndex = raw.lastIndex(of: "=") {
            let candidatePath = String(raw[raw.startIndex..<separatorIndex])
            let candidateName = String(raw[raw.index(after: separatorIndex)...])
            var isDirectory: ObjCBool = false
            let expanded = (candidatePath as NSString).expandingTildeInPath
            if !candidateName.isEmpty,
               fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
               isDirectory.boolValue {
                path = candidatePath
                name = candidateName
            }
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("Source is not an existing directory: \(url.path)")
        }

        return Source(url: url, name: name ?? url.lastPathComponent)
    }
}

// MARK: - Errors

struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
