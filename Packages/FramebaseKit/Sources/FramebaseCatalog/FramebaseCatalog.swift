import Foundation
import FramebaseDomain
import GRDB

public enum FramebaseCatalogFoundation {
    public static let initialSchemaVersion = 1
    public static let migrationIdentifier = "v1_initial_catalog"
    public static let cloudMigrationIdentifier = "v2_cloud_sync_spine"
    public static let remoteEntityMigrationIdentifier = "v3_remote_entity_revisions"
    public static let organizationMigrationIdentifier = "v4_complete_organization"
    public static let organizationCloudParityMigrationIdentifier = "v5_organization_cloud_parity"
    public static let receiptCloudParityMigrationIdentifier = "v6_receipt_cloud_parity"
    public static let backupCloudParityMigrationIdentifier = "v7_backup_cloud_parity"
    public static let intelligenceMigrationIdentifier = "v8_local_intelligence"
    public static let visualLearningMigrationIdentifier = "v9_visual_learning_reviews"
    public static let workflowMigrationIdentifier = "v10_durable_workflow_runs"
    public static let currentSchemaVersion = 10

    public static func configure(_ configuration: inout Configuration) {
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        configuration.label = "Framebase Catalog"
    }
}

public enum CatalogError: Error, Equatable, Sendable {
    case invalidCatalogURL
    case missingCatalogIdentity
    case invalidPersistedIdentifier(String)
    case invalidPersistedValue(String)
    case invalidPage(offset: Int, limit: Int)
    case invalidAssetDisplayName
    case folderNotFound(FolderID)
    case albumNotFound(AlbumID)
    case systemFolderImmutable(FolderID)
    case invalidFolderParent(FolderID)
    case folderCycle
    case incompleteRestore
    case tagNotFound(TagID)
    case savedSearchNotFound(SavedSearchID)
}

/// The persistence boundary for one Framebase catalog.
///
/// It owns the GRDB pool and exposes domain-facing repositories. The supplied
/// URL is always the actual `catalog.sqlite` file; library package discovery
/// and original-file storage remain outside this module.
public final class CatalogDatabase: Sendable {
    public let catalogURL: URL
    public let catalogID: CatalogID
    public let inboxID: FolderID
    public let assets: CatalogAssetRepository
    public let folders: CatalogFolderRepository
    public let albums: CatalogAlbumRepository
    public let tags: CatalogTagRepository
    public let savedSearches: CatalogSavedSearchRepository
    public let exports: CatalogExportReceiptRepository
    public let backups: CatalogBackupManifestRepository
    public let intelligence: CatalogIntelligenceRepository
    public let visualLearning: CatalogVisualLearningRepository
    public let workflows: CatalogWorkflowRepository
    public let cloud: CatalogCloudRepository

    let databasePool: DatabasePool

    public init(catalogURL: URL) throws {
        guard catalogURL.isFileURL, !catalogURL.hasDirectoryPath else {
            throw CatalogError.invalidCatalogURL
        }

        var configuration = Configuration()
        FramebaseCatalogFoundation.configure(&configuration)
        let pool = try DatabasePool(path: catalogURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(pool)

        let identity = try pool.read { db -> (CatalogID, FolderID) in
            guard let catalogIDText = try String.fetchOne(
                db,
                sql: "SELECT value FROM catalog_settings WHERE key = 'catalog_id'"
            ), let catalogUUID = UUID(uuidString: catalogIDText) else {
                throw CatalogError.missingCatalogIdentity
            }
            guard let inboxIDText = try String.fetchOne(
                db,
                sql: "SELECT id FROM folders WHERE system_kind = 'inbox'"
            ), let inboxUUID = UUID(uuidString: inboxIDText) else {
                throw CatalogError.missingCatalogIdentity
            }
            return (CatalogID(rawValue: catalogUUID), FolderID(rawValue: inboxUUID))
        }

        self.catalogURL = catalogURL
        self.catalogID = identity.0
        self.inboxID = identity.1
        self.databasePool = pool
        self.assets = CatalogAssetRepository(databasePool: pool)
        self.folders = CatalogFolderRepository(databasePool: pool, inboxID: identity.1)
        self.albums = CatalogAlbumRepository(databasePool: pool)
        self.tags = CatalogTagRepository(databasePool: pool)
        self.savedSearches = CatalogSavedSearchRepository(databasePool: pool)
        self.exports = CatalogExportReceiptRepository(databasePool: pool)
        self.backups = CatalogBackupManifestRepository(databasePool: pool)
        self.intelligence = CatalogIntelligenceRepository(databasePool: pool)
        self.visualLearning = CatalogVisualLearningRepository(databasePool: pool)
        self.workflows = CatalogWorkflowRepository(databasePool: pool)
        self.cloud = CatalogCloudRepository(databasePool: pool)
    }

    /// Inserts an already committed managed original into the catalog.
    /// `Asset.localURL` is deliberately ignored and is never persisted.
    public func insertAsset(_ asset: Asset, originalAvailable: Bool = true) async throws {
        try await insertAssets([asset], originalAvailable: originalAvailable)
    }

    /// Atomically inserts a committed import batch. A constraint failure rolls
    /// back every catalog row in the batch so the import coordinator can clean
    /// up only the newly managed files.
    public func insertAssets(_ assets: [Asset], originalAvailable: Bool = true) async throws {
        guard !assets.isEmpty else { return }
        let records = try assets.map { try AssetRecord(asset: $0, originalAvailable: originalAvailable) }
        try await databasePool.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    /// Creates schema-backed album fixtures/integration records. Album editing
    /// remains outside the phase-one UI, but persistence exists from migration 1.
    @discardableResult
    public func createAlbum(named name: String, at date: Date = Date()) async throws -> Album {
        let normalizedName = try CatalogValidation.normalizedName(name)
        return try await databasePool.write { db in
            let sortOrder = try CatalogSortOrder.next(
                in: db,
                table: "albums",
                predicateSQL: "1",
                arguments: []
            )
            let album = Album(
                id: AlbumID(),
                name: normalizedName,
                createdAt: date,
                updatedAt: date,
                sortOrder: sortOrder
            )
            try AlbumRecord(album: album).insert(db)
            return album
        }
    }

    public func setOriginalAvailable(_ available: Bool, for assetID: AssetID) async throws {
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE assets SET original_available = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [available, CatalogDate.milliseconds(Date()), assetID.description]
            )
        }
    }

