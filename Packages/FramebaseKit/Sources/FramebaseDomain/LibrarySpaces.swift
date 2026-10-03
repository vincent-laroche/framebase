import Foundation

/// One separately scoped Framebase library.
///
/// A library space is not a folder, album, tag, or saved view inside another
/// catalog. Personal photos, Hair Solutions, and screenshots each keep their
/// own catalog identity.
public enum LibrarySpace: String, Codable, CaseIterable, Hashable, Sendable {
    case personal
    case hairSolutions
    case screenshots

    public var displayName: String {
        switch self {
        case .personal: "Personal Library"
        case .hairSolutions: "HSC Library"
        case .screenshots: "Screenshots Library"
        }
    }

    public var packageName: String {
        "\(displayName).framebase"
    }

    public var symbolName: String {
        switch self {
        case .personal: "photo"
        case .hairSolutions: "briefcase"
        case .screenshots: "rectangle.on.rectangle"
        }
    }

    public var templateActionTitle: String {
        switch self {
        case .personal: "Apply Personal Library Template"
        case .hairSolutions: "Apply Hair Solutions Template"
        case .screenshots: "Apply Screenshots Library Template"
        }
    }

    public var tagNamespaces: [LibraryTagNamespaceTemplate] {
        switch self {
        case .personal: PersonalLibraryTemplate.tagNamespaces
        case .hairSolutions: HairSolutionsLibraryTemplate.tagNamespaces
        case .screenshots: ScreenshotsLibraryTemplate.tagNamespaces
        }
    }

    public var initialFolders: [LibraryFolderTemplate] {
        switch self {
        case .personal: PersonalLibraryTemplate.initialFolders
        case .hairSolutions: HairSolutionsLibraryTemplate.initialFolders
        case .screenshots: ScreenshotsLibraryTemplate.initialFolders
        }
    }

    public var onFirstUseFolderPaths: [String] {
        switch self {
        case .personal: PersonalLibraryTemplate.onFirstUseFolderPaths
        case .hairSolutions: HairSolutionsLibraryTemplate.onFirstUseFolderPaths
        case .screenshots: ScreenshotsLibraryTemplate.onFirstUseFolderPaths
        }
    }

    public func validates(_ tagName: TagName) -> Bool {
        switch self {
        case .personal: PersonalLibraryTemplate.validates(tagName)
        case .hairSolutions: HairSolutionsLibraryTemplate.validates(tagName)
        case .screenshots: ScreenshotsLibraryTemplate.validates(tagName)
        }
    }

    public func initialTagNames() throws -> [TagName] {
        switch self {
        case .personal: try PersonalLibraryTemplate.initialTagNames()
        case .hairSolutions: try HairSolutionsLibraryTemplate.initialTagNames()
        case .screenshots: try ScreenshotsLibraryTemplate.initialTagNames()
        }
    }

    /// Matches a package file name to a space. The historical Personal package
    /// `Framebase Library.framebase` is intentionally not renamed here.
    public static func inferred(from rootURL: URL) -> LibrarySpace? {
        let packageName = rootURL.lastPathComponent
        return allCases.first { $0.packageName == packageName }
    }
}

public struct LibraryRegistration: Codable, Hashable, Identifiable, Sendable {
    public let catalogID: CatalogID
    public let displayName: String
    public let space: LibrarySpace
    public let rootPath: String

    public var id: CatalogID { catalogID }
    public var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }

    public init(catalogID: CatalogID, displayName: String, space: LibrarySpace, rootURL: URL) {
        self.catalogID = catalogID
        self.displayName = displayName
        self.space = space
        self.rootPath = rootURL.standardizedFileURL.path
    }
}

public enum LibraryRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case catalogIDMismatch(expected: CatalogID, observed: CatalogID)
    case librarySpaceConflict(existing: LibrarySpace, requested: LibrarySpace)
    case unavailableRoot(String)

    public var errorDescription: String? {
        switch self {
        case let .catalogIDMismatch(expected, observed):
            "This library package is registered as catalog \(expected.description), but the catalog file is \(observed.description). Framebase will not retarget it."
        case let .librarySpaceConflict(existing, requested):
            "This library is \(existing.displayName) and cannot be opened as \(requested.displayName)."
        case let .unavailableRoot(path):
            "Framebase cannot open the library because its package is unavailable: \(path)"
        }
    }
}

public enum LibraryRegistrationRules {
    /// The last-opened package from before the registry existed stays Personal
    /// at its current path. This does not rename `Framebase Library.framebase`.
    public static func legacyPersonalLibrary(catalogID: CatalogID, rootPath: String) -> LibraryRegistration {
        LibraryRegistration(
            catalogID: catalogID,
            displayName: LibrarySpace.personal.displayName,
            space: .personal,
            rootURL: URL(fileURLWithPath: rootPath, isDirectory: true)
        )
    }

    public static func requireAvailableRoot(_ rootPath: String, isDirectory: Bool) throws {
        guard !rootPath.isEmpty, isDirectory else {
            throw LibraryRegistrationError.unavailableRoot(rootPath)
        }
    }

    /// Inserts or updates one registration.
    ///
    /// The same catalog may move to a new package path. A package path cannot
    /// adopt a different catalog ID, and an existing space cannot be retargeted.
    public static func upsert(
        existing libraries: [LibraryRegistration],
        catalogID: CatalogID,
        rootPath: String,
        preferredSpace: LibrarySpace?
    ) throws -> [LibraryRegistration] {
        let path = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let byPath = libraries.first { $0.rootPath == path }
        let byCatalog = libraries.first { $0.catalogID == catalogID }

        if let byPath, byPath.catalogID != catalogID {
            throw LibraryRegistrationError.catalogIDMismatch(expected: byPath.catalogID, observed: catalogID)
        }

        let prior = byPath ?? byCatalog
        if let prior, let preferredSpace, preferredSpace != prior.space {
            throw LibraryRegistrationError.librarySpaceConflict(existing: prior.space, requested: preferredSpace)
        }

        let space = preferredSpace ?? prior?.space ?? .personal
        let registration = LibraryRegistration(
            catalogID: catalogID,
            displayName: prior?.displayName ?? space.displayName,
            space: space,
            rootURL: URL(fileURLWithPath: path, isDirectory: true)
        )
        var updated = libraries.filter { $0.catalogID != catalogID && $0.rootPath != path }
        updated.append(registration)
        updated.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return updated
    }
}
