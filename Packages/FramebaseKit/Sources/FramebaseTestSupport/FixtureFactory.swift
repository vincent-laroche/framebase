import Foundation
import FramebaseDomain

public enum FixtureFactory {
    public static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    public static func folder(
        id: FolderID = FolderID(),
        name: String = "Reference",
        parentFolderID: FolderID? = nil,
        sortOrder: Int64 = 1_024,
        systemKind: FolderSystemKind? = nil
    ) throws -> Folder {
        Folder(
            id: id,
            name: try FolderName(name),
            parentFolderID: parentFolderID,
            createdAt: fixedDate,
            updatedAt: fixedDate,
            sortOrder: sortOrder,
            systemKind: systemKind
        )
    }

    public static func asset(
        id: AssetID = AssetID(),
        parentFolderID: FolderID = FolderID(),
        filename: String = "fixture.jpg"
    ) throws -> Asset {
        Asset(
            id: id,
            filename: filename,
            displayName: filename,
            parentFolderID: parentFolderID,
            storageKey: try AssetStorageKey("ab/\(id.description).jpg"),
            fileSize: 1_024,
            createdAt: fixedDate,
            modifiedAt: fixedDate,
            importedAt: fixedDate,
            updatedAt: fixedDate
        )
    }
}
