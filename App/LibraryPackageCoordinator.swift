import Foundation

enum LibraryPackageError: Error, LocalizedError, Sendable {
    case invalidExtension(URL)
    case existingItemIsNotDirectory(URL)
    case symbolicLinkNotSupported(URL)
    case managedDirectoryIsNotDirectory(URL)
    case managedDirectoryIsSymbolicLink(URL)
    case catalogIsNotRegularFile(URL)
    case catalogIsSymbolicLink(URL)
    case stagingRecoveryFailed(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidExtension(url):
            "Framebase libraries must use the .framebase extension: \(url.lastPathComponent)"
        case let .existingItemIsNotDirectory(url):
            "The selected library is not a directory: \(url.path)"
        case let .symbolicLinkNotSupported(url):
            "Framebase libraries cannot be symbolic links: \(url.path)"
        case let .managedDirectoryIsNotDirectory(url):
            "A required Framebase library folder is not a directory: \(url.path)"
        case let .managedDirectoryIsSymbolicLink(url):
            "Framebase library folders cannot be symbolic links: \(url.path)"
        case let .catalogIsNotRegularFile(url):
            "The Framebase catalog is not a regular file: \(url.path)"
        case let .catalogIsSymbolicLink(url):
            "The Framebase catalog cannot be a symbolic link: \(url.path)"
        case let .stagingRecoveryFailed(count):
            "Framebase could not safely recover \(count) item(s) left in Staging."
        }
    }
}

struct LibraryPackageLayout: Equatable, Sendable {
    static let packageExtension = "framebase"
    static let defaultPackageName = "Framebase Library.framebase"

    let rootURL: URL

    var catalogDirectoryURL: URL {
        rootURL.appendingPathComponent("Catalog", isDirectory: true)
    }

    var catalogDatabaseURL: URL {
        catalogDirectoryURL.appendingPathComponent("catalog.sqlite", isDirectory: false)
    }

    var originalsDirectoryURL: URL {
        rootURL.appendingPathComponent("Originals", isDirectory: true)
    }

    var stagingDirectoryURL: URL {
        rootURL.appendingPathComponent("Staging", isDirectory: true)
    }

    var syncDirectoryURL: URL {
        rootURL.appendingPathComponent("Sync", isDirectory: true)
    }

    var syncDatabaseURL: URL {
        syncDirectoryURL.appendingPathComponent("sync.sqlite", isDirectory: false)
    }

    static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
        guard let picturesURL = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return picturesURL.appendingPathComponent(defaultPackageName, isDirectory: true)
    }
}

actor LibraryPackageCoordinator {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createLibrary(at rootURL: URL) throws -> LibraryPackageLayout {
        let layout = try validatedLayout(at: rootURL, mustExist: false)
        try prepareDirectories(for: layout)
        return layout
    }

    func openLibrary(at rootURL: URL) throws -> LibraryPackageLayout {
        let layout = try validatedLayout(at: rootURL, mustExist: true)
        try prepareDirectories(for: layout)
        return layout
    }

    private func validatedLayout(at rootURL: URL, mustExist: Bool) throws -> LibraryPackageLayout {
        let standardizedURL = rootURL.standardizedFileURL

        guard standardizedURL.pathExtension.lowercased() == LibraryPackageLayout.packageExtension else {
            throw LibraryPackageError.invalidExtension(standardizedURL)
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory)

        if mustExist, !exists {
            throw CocoaError(.fileNoSuchFile)
        }

        if exists {
            guard isDirectory.boolValue else {
                throw LibraryPackageError.existingItemIsNotDirectory(standardizedURL)
            }

            let resourceValues = try standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues.isSymbolicLink == true {
                throw LibraryPackageError.symbolicLinkNotSupported(standardizedURL)
            }
        }

        return LibraryPackageLayout(rootURL: standardizedURL)
    }

    private func prepareDirectories(for layout: LibraryPackageLayout) throws {
        for directoryURL in [
            layout.rootURL,
            layout.catalogDirectoryURL,
            layout.originalsDirectoryURL,
            layout.stagingDirectoryURL,
            layout.syncDirectoryURL
        ] {
            try prepareManagedDirectory(at: directoryURL)
        }

        if fileManager.fileExists(atPath: layout.catalogDatabaseURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: layout.catalogDatabaseURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                throw LibraryPackageError.catalogIsSymbolicLink(layout.catalogDatabaseURL)
            }
            guard fileType == .typeRegular else {
                throw LibraryPackageError.catalogIsNotRegularFile(layout.catalogDatabaseURL)
            }
        }
    }

    private func prepareManagedDirectory(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileType = attributes[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            throw LibraryPackageError.managedDirectoryIsSymbolicLink(url)
        }
        guard fileType == .typeDirectory else {
            throw LibraryPackageError.managedDirectoryIsNotDirectory(url)
        }
    }
}
