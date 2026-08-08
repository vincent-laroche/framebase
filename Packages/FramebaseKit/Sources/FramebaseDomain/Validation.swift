import Foundation

public enum DomainValidationError: Error, Equatable, Sendable {
    case emptyFolderName
    case folderNameTooLong(maximum: Int)
    case invalidFolderNameCharacter
    case ratingOutOfRange
    case invalidStorageKey
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
