import Foundation
import FramebaseDomain
import GRDB

struct AssetRecord: FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "assets"

    let id: String
    let filename: String
    let displayName: String
    let parentFolderID: String
    let storageKey: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let fileSize: Int64
    let createdAtMilliseconds: Int64
    let modifiedAtMilliseconds: Int64
    let importedAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
    let favorite: Bool
    let rating: Int
    let metadataJSON: String
    let originalAvailable: Bool

    enum Columns: String, ColumnExpression {
        case id
        case filename
        case displayName = "display_name"
        case parentFolderID = "parent_folder_id"
        case storageKey = "storage_key"
        case mediaType = "media_type"
        case width
        case height
        case fileSize = "file_size"
        case createdAtMilliseconds = "created_at_ms"
        case modifiedAtMilliseconds = "modified_at_ms"
        case importedAtMilliseconds = "imported_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
        case favorite
        case rating
        case metadataJSON = "metadata_json"
        case originalAvailable = "original_available"
    }

    init(asset: Asset, originalAvailable: Bool) throws {
        id = asset.id.description
        filename = asset.filename
        displayName = try CatalogValidation.normalizedName(asset.displayName)
        parentFolderID = asset.parentFolderID.description
        storageKey = asset.storageKey.rawValue
        mediaType = asset.mediaType.rawValue
        width = asset.width
        height = asset.height
        fileSize = asset.fileSize
        createdAtMilliseconds = CatalogDate.milliseconds(asset.createdAt)
        modifiedAtMilliseconds = CatalogDate.milliseconds(asset.modifiedAt)
        importedAtMilliseconds = CatalogDate.milliseconds(asset.importedAt)
        updatedAtMilliseconds = CatalogDate.milliseconds(asset.updatedAt)
        favorite = asset.favorite
        rating = asset.rating.rawValue
        let data = try JSONEncoder().encode(asset.metadata)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidPersistedValue("metadata_json")
        }
        metadataJSON = json
        self.originalAvailable = originalAvailable
    }

    init(row: Row) {
        id = row[Columns.id]
        filename = row[Columns.filename]
        displayName = row[Columns.displayName]
        parentFolderID = row[Columns.parentFolderID]
        storageKey = row[Columns.storageKey]
        mediaType = row[Columns.mediaType]
        width = row[Columns.width]
        height = row[Columns.height]
        fileSize = row[Columns.fileSize]
        createdAtMilliseconds = row[Columns.createdAtMilliseconds]
        modifiedAtMilliseconds = row[Columns.modifiedAtMilliseconds]
        importedAtMilliseconds = row[Columns.importedAtMilliseconds]
        updatedAtMilliseconds = row[Columns.updatedAtMilliseconds]
        favorite = row[Columns.favorite]
        rating = row[Columns.rating]
        metadataJSON = row[Columns.metadataJSON]
        originalAvailable = row[Columns.originalAvailable]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.filename] = filename
        container[Columns.displayName] = displayName
        container[Columns.parentFolderID] = parentFolderID
        container[Columns.storageKey] = storageKey
        container[Columns.mediaType] = mediaType
        container[Columns.width] = width
        container[Columns.height] = height
        container[Columns.fileSize] = fileSize
        container[Columns.createdAtMilliseconds] = createdAtMilliseconds
        container[Columns.modifiedAtMilliseconds] = modifiedAtMilliseconds
        container[Columns.importedAtMilliseconds] = importedAtMilliseconds
        container[Columns.updatedAtMilliseconds] = updatedAtMilliseconds
        container[Columns.favorite] = favorite
        container[Columns.rating] = rating
        container[Columns.metadataJSON] = metadataJSON
        container[Columns.originalAvailable] = originalAvailable
    }

    func domainAsset() throws -> Asset {
        guard let assetUUID = UUID(uuidString: id) else {
            throw CatalogError.invalidPersistedIdentifier(id)
        }
        guard let folderUUID = UUID(uuidString: parentFolderID) else {
            throw CatalogError.invalidPersistedIdentifier(parentFolderID)
        }
        guard let type = MediaType(rawValue: mediaType) else {
            throw CatalogError.invalidPersistedValue(mediaType)
        }

        return Asset(
            id: AssetID(rawValue: assetUUID),
            filename: filename,
            displayName: displayName,
            parentFolderID: FolderID(rawValue: folderUUID),
            storageKey: try AssetStorageKey(storageKey),
            localURL: nil,
            mediaType: type,
            width: width,
            height: height,
            fileSize: fileSize,
            createdAt: CatalogDate.date(createdAtMilliseconds),
            modifiedAt: CatalogDate.date(modifiedAtMilliseconds),
            importedAt: CatalogDate.date(importedAtMilliseconds),
            updatedAt: CatalogDate.date(updatedAtMilliseconds),
            favorite: favorite,
            rating: try AssetRating(rating),
            metadata: try JSONDecoder().decode(AssetMetadata.self, from: Data(metadataJSON.utf8))
        )
    }

    func gridRecord() throws -> AssetGridRecord {
        guard let assetUUID = UUID(uuidString: id) else {
            throw CatalogError.invalidPersistedIdentifier(id)
        }
        return AssetGridRecord(
            id: AssetID(rawValue: assetUUID),
            displayName: displayName,
            storageKey: try AssetStorageKey(storageKey),
            fileSize: fileSize,
            modifiedAt: CatalogDate.date(modifiedAtMilliseconds),
            width: width,
            height: height,
            favorite: favorite,
            rating: try AssetRating(rating),
            originalAvailable: originalAvailable
        )
    }
}