    /// Applies only the starter template's explicitly initial logical folders
    /// and controlled tag values. It never moves assets, changes original
    /// storage, or creates the intentionally on-first-use folders.
    public func previewHairSolutionsLibraryTemplate() async throws -> LibraryTemplateApplicationPreview {
        try await databasePool.read { db in
            var foldersByPath: [String: FolderID] = [:]
            var folderPathsToCreate: [String] = []
            for definition in HairSolutionsLibraryTemplate.initialFolders {
                guard let name = definition.path.last else { continue }
                let path = definition.path.joined(separator: "/")
                let parentPath = definition.path.dropLast().joined(separator: "/")
                let parentID = parentPath.isEmpty ? nil : foldersByPath[parentPath]
                let existingID: String?
                if let parentID {
                    existingID = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM folders WHERE parent_folder_id = ? AND name = ? COLLATE NOCASE",
                        arguments: [parentID.description, name]
                    )
                } else {
                    existingID = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM folders WHERE parent_folder_id IS NULL AND name = ? COLLATE NOCASE",
                        arguments: [name]
                    )
                }
                if let existingID, let uuid = UUID(uuidString: existingID) {
                    foldersByPath[path] = FolderID(rawValue: uuid)
                } else {
                    folderPathsToCreate.append(path)
                }
            }

