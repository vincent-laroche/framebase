import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
    case emptyFolderName
    case folderNameTooLong(maximum: Int)
    case invalidFolderNameCharacter
    case ratingOutOfRange
    case invalidStorageKey
    case invalidTagName
    case invalidTagCardinality
    case invalidSavedSearchName
}

/// Stable, searchable `namespace:value` tag vocabulary. Tags intentionally
/// use lowercase URL-safe slugs so a local catalog and the synced API share
/// one identity without locale-dependent normalization.
public struct TagName: Codable, Hashable, Sendable, CustomStringConvertible {
    public let namespace: String
    public let value: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              Self.isSlug(String(parts[0])),
              Self.isSlug(String(parts[1])) else {
            throw DomainValidationError.invalidTagName
        }
        namespace = String(parts[0])
        value = String(parts[1])
    }

    public init(namespace: String, value: String) throws {
        try self.init("\(namespace):\(value)")
    }

    public var rawValue: String { "\(namespace):\(value)" }
    public var description: String { rawValue }

    private static func isSlug(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) ||
            ($0.value >= 97 && $0.value <= 122) ||
            $0.value == 45
        }
    }
}

public struct SavedSearchName: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 120, !normalized.contains("\0") else {
            throw DomainValidationError.invalidSavedSearchName
        }
        rawValue = normalized
    }

    public var description: String { rawValue }
}

public struct FolderName: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumLength = 255
    public let rawValue: String

    public init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw DomainValidationError.emptyFolderName
        }
        guard trimmed.count <= Self.maximumLength else {
            throw DomainValidationError.folderNameTooLong(maximum: Self.maximumLength)
        }
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw DomainValidationError.invalidFolderNameCharacter
        }

        rawValue = trimmed
    }

    public var description: String { rawValue }
}

public struct AssetRating: Codable, Hashable, Comparable, Sendable {
    public static let unrated = try! AssetRating(0)
    public let rawValue: Int

    public init(_ value: Int) throws {
        guard (0...5).contains(value) else {
            throw DomainValidationError.ratingOutOfRange
        }
        rawValue = value
    }

    public static func < (lhs: AssetRating, rhs: AssetRating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AssetStorageKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains(".."),
              !value.contains("\0") else {
            throw DomainValidationError.invalidStorageKey
        }
        rawValue = value
    }

    public var description: String { rawValue }
}