struct FolderRecord: FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "folders"

    let id: String
    let name: String
    let parentFolderID: String?
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
    let sortOrder: Int64
    let systemKind: String?

    enum Columns: String, ColumnExpression {
        case id
        case name
        case parentFolderID = "parent_folder_id"
        case createdAtMilliseconds = "created_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
        case sortOrder = "sort_order"
        case systemKind = "system_kind"
    }

    init(folder: Folder) {
        id = folder.id.description
        name = folder.name.rawValue
        parentFolderID = folder.parentFolderID?.description
        createdAtMilliseconds = CatalogDate.milliseconds(folder.createdAt)
        updatedAtMilliseconds = CatalogDate.milliseconds(folder.updatedAt)
        sortOrder = folder.sortOrder
        systemKind = folder.systemKind?.rawValue
    }

    init(row: Row) {
        id = row[Columns.id]
        name = row[Columns.name]
        parentFolderID = row[Columns.parentFolderID]
        createdAtMilliseconds = row[Columns.createdAtMilliseconds]
        updatedAtMilliseconds = row[Columns.updatedAtMilliseconds]
        sortOrder = row[Columns.sortOrder]
        systemKind = row[Columns.systemKind]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.parentFolderID] = parentFolderID
        container[Columns.createdAtMilliseconds] = createdAtMilliseconds
        container[Columns.updatedAtMilliseconds] = updatedAtMilliseconds
        container[Columns.sortOrder] = sortOrder
        container[Columns.systemKind] = systemKind
    }

    func domainFolder() throws -> Folder {
        guard let uuid = UUID(uuidString: id) else {
            throw CatalogError.invalidPersistedIdentifier(id)
        }
        let parentID: FolderID?
        if let parentFolderID {
            guard let parentUUID = UUID(uuidString: parentFolderID) else {
                throw CatalogError.invalidPersistedIdentifier(parentFolderID)
            }
            parentID = FolderID(rawValue: parentUUID)
        } else {
            parentID = nil
        }
        let kind: FolderSystemKind?
        if let systemKind {
            guard let decodedKind = FolderSystemKind(rawValue: systemKind) else {
                throw CatalogError.invalidPersistedValue(systemKind)
            }
            kind = decodedKind
        } else {
            kind = nil
        }
        return Folder(
            id: FolderID(rawValue: uuid),
            name: try FolderName(name),
            parentFolderID: parentID,
            createdAt: CatalogDate.date(createdAtMilliseconds),
            updatedAt: CatalogDate.date(updatedAtMilliseconds),
            sortOrder: sortOrder,
            systemKind: kind
        )
    }
}

struct AlbumRecord: FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "albums"

    let id: String
    let name: String
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
    let sortOrder: Int64

    enum Columns: String, ColumnExpression {
        case id
        case name
        case createdAtMilliseconds = "created_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
        case sortOrder = "sort_order"
    }

    init(album: Album) {
        id = album.id.description
        name = album.name
        createdAtMilliseconds = CatalogDate.milliseconds(album.createdAt)
        updatedAtMilliseconds = CatalogDate.milliseconds(album.updatedAt)
        sortOrder = album.sortOrder
    }

    init(row: Row) {
        id = row[Columns.id]
        name = row[Columns.name]
        createdAtMilliseconds = row[Columns.createdAtMilliseconds]
        updatedAtMilliseconds = row[Columns.updatedAtMilliseconds]
        sortOrder = row[Columns.sortOrder]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.createdAtMilliseconds] = createdAtMilliseconds
        container[Columns.updatedAtMilliseconds] = updatedAtMilliseconds
        container[Columns.sortOrder] = sortOrder
    }

    func domainAlbum() throws -> Album {
        guard let uuid = UUID(uuidString: id) else {
            throw CatalogError.invalidPersistedIdentifier(id)
        }
        return Album(
            id: AlbumID(rawValue: uuid),
            name: name,
            createdAt: CatalogDate.date(createdAtMilliseconds),
            updatedAt: CatalogDate.date(updatedAtMilliseconds),
            sortOrder: sortOrder
        )
    }
}