            let controlledTagNames = try HairSolutionsLibraryTemplate.tagNamespaces
                .flatMap { namespace in
                    try namespace.allowedValues.map { try TagName(namespace: namespace.namespace, value: $0) }
                }
            let tagNamesToCreate = try controlledTagNames.filter { name in
                !(try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM tags WHERE name = ? COLLATE NOCASE)",
                    arguments: [name.rawValue]
                ) ?? false)
            }

            return LibraryTemplateApplicationPreview(
                folderPathsToCreate: folderPathsToCreate,
                tagNamesToCreate: tagNamesToCreate,
                onFirstUseFolderPaths: HairSolutionsLibraryTemplate.folders
                    .filter { $0.provisioning == .onFirstUse }
                    .map { $0.path.joined(separator: "/") }
            )
        }
    }

    public func applyHairSolutionsLibraryTemplate() async throws -> LibraryTemplateApplicationReceipt {
        try await databasePool.write { db in
            let now = Date()
            let milliseconds = CatalogDate.milliseconds(now)
            var foldersByPath: [String: FolderID] = [:]
            var createdFolderIDs: [FolderID] = []
            for definition in HairSolutionsLibraryTemplate.initialFolders {
                guard let name = definition.path.last else { continue }
                let parentPath = definition.path.dropLast().joined(separator: "/")
                let parentID = parentPath.isEmpty ? nil : foldersByPath[parentPath]
                if !parentPath.isEmpty, parentID == nil {
                    throw CatalogError.invalidPersistedValue("template_parent_path")
                }
                let existingID: String?
                if let parentID {
                    existingID = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM folders WHERE parent_folder_id = ? AND name = ? COLLATE NOCASE",
                        arguments: [parentID.description, name]
                    )
                } else {
                    existingID = try String.fetchOne(
                        db,
                        sql: "SELECT id FROM folders WHERE parent_folder_id IS NULL AND name = ? COLLATE NOCASE",
                        arguments: [name]
                    )
                }
                if let existingID, let uuid = UUID(uuidString: existingID) {
                    foldersByPath[definition.path.joined(separator: "/")] = FolderID(rawValue: uuid)
                    continue
                }
                let predicate = parentID == nil ? "parent_folder_id IS NULL" : "parent_folder_id = ?"
                let arguments: StatementArguments = parentID == nil ? [] : [parentID!.description]
                let folder = Folder(
                    id: FolderID(),
                    name: try FolderName(name),
                    parentFolderID: parentID,
                    createdAt: now,
                    updatedAt: now,
                    sortOrder: try CatalogSortOrder.next(in: db, table: "folders", predicateSQL: predicate, arguments: arguments)
                )
                try FolderRecord(folder: folder).insert(db)
                foldersByPath[definition.path.joined(separator: "/")] = folder.id
                createdFolderIDs.append(folder.id)
            }

            var createdTagIDs: [TagID] = []
            for namespace in HairSolutionsLibraryTemplate.tagNamespaces where !namespace.allowedValues.isEmpty {
                for value in namespace.allowedValues {
                    let name = try TagName(namespace: namespace.namespace, value: value)
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM tags WHERE name = ? COLLATE NOCASE)",
                        arguments: [name.rawValue]
                    ) ?? false
                    guard !exists else { continue }
                    let tag = Tag(name: name, createdAt: now, updatedAt: now)
                    try db.execute(
                        sql: "INSERT INTO tags (id, namespace, value, name, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?)",
                        arguments: [tag.id.description, name.namespace, name.value, name.rawValue, milliseconds, milliseconds]
                    )
                    createdTagIDs.append(tag.id)
                }
            }
            return LibraryTemplateApplicationReceipt(createdFolderIDs: createdFolderIDs, createdTagIDs: createdTagIDs)
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(FramebaseCatalogFoundation.migrationIdentifier) { db in
            try db.execute(sql: Self.initialSchemaSQL)

            let now = CatalogDate.milliseconds(Date())
            let inboxID = FolderID().description
            let catalogID = CatalogID().description
            try db.execute(
                sql: """
                    INSERT INTO folders
                        (id, name, parent_folder_id, created_at_ms, updated_at_ms, sort_order, system_kind)
                    VALUES (?, 'Inbox', NULL, ?, ?, 0, 'inbox')
                    """,
                arguments: [inboxID, now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO catalog_settings (key, value, updated_at_ms)
                    VALUES ('catalog_id', ?, ?), ('schema_version', '1', ?)
                    """,
                arguments: [catalogID, now, now]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.cloudMigrationIdentifier) { db in
            try db.execute(sql: Self.cloudSchemaSQL)
            try db.execute(
                sql: "UPDATE catalog_settings SET value = '2', updated_at_ms = ? WHERE key = 'schema_version'",
                arguments: [CatalogDate.milliseconds(Date())]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.remoteEntityMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE remote_entity_state (
                    entity_type TEXT NOT NULL CHECK(entity_type IN ('folder', 'album')),
                    entity_id TEXT NOT NULL CHECK(entity_id = lower(entity_id) AND length(entity_id) = 36),
                    remote_revision INTEGER NOT NULL CHECK(remote_revision >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(entity_type, entity_id)
                );
                CREATE INDEX remote_entity_state_revision_index
                    ON remote_entity_state(entity_type, remote_revision);
                """)
            try db.execute(
                sql: "UPDATE catalog_settings SET value = '3', updated_at_ms = ? WHERE key = 'schema_version'",
                arguments: [CatalogDate.milliseconds(Date())]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.organizationMigrationIdentifier) { db in
            try Self.applyOrganizationSchemaMigration(in: db)
            try db.execute(
                sql: "UPDATE catalog_settings SET value = '4', updated_at_ms = ? WHERE key = 'schema_version'",
                arguments: [CatalogDate.milliseconds(Date())]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.organizationCloudParityMigrationIdentifier) { db in
            try db.execute(sql: """
                ALTER TABLE remote_entity_state RENAME TO remote_entity_state_v3;
                DROP INDEX remote_entity_state_revision_index;
                CREATE TABLE remote_entity_state (
                    entity_type TEXT NOT NULL CHECK(entity_type IN ('folder', 'album', 'tag', 'saved_search')),
                    entity_id TEXT NOT NULL CHECK(entity_id = lower(entity_id) AND length(entity_id) = 36),
                    remote_revision INTEGER NOT NULL CHECK(remote_revision >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(entity_type, entity_id)
                );
                INSERT INTO remote_entity_state (entity_type, entity_id, remote_revision, updated_at_ms)
                SELECT entity_type, entity_id, remote_revision, updated_at_ms FROM remote_entity_state_v3;
                DROP TABLE remote_entity_state_v3;
                CREATE INDEX remote_entity_state_revision_index
                    ON remote_entity_state(entity_type, remote_revision);
                """)
            try db.execute(
                sql: "UPDATE catalog_settings SET value = '5', updated_at_ms = ? WHERE key = 'schema_version'",
                arguments: [CatalogDate.milliseconds(Date())]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.receiptCloudParityMigrationIdentifier) { db in
            try db.execute(sql: """
                ALTER TABLE remote_entity_state RENAME TO remote_entity_state_v5;
                DROP INDEX remote_entity_state_revision_index;
                CREATE TABLE remote_entity_state (
                    entity_type TEXT NOT NULL CHECK(entity_type IN ('folder', 'album', 'tag', 'saved_search', 'export_receipt')),
                    entity_id TEXT NOT NULL CHECK(entity_id = lower(entity_id) AND length(entity_id) = 36),
                    remote_revision INTEGER NOT NULL CHECK(remote_revision >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(entity_type, entity_id)
                );
                INSERT INTO remote_entity_state (entity_type, entity_id, remote_revision, updated_at_ms)
                SELECT entity_type, entity_id, remote_revision, updated_at_ms FROM remote_entity_state_v5;
                DROP TABLE remote_entity_state_v5;
                CREATE INDEX remote_entity_state_revision_index
                    ON remote_entity_state(entity_type, remote_revision);
                """)
            try db.execute(
                sql: "UPDATE catalog_settings SET value = '6', updated_at_ms = ? WHERE key = 'schema_version'",
                arguments: [CatalogDate.milliseconds(Date())]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.backupCloudParityMigrationIdentifier) { db in
            try db.execute(sql: """
                ALTER TABLE remote_entity_state RENAME TO remote_entity_state_v6;
                DROP INDEX remote_entity_state_revision_index;
                CREATE TABLE remote_entity_state (
                    entity_type TEXT NOT NULL CHECK(entity_type IN ('folder', 'album', 'tag', 'saved_search', 'export_receipt', 'backup_manifest')),
                    entity_id TEXT NOT NULL CHECK(entity_id = lower(entity_id) AND length(entity_id) = 36),
                    remote_revision INTEGER NOT NULL CHECK(remote_revision >= 0),
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(entity_type, entity_id)
                );
                INSERT INTO remote_entity_state (entity_type, entity_id, remote_revision, updated_at_ms)
                SELECT entity_type, entity_id, remote_revision, updated_at_ms FROM remote_entity_state_v6;
                DROP TABLE remote_entity_state_v6;
                CREATE INDEX remote_entity_state_revision_index
                    ON remote_entity_state(entity_type, remote_revision);
                """)
            try db.execute(
                sql: "UPDATE catalog_settings SET value = '7', updated_at_ms = ? WHERE key = 'schema_version'",
                arguments: [CatalogDate.milliseconds(Date())]
            )
        }
        migrator.registerMigration(FramebaseCatalogFoundation.intelligenceMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE analysis_results (
                    id TEXT PRIMARY KEY NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    engine TEXT NOT NULL,
                    request_revision INTEGER NOT NULL,
                    schema_version INTEGER NOT NULL,
                    derivative_sha256 TEXT NOT NULL,
                    derivative_maximum_pixel_dimension INTEGER NOT NULL,
                    captured_at_ms INTEGER NOT NULL,
                    locales_json TEXT NOT NULL CHECK(json_valid(locales_json)),
                    payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    UNIQUE(asset_id, kind, engine, request_revision, derivative_sha256)
                );
                CREATE INDEX analysis_results_asset_status_index ON analysis_results(asset_id, status, captured_at_ms DESC);
                CREATE TABLE analysis_text_lines (
                    result_id TEXT NOT NULL REFERENCES analysis_results(id) ON DELETE CASCADE,
                    line_index INTEGER NOT NULL,
                    normalized_text TEXT NOT NULL,
                    PRIMARY KEY(result_id, line_index)
                );
                CREATE INDEX analysis_text_lines_text_index ON analysis_text_lines(normalized_text);
                """)
            try db.execute(sql: "UPDATE catalog_settings SET value = '8', updated_at_ms = ? WHERE key = 'schema_version'", arguments: [CatalogDate.milliseconds(Date())])
        }
        migrator.registerMigration(FramebaseCatalogFoundation.visualLearningMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE visual_assessments (
                    id TEXT PRIMARY KEY NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    business_quality TEXT NOT NULL,
                    evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)),
                    photo_role TEXT NOT NULL,
                    hairline_presentation TEXT NOT NULL,
                    confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
                    rationale TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    model_identifier TEXT NOT NULL,
                    assessment_schema_version INTEGER NOT NULL CHECK(assessment_schema_version > 0),
                    derivative_sha256 TEXT NOT NULL,
                    derivative_maximum_pixel_dimension INTEGER NOT NULL CHECK(derivative_maximum_pixel_dimension BETWEEN 1 AND 1600),
                    captured_at_ms INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    UNIQUE(asset_id, provider, model_identifier, assessment_schema_version, derivative_sha256)
                );
                CREATE INDEX visual_assessments_asset_captured_index ON visual_assessments(asset_id, captured_at_ms DESC);
                CREATE TABLE visual_assessment_reviews (
                    id TEXT PRIMARY KEY NOT NULL,
                    assessment_id TEXT NOT NULL REFERENCES visual_assessments(id) ON DELETE CASCADE,
                    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    decision TEXT NOT NULL,
                    corrected_business_quality TEXT,
                    corrected_photo_role TEXT,
                    corrected_hairline_presentation TEXT,
                    reviewed_at_ms INTEGER NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );
                CREATE INDEX visual_assessment_reviews_assessment_index ON visual_assessment_reviews(assessment_id, reviewed_at_ms ASC);
                CREATE TABLE visual_assessment_feedback_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    assessment_id TEXT NOT NULL REFERENCES visual_assessments(id) ON DELETE CASCADE,
                    review_id TEXT REFERENCES visual_assessment_reviews(id) ON DELETE SET NULL,
                    outcome TEXT NOT NULL,
                    captured_at_ms INTEGER NOT NULL
                );
                CREATE INDEX visual_assessment_feedback_assessment_index ON visual_assessment_feedback_events(assessment_id, captured_at_ms ASC);
                CREATE TABLE before_after_relationships (
                    id TEXT PRIMARY KEY NOT NULL,
                    before_asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    after_asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    status TEXT NOT NULL,
                    source_assessment_id TEXT REFERENCES visual_assessments(id) ON DELETE SET NULL,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    CHECK(before_asset_id != after_asset_id),
                    UNIQUE(before_asset_id, after_asset_id)
                );
                CREATE INDEX before_after_relationships_asset_index ON before_after_relationships(before_asset_id, after_asset_id, status);
                """)
            try db.execute(sql: "UPDATE catalog_settings SET value = '9', updated_at_ms = ? WHERE key = 'schema_version'", arguments: [CatalogDate.milliseconds(Date())])
        }
        migrator.registerMigration(FramebaseCatalogFoundation.workflowMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE workflow_definitions (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    schema_version INTEGER NOT NULL CHECK(schema_version > 0),
                    definition_json TEXT NOT NULL CHECK(json_valid(definition_json)),
                    is_enabled INTEGER NOT NULL CHECK(is_enabled IN (0, 1)),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE workflow_runs (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    definition_id TEXT NOT NULL REFERENCES workflow_definitions(id) ON DELETE RESTRICT,
                    idempotency_key TEXT NOT NULL UNIQUE CHECK(length(idempotency_key) = 64),
                    state TEXT NOT NULL CHECK(state IN ('queued', 'awaitingApproval', 'running', 'succeeded', 'failed', 'cancelled', 'stale')),
                    snapshot_catalog_revision INTEGER NOT NULL CHECK(snapshot_catalog_revision >= 0),
                    plan_json TEXT NOT NULL CHECK(json_valid(plan_json)),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                CREATE INDEX workflow_runs_definition_created_index ON workflow_runs(definition_id, created_at_ms DESC);
                CREATE TABLE workflow_step_runs (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    workflow_run_id TEXT NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
                    sequence INTEGER NOT NULL CHECK(sequence > 0),
                    action_json TEXT NOT NULL CHECK(json_valid(action_json)),
                    target_asset_ids_json TEXT NOT NULL CHECK(json_valid(target_asset_ids_json)),
                    state TEXT NOT NULL CHECK(state IN ('queued', 'awaitingApproval', 'running', 'succeeded', 'failed', 'cancelled', 'stale')),
                    UNIQUE(workflow_run_id, sequence)
                );
                CREATE TABLE workflow_proposals (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    workflow_run_id TEXT NOT NULL UNIQUE REFERENCES workflow_runs(id) ON DELETE CASCADE,
                    plan_json TEXT NOT NULL CHECK(json_valid(plan_json)),
                    state TEXT NOT NULL CHECK(state IN ('draft', 'awaitingApproval', 'approved', 'rejected', 'stale')),
                    created_at_ms INTEGER NOT NULL
                );
                CREATE TABLE workflow_audit_events (
                    id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
                    workflow_run_id TEXT NOT NULL REFERENCES workflow_runs(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK(kind IN ('planCreated', 'proposalCreated', 'approvalGranted', 'approvalRejected', 'executionStarted', 'executionSucceeded', 'executionFailed', 'runCancelled', 'snapshotMarkedStale')),
                    actor TEXT NOT NULL CHECK(actor IN ('human', 'workflow', 'agent', 'system')),
                    summary TEXT NOT NULL CHECK(length(summary) BETWEEN 1 AND 512),
                    captured_at_ms INTEGER NOT NULL
                );
                CREATE INDEX workflow_audit_events_run_captured_index ON workflow_audit_events(workflow_run_id, captured_at_ms ASC, id ASC);
                """)
            try db.execute(sql: "UPDATE catalog_settings SET value = '10', updated_at_ms = ? WHERE key = 'schema_version'", arguments: [CatalogDate.milliseconds(Date())])
        }
        return migrator
    }

    /// A short-lived compatibility bridge for catalogs created by the
    /// pre-cloud organization prototype. Those catalogs recorded their own
    /// `v3_tags`, `v5_saved_searches`, and `v6_local_trash` migrations, but
    /// their tables do not have the Phase 4 shape. Recreating the Phase 4
    /// tables blindly caused launch to fail before GRDB could record v4.
    private static func applyOrganizationSchemaMigration(in db: Database) throws {
        if try tableExists("tags", in: db) {
            try migrateLegacyTags(in: db)
        } else {
            try db.execute(sql: Self.tagSchemaSQL)
            try db.execute(sql: Self.tagIndexSQL)
        }

        if try tableExists("saved_searches", in: db) {
            try migrateLegacySavedSearches(in: db)
        } else {
            try db.execute(sql: Self.savedSearchSchemaSQL)
            try db.execute(sql: Self.savedSearchIndexSQL)
        }

        if try tableExists("asset_trash", in: db) {
            try migrateLegacyTrash(in: db)
        } else {
            try db.execute(sql: Self.trashSchemaSQL)
            try db.execute(sql: Self.trashIndexSQL)
        }

        try db.execute(sql: Self.receiptSchemaSQL)
    }

    private static func migrateLegacyTags(in db: Database) throws {
        let columns = try tableColumns("tags", in: db)
        let expected = Set(["id", "namespace", "value", "name", "created_at_ms", "updated_at_ms"])
        guard !expected.isSubset(of: columns) else { return }
        guard try tableExists("asset_tags", in: db) else {
            throw CatalogError.invalidPersistedValue("legacy_tag_schema")
        }

        let legacyTags = try Row.fetchAll(
            db,
            sql: "SELECT id, name, created_at_ms, updated_at_ms FROM tags ORDER BY sort_order, id"
        )
        let legacyMemberships = try Row.fetchAll(
            db,
            sql: "SELECT asset_id, tag_id, added_at_ms FROM asset_tags ORDER BY asset_id, tag_id"
        )

        try db.execute(sql: Self.legacyTagSchemaSQL)
        var allocatedNames = Set<String>()
        for row in legacyTags {
            let id: String = row["id"]
            let originalName: String = row["name"]
            let name = try migratedTagName(originalName, id: id, allocatedNames: &allocatedNames)
            try db.execute(
                sql: """
                    INSERT INTO tags_v4
                        (id, namespace, value, name, legacy_original_name, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id,
                    name.namespace,
                    name.value,
                    name.rawValue,
                    originalName,
                    row["created_at_ms"] as Int64,
                    row["updated_at_ms"] as Int64
                ]
            )
        }
        for row in legacyMemberships {
            try db.execute(
                sql: "INSERT INTO asset_tags_v4 (asset_id, tag_id, added_at_ms) VALUES (?, ?, ?)",
                arguments: [row["asset_id"] as String, row["tag_id"] as String, row["added_at_ms"] as Int64]
            )
        }

        try db.execute(sql: "DROP TABLE asset_tags")
        try db.execute(sql: "DROP TABLE tags")
        try db.execute(sql: "ALTER TABLE tags_v4 RENAME TO tags")
        try db.execute(sql: """
            CREATE TABLE asset_tags (
                asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                added_at_ms INTEGER NOT NULL,
                PRIMARY KEY(asset_id, tag_id)
            );
            INSERT INTO asset_tags (asset_id, tag_id, added_at_ms)
            SELECT asset_id, tag_id, added_at_ms FROM asset_tags_v4;
            DROP TABLE asset_tags_v4;
            """)
        try db.execute(sql: Self.tagIndexSQL)
    }

    private static func migrateLegacySavedSearches(in db: Database) throws {
        let columns = try tableColumns("saved_searches", in: db)
        let expected = Set(["id", "name", "filter_json", "sort_json", "created_at_ms", "updated_at_ms"])
        guard !expected.isSubset(of: columns) else { return }
        guard Set(["id", "name", "query_json", "created_at_ms", "updated_at_ms", "sort_order"]).isSubset(of: columns) else {
            throw CatalogError.invalidPersistedValue("legacy_saved_search_schema")
        }

        let legacySearches = try Row.fetchAll(
            db,
            sql: "SELECT id, name, query_json, created_at_ms, updated_at_ms FROM saved_searches ORDER BY sort_order, id"
        )
        try db.execute(sql: Self.legacySavedSearchSchemaSQL)
        let encoder = JSONEncoder()
        let defaultSortJSON = try jsonString(encoder.encode(AssetSort.defaultSort))
        for row in legacySearches {
            let name: String = row["name"]
            let queryJSON: String = row["query_json"]
            let filter = legacyFilter(from: queryJSON) ?? AssetFilter()
            let filterJSON = try jsonString(encoder.encode(filter))
            let normalizedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard !normalizedName.isEmpty else {
                throw CatalogError.invalidPersistedValue("legacy_saved_search_name")
            }
            try db.execute(
                sql: """
                    INSERT INTO saved_searches_v4
                        (id, name, filter_json, sort_json, legacy_query_json, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    row["id"] as String,
                    normalizedName,
                    filterJSON,
                    defaultSortJSON,
                    queryJSON,
                    row["created_at_ms"] as Int64,
                    row["updated_at_ms"] as Int64
                ]
            )
        }
        try db.execute(sql: "DROP TABLE saved_searches")
        try db.execute(sql: "ALTER TABLE saved_searches_v4 RENAME TO saved_searches")
        try db.execute(sql: Self.savedSearchIndexSQL)
    }

    private static func migrateLegacyTrash(in db: Database) throws {
        let columns = try tableColumns("asset_trash", in: db)
        let expected = Set(["asset_id", "prior_folder_id", "prior_album_ids_json", "prior_tag_ids_json", "trashed_at_ms", "scheduled_purge_at_ms"])
        guard !expected.isSubset(of: columns) else { return }
        guard Set(["asset_id", "prior_folder_id", "trashed_at_ms", "expires_at_ms"]).isSubset(of: columns) else {
            throw CatalogError.invalidPersistedValue("legacy_trash_schema")
        }

        let legacyReceipts = try Row.fetchAll(
            db,
            sql: "SELECT asset_id, prior_folder_id, trashed_at_ms, expires_at_ms FROM asset_trash ORDER BY asset_id"
        )
        var membershipsByAsset: [String: (albums: String, tags: String)] = [:]
        for row in legacyReceipts {
            let assetID: String = row["asset_id"]
            let albums = try String.fetchAll(
                db,
                sql: "SELECT album_id FROM album_assets WHERE asset_id = ? ORDER BY album_id",
                arguments: [assetID]
            )
            let tags = try String.fetchAll(
                db,
                sql: "SELECT tag_id FROM asset_tags WHERE asset_id = ? ORDER BY tag_id",
                arguments: [assetID]
            )
            membershipsByAsset[assetID] = (try jsonString(JSONEncoder().encode(albums)), try jsonString(JSONEncoder().encode(tags)))
        }

        try db.execute(sql: Self.legacyTrashSchemaSQL)
        for row in legacyReceipts {
            let assetID: String = row["asset_id"]
            guard let memberships = membershipsByAsset[assetID] else {
                throw CatalogError.invalidPersistedValue("legacy_trash_membership")
            }
            try db.execute(
                sql: """
                    INSERT INTO asset_trash_v4
                        (asset_id, prior_folder_id, prior_album_ids_json, prior_tag_ids_json, trashed_at_ms, scheduled_purge_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    assetID,
                    row["prior_folder_id"] as String,
                    memberships.albums,
                    memberships.tags,
                    row["trashed_at_ms"] as Int64,
                    row["expires_at_ms"] as Int64
                ]
            )
        }
        try db.execute(sql: "DROP TABLE asset_trash")
        try db.execute(sql: "ALTER TABLE asset_trash_v4 RENAME TO asset_trash")
        try db.execute(sql: Self.trashIndexSQL)
        for row in legacyReceipts {
            let assetID: String = row["asset_id"]
            try db.execute(sql: "DELETE FROM album_assets WHERE asset_id = ?", arguments: [assetID])
            try db.execute(sql: "DELETE FROM asset_tags WHERE asset_id = ?", arguments: [assetID])
        }
    }

    private static func tableExists(_ table: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) ?? false
    }

    private static func tableColumns(_ table: String, in db: Database) throws -> Set<String> {
        let allowed = Set(["tags", "saved_searches", "asset_trash"])
        guard allowed.contains(table) else { throw CatalogError.invalidPersistedValue("table_name") }
        return Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { ($0["name"] as String) })
    }

    private static func migratedTagName(_ originalName: String, id: String, allocatedNames: inout Set<String>) throws -> TagName {
        if let name = try? TagName(originalName), allocatedNames.insert(name.rawValue).inserted {
            return name
        }

        let folded = originalName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let characters = folded.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 97...122: return Character(String(scalar))
            default: return "-"
            }
        }
        let slug = String(characters).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = String((slug.isEmpty ? "tag" : slug).prefix(54))
        let suffix = id.replacingOccurrences(of: "-", with: "").prefix(8)
        var value = base
        while true {
            let candidate = try TagName(namespace: "legacy", value: value)
            if allocatedNames.insert(candidate.rawValue).inserted { return candidate }
            value = String("\(base.prefix(55))\(base.isEmpty ? "" : "-")\(suffix)".prefix(64))
        }
    }

    private static func jsonString(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidPersistedValue("json_encoding")
        }
        return value
    }

    private static func legacyFilter(from json: String) -> AssetFilter? {
        guard let data = json.data(using: .utf8),
              let query = try? JSONDecoder().decode(LegacySavedSearchQuery.self, from: data),
              let criteria = query.criteria else { return nil }
        let dateRange = criteria.capturedDateRange.map { min($0.start, $0.end)...max($0.start, $0.end) }
        return AssetFilter(
            text: criteria.text,
            folderPath: criteria.folderPathText,
            tagIDs: criteria.tagIDs,
            albumIDs: criteria.albumIDs,
            dateRange: dateRange,
            rating: criteria.rating,
            favorite: criteria.favorite
        )
    }

    private struct LegacySavedSearchQuery: Decodable {
        let criteria: LegacySavedSearchCriteria?
    }

    private struct LegacySavedSearchCriteria: Decodable {
        let text: String?
        let folderPathText: String?
        let capturedDateRange: LegacyCapturedDateRange?
        let rating: AssetRating?
        let favorite: Bool?
        let tagIDs: Set<TagID>
        let albumIDs: Set<AlbumID>

        enum CodingKeys: String, CodingKey {
            case text, folderPathText, capturedDateRange, rating, favorite, tagIDs, albumIDs
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decodeIfPresent(String.self, forKey: .text)
            folderPathText = try values.decodeIfPresent(String.self, forKey: .folderPathText)
            capturedDateRange = try values.decodeIfPresent(LegacyCapturedDateRange.self, forKey: .capturedDateRange)
            rating = try values.decodeIfPresent(AssetRating.self, forKey: .rating)
            favorite = try values.decodeIfPresent(Bool.self, forKey: .favorite)
            tagIDs = try values.decodeIfPresent(Set<TagID>.self, forKey: .tagIDs) ?? []
            albumIDs = try values.decodeIfPresent(Set<AlbumID>.self, forKey: .albumIDs) ?? []
        }
    }

    private struct LegacyCapturedDateRange: Decodable {
        let start: Date
        let end: Date
    }

    private static let initialSchemaSQL = """
        CREATE TABLE folders (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 255
                    AND instr(name, '/') = 0 AND instr(name, char(0)) = 0),
            parent_folder_id TEXT REFERENCES folders(id) ON DELETE RESTRICT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            system_kind TEXT
                CHECK(system_kind IS NULL OR system_kind = 'inbox')
        );

        CREATE UNIQUE INDEX folders_sibling_name_unique
            ON folders(COALESCE(parent_folder_id, ''), name COLLATE NOCASE);
        CREATE UNIQUE INDEX folders_system_kind_unique
            ON folders(system_kind) WHERE system_kind IS NOT NULL;
        CREATE INDEX folders_parent_sort_index
            ON folders(parent_folder_id, sort_order, name COLLATE NOCASE, id);

        CREATE TABLE assets (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            filename TEXT NOT NULL
                CHECK(length(filename) BETWEEN 1 AND 1024 AND instr(filename, char(0)) = 0),
            display_name TEXT NOT NULL COLLATE NOCASE
                CHECK(display_name = trim(display_name) AND length(display_name) BETWEEN 1 AND 255
                    AND instr(display_name, char(0)) = 0),
            parent_folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE RESTRICT,
            storage_key TEXT NOT NULL UNIQUE
                CHECK(length(storage_key) > 0 AND substr(storage_key, 1, 1) != '/'
                    AND instr(storage_key, '..') = 0 AND instr(storage_key, char(0)) = 0),
            media_type TEXT NOT NULL CHECK(media_type = 'stillImage'),
            width INTEGER CHECK(width IS NULL OR width > 0),
            height INTEGER CHECK(height IS NULL OR height > 0),
            file_size INTEGER NOT NULL CHECK(file_size >= 0),
            created_at_ms INTEGER NOT NULL,
            modified_at_ms INTEGER NOT NULL,
            imported_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0, 1)),
            rating INTEGER NOT NULL DEFAULT 0 CHECK(rating BETWEEN 0 AND 5),
            metadata_json TEXT NOT NULL CHECK(json_valid(metadata_json)),
            original_available INTEGER NOT NULL DEFAULT 1 CHECK(original_available IN (0, 1))
        );

        CREATE INDEX assets_folder_display_name_index
            ON assets(parent_folder_id, display_name COLLATE NOCASE, id);
        CREATE INDEX assets_folder_imported_at_index
            ON assets(parent_folder_id, imported_at_ms, id);
        CREATE INDEX assets_folder_modified_at_index
            ON assets(parent_folder_id, modified_at_ms, id);
        CREATE INDEX assets_folder_created_at_index
            ON assets(parent_folder_id, created_at_ms, id);
        CREATE INDEX assets_folder_file_size_index
            ON assets(parent_folder_id, file_size, id);
        CREATE INDEX assets_folder_rating_index
            ON assets(parent_folder_id, rating, id);
        CREATE INDEX assets_display_name_index ON assets(display_name COLLATE NOCASE, id);
        CREATE INDEX assets_imported_at_index ON assets(imported_at_ms, id);
        CREATE INDEX assets_modified_at_index ON assets(modified_at_ms, id);
        CREATE INDEX assets_created_at_index ON assets(created_at_ms, id);
        CREATE INDEX assets_file_size_index ON assets(file_size, id);
        CREATE INDEX assets_rating_index ON assets(rating, id);
        CREATE INDEX assets_favorite_imported_at_index
            ON assets(favorite, imported_at_ms, id);

        CREATE TABLE albums (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 255
                    AND instr(name, '/') = 0 AND instr(name, char(0)) = 0),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX albums_name_unique ON albums(name COLLATE NOCASE);
        CREATE INDEX albums_sort_index ON albums(sort_order, name COLLATE NOCASE, id);

        CREATE TABLE album_assets (
            album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            added_at_ms INTEGER NOT NULL,
            sort_order INTEGER NOT NULL,
            PRIMARY KEY(album_id, asset_id)
        );
        CREATE INDEX album_assets_album_sort_index
            ON album_assets(album_id, sort_order, asset_id);
        CREATE INDEX album_assets_asset_index ON album_assets(asset_id, album_id);

        CREATE TABLE catalog_settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        """

    private static let cloudSchemaSQL = """
        CREATE TABLE cloud_blobs (
            sha256 TEXT PRIMARY KEY NOT NULL
                CHECK(sha256 = lower(sha256) AND length(sha256) = 64),
            byte_size INTEGER NOT NULL CHECK(byte_size > 0),
            media_type TEXT NOT NULL CHECK(length(media_type) BETWEEN 3 AND 127),
            original_extension TEXT NOT NULL CHECK(length(original_extension) BETWEEN 1 AND 10),
            remote_blob_id TEXT,
            verification_state TEXT NOT NULL
                CHECK(verification_state IN ('pendingHash', 'pendingUpload', 'uploading', 'verified', 'failed', 'abandoned')),
            last_error TEXT,
            verified_at_ms INTEGER,
            updated_at_ms INTEGER NOT NULL
        );

        CREATE TABLE asset_cloud_state (
            asset_id TEXT PRIMARY KEY NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            blob_sha256 TEXT NOT NULL REFERENCES cloud_blobs(sha256) ON DELETE RESTRICT,
            remote_revision INTEGER,
            materialization_state TEXT NOT NULL
                CHECK(materialization_state IN ('localVerified', 'remoteVerified', 'remoteOnly', 'materializing', 'unavailable')),
            last_error TEXT,
            updated_at_ms INTEGER NOT NULL
        );
        CREATE INDEX asset_cloud_state_blob_index ON asset_cloud_state(blob_sha256);

        CREATE TABLE migration_manifest (
            asset_id TEXT PRIMARY KEY NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            storage_key TEXT NOT NULL,
            byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
            source_modified_at_ms INTEGER NOT NULL,
            sha256 TEXT,
            captured_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );

        CREATE TABLE sync_outbox (
            id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
            idempotency_key TEXT NOT NULL UNIQUE,
            operation TEXT NOT NULL,
            payload BLOB NOT NULL,
            state TEXT NOT NULL
                CHECK(state IN ('pending', 'inFlight', 'applied', 'conflict', 'failed', 'cancelled')),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
            next_attempt_at_ms INTEGER NOT NULL,
            last_error TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        CREATE INDEX sync_outbox_due_index ON sync_outbox(state, next_attempt_at_ms, created_at_ms);

        CREATE TABLE sync_conflicts (
            id TEXT PRIMARY KEY NOT NULL CHECK(id = lower(id) AND length(id) = 36),
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            local_payload BLOB NOT NULL,
            remote_payload BLOB NOT NULL,
            detected_at_ms INTEGER NOT NULL,
            resolution TEXT NOT NULL CHECK(resolution IN ('unresolved', 'keptLocal', 'keptRemote', 'merged')),
            updated_at_ms INTEGER NOT NULL
        );
        CREATE INDEX sync_conflicts_unresolved_index ON sync_conflicts(resolution, detected_at_ms);

        CREATE TABLE sync_state (
            key TEXT PRIMARY KEY NOT NULL CHECK(key = 'library'),
            mode TEXT NOT NULL CHECK(mode IN ('localOnly', 'preparingMigration', 'syncing', 'cloudBacked', 'paused', 'failed')),
            device_id TEXT,
            change_cursor INTEGER NOT NULL DEFAULT 0 CHECK(change_cursor >= 0),
            last_successful_sync_at_ms INTEGER,
            last_error TEXT,
            updated_at_ms INTEGER NOT NULL
        );
        INSERT INTO sync_state (key, mode, change_cursor, updated_at_ms)
            VALUES ('library', 'localOnly', 0, CAST(unixepoch('subsec') * 1000 AS INTEGER));
        """

    private static let tagSchemaSQL = """
        CREATE TABLE tags (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            namespace TEXT NOT NULL
                CHECK(namespace = lower(namespace) AND length(namespace) BETWEEN 1 AND 64),
            value TEXT NOT NULL
                CHECK(value = lower(value) AND length(value) BETWEEN 1 AND 64),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = lower(name) AND name = namespace || ':' || value),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            UNIQUE(name COLLATE NOCASE)
        );

        CREATE TABLE asset_tags (
            asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            added_at_ms INTEGER NOT NULL,
            PRIMARY KEY(asset_id, tag_id)
        );
        """

    private static let tagIndexSQL = """
        CREATE INDEX tags_namespace_value_index ON tags(namespace, value, id);
        CREATE INDEX asset_tags_tag_asset_index ON asset_tags(tag_id, asset_id);
        """

    private static let legacyTagSchemaSQL = """
        CREATE TABLE tags_v4 (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            namespace TEXT NOT NULL
                CHECK(namespace = lower(namespace) AND length(namespace) BETWEEN 1 AND 64),
            value TEXT NOT NULL
                CHECK(value = lower(value) AND length(value) BETWEEN 1 AND 64),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = lower(name) AND name = namespace || ':' || value),
            legacy_original_name TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            UNIQUE(name COLLATE NOCASE)
        );
        CREATE TABLE asset_tags_v4 (
            asset_id TEXT NOT NULL,
            tag_id TEXT NOT NULL,
            added_at_ms INTEGER NOT NULL,
            PRIMARY KEY(asset_id, tag_id)
        );
        """

    private static let savedSearchSchemaSQL = """
        CREATE TABLE saved_searches (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 120),
            filter_json TEXT NOT NULL CHECK(json_valid(filter_json)),
            sort_json TEXT NOT NULL CHECK(json_valid(sort_json)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            UNIQUE(name COLLATE NOCASE)
        );
        """

    private static let savedSearchIndexSQL = """
        CREATE INDEX saved_searches_name_index ON saved_searches(name COLLATE NOCASE, id);
        """

    private static let legacySavedSearchSchemaSQL = """
        CREATE TABLE saved_searches_v4 (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            name TEXT NOT NULL COLLATE NOCASE
                CHECK(name = trim(name) AND length(name) BETWEEN 1 AND 120),
            filter_json TEXT NOT NULL CHECK(json_valid(filter_json)),
            sort_json TEXT NOT NULL CHECK(json_valid(sort_json)),
            legacy_query_json TEXT NOT NULL CHECK(json_valid(legacy_query_json)),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            UNIQUE(name COLLATE NOCASE)
        );
        """

    private static let trashSchemaSQL = """
        CREATE TABLE asset_trash (
            asset_id TEXT PRIMARY KEY NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            prior_folder_id TEXT NOT NULL,
            prior_album_ids_json TEXT NOT NULL CHECK(json_valid(prior_album_ids_json)),
            prior_tag_ids_json TEXT NOT NULL CHECK(json_valid(prior_tag_ids_json)),
            trashed_at_ms INTEGER NOT NULL,
            scheduled_purge_at_ms INTEGER NOT NULL CHECK(scheduled_purge_at_ms >= trashed_at_ms)
        );
        """

    private static let trashIndexSQL = """
        CREATE INDEX asset_trash_retention_index ON asset_trash(scheduled_purge_at_ms, trashed_at_ms);
        """

    private static let legacyTrashSchemaSQL = """
        CREATE TABLE asset_trash_v4 (
            asset_id TEXT PRIMARY KEY NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            prior_folder_id TEXT NOT NULL,
            prior_album_ids_json TEXT NOT NULL CHECK(json_valid(prior_album_ids_json)),
            prior_tag_ids_json TEXT NOT NULL CHECK(json_valid(prior_tag_ids_json)),
            trashed_at_ms INTEGER NOT NULL,
            scheduled_purge_at_ms INTEGER NOT NULL CHECK(scheduled_purge_at_ms >= trashed_at_ms)
        );
        """

    private static let receiptSchemaSQL = """
        CREATE TABLE export_receipts (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            manifest_sha256 TEXT NOT NULL
                CHECK(manifest_sha256 = lower(manifest_sha256) AND length(manifest_sha256) = 64),
            asset_ids_json TEXT NOT NULL CHECK(json_valid(asset_ids_json)),
            completed_at_ms INTEGER NOT NULL
        );
        CREATE INDEX export_receipts_completed_index ON export_receipts(completed_at_ms);

        CREATE TABLE backup_manifests (
            id TEXT PRIMARY KEY NOT NULL
                CHECK(id = lower(id) AND length(id) = 36),
            manifest_sha256 TEXT NOT NULL
                CHECK(manifest_sha256 = lower(manifest_sha256) AND length(manifest_sha256) = 64),
            recorded_at_ms INTEGER NOT NULL,
            last_restore_drill_at_ms INTEGER,
            last_restore_drill_result TEXT
        );
        """
}

enum CatalogDate {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

enum CatalogValidation {
    static func normalizedName(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 255,
              !normalized.contains("/"),
              !normalized.contains("\0") else {
            throw CatalogError.invalidAssetDisplayName
        }
        return normalized
    }
}

enum CatalogSortOrder {
    static let gap: Int64 = 1_024

    static func next(
        in db: Database,
        table: String,
        predicateSQL: String,
        arguments: StatementArguments
    ) throws -> Int64 {
        let current: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sort_order), 0) FROM \(table) WHERE \(predicateSQL)",
            arguments: arguments
        ) ?? 0
        guard current > Int64.max - gap else { return current + gap }

        // This is intentionally rare. Gap order is preserved for normal
        // mutations and compacted only when the integer range is exhausted.
        let rowIDs = try Int64.fetchAll(
            db,
            sql: "SELECT rowid FROM \(table) WHERE \(predicateSQL) ORDER BY sort_order, rowid",
            arguments: arguments
        )
        for (index, rowID) in rowIDs.enumerated() {
            let normalized = Int64(index + 1) * gap
            try db.execute(
                sql: "UPDATE \(table) SET sort_order = ? WHERE rowid = ?",
                arguments: [normalized, rowID]
            )
        }
        guard rowIDs.count < Int(Int64.max / gap) else {
            throw CatalogError.invalidPersistedValue("sort_order")
        }
        return Int64(rowIDs.count + 1) * gap
    }
}
