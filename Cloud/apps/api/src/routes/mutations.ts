import { Hono } from 'hono';
import { apiError, fingerprint } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const mutationsRouter = new Hono<AppEnv>();

type MutationOperationType =
  | 'create_folder'
  | 'create_album'
  | 'add_assets_to_album'
  | 'rename_folder'
  | 'move_folder'
  | 'create_asset'
  | 'move_asset'
  | 'move_assets'
  | 'update_rating'
  | 'update_favorite'
  | 'create_tag'
  | 'rename_tag'
  | 'delete_tag'
  | 'add_tag_to_assets'
  | 'remove_tag_from_assets'
  | 'create_saved_search'
  | 'update_saved_search'
  | 'delete_saved_search'
  | 'record_export_receipt'
  | 'record_backup_manifest'
  | 'record_backup_restore_drill'
  | 'rename_asset'
  | 'trash_asset'
  | 'restore_asset'
  | 'rename_album'
  | 'remove_assets_from_album'
  | 'reorder_album'
  | 'delete_album';

interface MutationOperation {
  type: MutationOperationType;
  targetId: string;
  baseRevision?: number;
  payload: Record<string, unknown>;
}

interface MutationRequest {
  clientMutationId?: string;
  operations?: MutationOperation[];
}

const REQUIRED_SCOPE_BY_OPERATION: Record<MutationOperationType, string> = {
  create_folder: 'assets.organize',
  create_album: 'assets.organize',
  add_assets_to_album: 'assets.organize',
  rename_folder: 'assets.organize',
  move_folder: 'assets.organize',
  create_asset: 'assets.import',
  move_asset: 'assets.organize',
  move_assets: 'assets.organize',
  update_rating: 'assets.metadata.write',
  update_favorite: 'assets.metadata.write',
  create_tag: 'assets.metadata.write',
  rename_tag: 'assets.metadata.write',
  delete_tag: 'assets.metadata.write',
  add_tag_to_assets: 'assets.metadata.write',
  remove_tag_from_assets: 'assets.metadata.write',
  create_saved_search: 'library.preferences.write',
  update_saved_search: 'library.preferences.write',
  delete_saved_search: 'library.preferences.write',
  record_export_receipt: 'library.preferences.write',
  record_backup_manifest: 'library.preferences.write',
  record_backup_restore_drill: 'library.preferences.write',
  rename_asset: 'assets.metadata.write',
  trash_asset: 'trash.write',
  restore_asset: 'trash.write',
  rename_album: 'assets.organize',
  remove_assets_from_album: 'assets.organize',
  reorder_album: 'assets.organize',
  delete_album: 'assets.organize'
};
const ID = /^[a-zA-Z0-9_-]{3,128}$/;

interface PreparedOperation {
  index: number;
  operation: MutationOperation;
  entityType: 'folder' | 'asset' | 'album' | 'tag' | 'saved_search' | 'export_receipt' | 'backup_manifest';
  revision: number;
  afterState: Record<string, unknown>;
  guardSql: string;
  guardParams: unknown[];
  mutationStatements: Array<{ sql: string; params: unknown[] }>;
}

function validName(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= 160;
}

function validRevision(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

function validAssetMetadata(value: unknown): value is Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  try {
    const encoded = JSON.stringify(value);
    return encoded.length <= 32_000;
  } catch {
    return false;
  }
}

function validTagName(value: unknown): value is string {
  return typeof value === 'string' && /^[a-z][a-z0-9_-]{0,63}:[a-z0-9][a-z0-9._-]{0,127}$/.test(value);
}

function validJSONRecord(value: unknown): value is Record<string, unknown> {
  return validAssetMetadata(value);
}

async function prepareOperation(
  env: AppEnv['Bindings'],
  operation: MutationOperation,
  index: number,
  mutationId: string
): Promise<PreparedOperation | { code: string; message: string }> {
  if (!ID.test(operation.targetId)) return { code: 'INVALID_MUTATION', message: 'targetId is invalid' };
  const guardId = `${mutationId}:${index}`;

  if (operation.type === 'create_tag') {
    const name = operation.payload.name;
    if (!validTagName(name)) return { code: 'INVALID_MUTATION', message: 'Tag name must be lowercase namespace:value' };
    return {
      index, operation, entityType: 'tag', revision: 1,
      afterState: { id: operation.targetId, name, assetIds: [], revision: 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM tags WHERE id = ?)
          AND NOT EXISTS (SELECT 1 FROM tags WHERE name = ? COLLATE NOCASE) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, name],
      mutationStatements: [{ sql: 'INSERT INTO tags (id, name, revision) VALUES (?, ?, 1)', params: [operation.targetId, name] }]
    };
  }

  if (operation.type === 'rename_tag') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const name = operation.payload.name;
    if (!validTagName(name)) return { code: 'INVALID_MUTATION', message: 'Tag name must be lowercase namespace:value' };
    const tag = await env.DB.prepare('SELECT id, revision FROM tags WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; revision: number }>();
    if (!tag || tag.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Tag has changed' };
    const memberships = await env.DB.prepare('SELECT asset_id FROM asset_tags WHERE tag_id = ? ORDER BY asset_id').bind(tag.id).all<{ asset_id: string }>();
    return {
      index, operation, entityType: 'tag', revision: tag.revision + 1,
      afterState: { id: tag.id, name, assetIds: memberships.results.map((row) => row.asset_id), revision: tag.revision + 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM tags WHERE id = ? AND revision = ?)
          AND NOT EXISTS (SELECT 1 FROM tags WHERE name = ? COLLATE NOCASE AND id <> ?) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, tag.id, tag.revision, name, tag.id],
      mutationStatements: [{ sql: "UPDATE tags SET name = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [name, tag.id] }]
    };
  }

  if (operation.type === 'delete_tag') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const tag = await env.DB.prepare('SELECT id, revision FROM tags WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; revision: number }>();
    if (!tag || tag.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Tag has changed' };
    return {
      index, operation, entityType: 'tag', revision: tag.revision + 1,
      afterState: { id: tag.id, deleted: true, revision: tag.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM tags WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, tag.id, tag.revision],
      mutationStatements: [{ sql: 'DELETE FROM tags WHERE id = ?', params: [tag.id] }]
    };
  }

  if (operation.type === 'add_tag_to_assets' || operation.type === 'remove_tag_from_assets') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const rawAssetIDs = operation.payload.assetIds;
    if (!Array.isArray(rawAssetIDs) || rawAssetIDs.length === 0 || rawAssetIDs.length > 500 || rawAssetIDs.some((id) => !ID.test(String(id)))) {
      return { code: 'INVALID_MUTATION', message: 'assetIds must contain between one and five hundred valid asset IDs' };
    }
    const assetIDs = [...new Set(rawAssetIDs.map(String))].sort();
    const tag = await env.DB.prepare('SELECT id, name, revision FROM tags WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; name: string; revision: number }>();
    if (!tag || tag.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Tag has changed' };
    const existing = await env.DB.prepare('SELECT asset_id FROM asset_tags WHERE tag_id = ? ORDER BY asset_id').bind(tag.id).all<{ asset_id: string }>();
    const existingIDs = existing.results.map((row) => row.asset_id);
    const nextAssetIDs = operation.type === 'add_tag_to_assets'
      ? [...new Set([...existingIDs, ...assetIDs])].sort()
      : existingIDs.filter((assetID) => !assetIDs.includes(assetID));
    const encodedAssetIDs = JSON.stringify(assetIDs);
    const membershipStatement = operation.type === 'add_tag_to_assets'
      ? { sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) SELECT value, ? FROM json_each(?)", params: [tag.id, encodedAssetIDs] }
      : { sql: "DELETE FROM asset_tags WHERE tag_id = ? AND asset_id IN (SELECT value FROM json_each(?))", params: [tag.id, encodedAssetIDs] };
    return {
      index, operation, entityType: 'tag', revision: tag.revision + 1,
      afterState: { id: tag.id, name: tag.name, assetIds: nextAssetIDs, revision: tag.revision + 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM tags WHERE id = ? AND revision = ?)
          AND (SELECT COUNT(*) FROM assets WHERE id IN (SELECT value FROM json_each(?))) = ? THEN 1 ELSE 0 END)`,
      guardParams: [guardId, tag.id, tag.revision, encodedAssetIDs, assetIDs.length],
      mutationStatements: [
        { sql: "UPDATE tags SET revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [tag.id] },
        membershipStatement
      ]
    };
  }

  if (operation.type === 'create_saved_search') {
    const name = operation.payload.name;
    const rules = operation.payload.rules;
    const sort = operation.payload.sort;
    if (!validName(name) || !validJSONRecord(rules) || !validJSONRecord(sort)) {
      return { code: 'INVALID_MUTATION', message: 'Saved search name, rules, or sort is invalid' };
    }
    return {
      index, operation, entityType: 'saved_search', revision: 1,
      afterState: { id: operation.targetId, name: name.trim(), rules, sort, revision: 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM saved_searches WHERE id = ?)
          AND NOT EXISTS (SELECT 1 FROM saved_searches WHERE name = ? COLLATE NOCASE) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, name.trim()],
      mutationStatements: [{ sql: 'INSERT INTO saved_searches (id, name, rules_json, sort_json, revision) VALUES (?, ?, ?, ?, 1)', params: [operation.targetId, name.trim(), JSON.stringify(rules), JSON.stringify(sort)] }]
    };
  }

  if (operation.type === 'update_saved_search') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const name = operation.payload.name;
    const rules = operation.payload.rules;
    const sort = operation.payload.sort;
    if (!validName(name) || !validJSONRecord(rules) || !validJSONRecord(sort)) {
      return { code: 'INVALID_MUTATION', message: 'Saved search name, rules, or sort is invalid' };
    }
    const savedSearch = await env.DB.prepare('SELECT id, revision FROM saved_searches WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; revision: number }>();
    if (!savedSearch || savedSearch.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Saved search has changed' };
    return {
      index, operation, entityType: 'saved_search', revision: savedSearch.revision + 1,
      afterState: { id: savedSearch.id, name: name.trim(), rules, sort, revision: savedSearch.revision + 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM saved_searches WHERE id = ? AND revision = ?)
          AND NOT EXISTS (SELECT 1 FROM saved_searches WHERE name = ? COLLATE NOCASE AND id <> ?) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, savedSearch.id, savedSearch.revision, name.trim(), savedSearch.id],
      mutationStatements: [{ sql: "UPDATE saved_searches SET name = ?, rules_json = ?, sort_json = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [name.trim(), JSON.stringify(rules), JSON.stringify(sort), savedSearch.id] }]
    };
  }

  if (operation.type === 'delete_saved_search') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const savedSearch = await env.DB.prepare('SELECT id, revision FROM saved_searches WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; revision: number }>();
    if (!savedSearch || savedSearch.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Saved search has changed' };
    return {
      index, operation, entityType: 'saved_search', revision: savedSearch.revision + 1,
      afterState: { id: savedSearch.id, deleted: true, revision: savedSearch.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM saved_searches WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, savedSearch.id, savedSearch.revision],
      mutationStatements: [{ sql: 'DELETE FROM saved_searches WHERE id = ?', params: [savedSearch.id] }]
    };
  }

  if (operation.type === 'record_export_receipt') {
    const manifestSHA256 = operation.payload.manifestSHA256;
    const rawAssetIDs = operation.payload.assetIds;
    if (typeof manifestSHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(manifestSHA256)
      || !Array.isArray(rawAssetIDs) || rawAssetIDs.length > 500
      || rawAssetIDs.some((id) => !ID.test(String(id)))) {
      return { code: 'INVALID_MUTATION', message: 'Export receipt manifest or asset IDs are invalid' };
    }
    const assetIDs = [...new Set(rawAssetIDs.map(String))].sort();
    const completedAt = new Date().toISOString();
    return {
      index, operation, entityType: 'export_receipt', revision: 1,
      afterState: { id: operation.targetId, manifestSHA256, assetIds: assetIDs, completedAt, revision: 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM export_receipts WHERE id = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, operation.targetId],
      mutationStatements: [{
        sql: 'INSERT INTO export_receipts (id, manifest_sha256, asset_ids_json, completed_at, revision) VALUES (?, ?, ?, ?, 1)',
        params: [operation.targetId, manifestSHA256, JSON.stringify(assetIDs), completedAt]
      }]
    };
  }

  if (operation.type === 'record_backup_manifest') {
    const manifestSHA256 = operation.payload.manifestSHA256;
    if (typeof manifestSHA256 !== 'string' || !/^[a-f0-9]{64}$/.test(manifestSHA256)) {
      return { code: 'INVALID_MUTATION', message: 'Backup manifest hash is invalid' };
    }
    const recordedAt = new Date().toISOString();
    return {
      index, operation, entityType: 'backup_manifest', revision: 1,
      afterState: { id: operation.targetId, manifestSHA256, recordedAt, lastRestoreDrillAt: null, lastRestoreDrillResult: null, revision: 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM backup_manifests WHERE id = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, operation.targetId],
      mutationStatements: [{
        sql: 'INSERT INTO backup_manifests (id, manifest_sha256, recorded_at, revision) VALUES (?, ?, ?, 1)',
        params: [operation.targetId, manifestSHA256, recordedAt]
      }]
    };
  }

  if (operation.type === 'record_backup_restore_drill') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for a backup manifest' };
    const result = operation.payload.result;
    if (typeof result !== 'string' || result.trim().length === 0 || result.trim().length > 240) {
      return { code: 'INVALID_MUTATION', message: 'Backup restore-drill result is invalid' };
    }
    const manifest = await env.DB.prepare('SELECT id, manifest_sha256, recorded_at, revision FROM backup_manifests WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; manifest_sha256: string; recorded_at: string; revision: number }>();
    if (!manifest || manifest.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Backup manifest has changed' };
    const lastRestoreDrillAt = new Date().toISOString();
    return {
      index, operation, entityType: 'backup_manifest', revision: manifest.revision + 1,
      afterState: { id: manifest.id, manifestSHA256: manifest.manifest_sha256, recordedAt: manifest.recorded_at, lastRestoreDrillAt, lastRestoreDrillResult: result.trim(), revision: manifest.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM backup_manifests WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, manifest.id, manifest.revision],
      mutationStatements: [{
        sql: "UPDATE backup_manifests SET last_restore_drill_at = ?, last_restore_drill_result = ?, revision = revision + 1 WHERE id = ?",
        params: [lastRestoreDrillAt, result.trim(), manifest.id]
      }]
    };
  }

  if (operation.type === 'rename_album') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const name = operation.payload.name;
    if (!validName(name)) return { code: 'INVALID_MUTATION', message: 'Album name is invalid' };
    const album = await env.DB.prepare('SELECT id, sort_order, revision FROM albums WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; sort_order: number; revision: number }>();
    if (!album || album.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Album has changed' };
    const members = await env.DB.prepare('SELECT asset_id FROM album_assets WHERE album_id = ? ORDER BY sort_order, asset_id').bind(album.id).all<{ asset_id: string }>();
    return {
      index, operation, entityType: 'album', revision: album.revision + 1,
      afterState: { id: album.id, name: name.trim(), sortOrder: album.sort_order, assetIds: members.results.map((row) => row.asset_id), revision: album.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM albums WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, album.id, album.revision],
      mutationStatements: [{ sql: "UPDATE albums SET name = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [name.trim(), album.id] }]
    };
  }

  if (operation.type === 'remove_assets_from_album') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const rawAssetIDs = operation.payload.assetIds;
    if (!Array.isArray(rawAssetIDs) || rawAssetIDs.length === 0 || rawAssetIDs.length > 500 || rawAssetIDs.some((id) => !ID.test(String(id)))) {
      return { code: 'INVALID_MUTATION', message: 'assetIds must contain between one and five hundred valid asset IDs' };
    }
    const assetIDs = [...new Set(rawAssetIDs.map(String))].sort();
    const album = await env.DB.prepare('SELECT id, name, sort_order, revision FROM albums WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; name: string; sort_order: number; revision: number }>();
    if (!album || album.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Album has changed' };
    const existing = await env.DB.prepare('SELECT asset_id FROM album_assets WHERE album_id = ? ORDER BY sort_order, asset_id').bind(album.id).all<{ asset_id: string }>();
    const nextAssetIDs = existing.results.map((row) => row.asset_id).filter((assetID) => !assetIDs.includes(assetID));
    const encodedAssetIDs = JSON.stringify(assetIDs);
    return {
      index, operation, entityType: 'album', revision: album.revision + 1,
      afterState: { id: album.id, name: album.name, sortOrder: album.sort_order, assetIds: nextAssetIDs, revision: album.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM albums WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, album.id, album.revision],
      mutationStatements: [
        { sql: "UPDATE albums SET revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [album.id] },
        { sql: 'DELETE FROM album_assets WHERE album_id = ? AND asset_id IN (SELECT value FROM json_each(?))', params: [album.id, encodedAssetIDs] }
      ]
    };
  }

  if (operation.type === 'reorder_album') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const predecessorID = operation.payload.predecessorId;
    if (predecessorID !== null && predecessorID !== undefined && (!ID.test(String(predecessorID)) || String(predecessorID) === operation.targetId)) {
      return { code: 'INVALID_MUTATION', message: 'Album predecessor is invalid' };
    }
    const album = await env.DB.prepare('SELECT id, name, revision FROM albums WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; name: string; revision: number }>();
    if (!album || album.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Album has changed' };
    const predecessor = predecessorID ? await env.DB.prepare('SELECT sort_order FROM albums WHERE id = ?').bind(String(predecessorID)).first<{ sort_order: number }>() : null;
    if (predecessorID && !predecessor) return { code: 'INVALID_MUTATION', message: 'Album predecessor does not exist' };
    const firstSortOrder = (await env.DB.prepare('SELECT MIN(sort_order) AS sort_order FROM albums WHERE id <> ?').bind(album.id).first<{ sort_order: number | null }>())?.sort_order;
    const nextSortOrder = predecessor
      ? predecessor.sort_order + 1_024
      : (firstSortOrder ?? 0) - 1_024;
    const members = await env.DB.prepare('SELECT asset_id FROM album_assets WHERE album_id = ? ORDER BY sort_order, asset_id').bind(album.id).all<{ asset_id: string }>();
    return {
      index, operation, entityType: 'album', revision: album.revision + 1,
      afterState: { id: album.id, name: album.name, sortOrder: nextSortOrder, assetIds: members.results.map((row) => row.asset_id), revision: album.revision + 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM albums WHERE id = ? AND revision = ?)
          AND (? IS NULL OR EXISTS (SELECT 1 FROM albums WHERE id = ?)) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, album.id, album.revision, predecessorID ?? null, predecessorID ?? null],
      mutationStatements: [{ sql: "UPDATE albums SET sort_order = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [nextSortOrder, album.id] }]
    };
  }

  if (operation.type === 'delete_album') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const album = await env.DB.prepare('SELECT id, revision FROM albums WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; revision: number }>();
    if (!album || album.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Album has changed' };
    return {
      index, operation, entityType: 'album', revision: album.revision + 1,
      afterState: { id: album.id, deleted: true, revision: album.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM albums WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, album.id, album.revision],
      mutationStatements: [{ sql: 'DELETE FROM albums WHERE id = ?', params: [album.id] }]
    };
  }

  if (operation.type === 'create_folder') {
    const name = operation.payload.name;
    const parentId = operation.payload.parentId;
    if (!validName(name) || (parentId !== undefined && parentId !== null && (!ID.test(String(parentId)) || parentId === operation.targetId))) {
      return { code: 'INVALID_MUTATION', message: 'Folder name or parent is invalid' };
    }
    const parent = parentId ? String(parentId) : null;
    return {
      index, operation, entityType: 'folder', revision: 1,
      afterState: { id: operation.targetId, name: name.trim(), parentId: parent, revision: 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM folders WHERE id = ?)
          AND (? IS NULL OR EXISTS (SELECT 1 FROM folders WHERE id = ?)) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, parent, parent],
      mutationStatements: [{ sql: 'INSERT INTO folders (id, name, parent_id, revision) VALUES (?, ?, ?, 1)', params: [operation.targetId, name.trim(), parent] }]
    };
  }

  if (operation.type === 'create_album') {
    const name = operation.payload.name;
    if (!validName(name)) return { code: 'INVALID_MUTATION', message: 'Album name is invalid' };
    const lastSortOrder = await env.DB.prepare('SELECT MAX(sort_order) AS sort_order FROM albums').first<{ sort_order: number | null }>();
    const sortOrder = (lastSortOrder?.sort_order ?? 0) + 1_024;
    return {
      index, operation, entityType: 'album', revision: 1,
      afterState: { id: operation.targetId, name: name.trim(), sortOrder, assetIds: [], revision: 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM albums WHERE id = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, operation.targetId],
      mutationStatements: [{ sql: 'INSERT INTO albums (id, name, sort_order, revision) VALUES (?, ?, ?, 1)', params: [operation.targetId, name.trim(), sortOrder] }]
    };
  }

  if (operation.type === 'add_assets_to_album') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const rawAssetIDs = operation.payload.assetIds;
    if (!Array.isArray(rawAssetIDs) || rawAssetIDs.length === 0 || rawAssetIDs.length > 500 || rawAssetIDs.some((id) => !ID.test(String(id)))) {
      return { code: 'INVALID_MUTATION', message: 'assetIds must contain between one and five hundred valid asset IDs' };
    }
    const assetIDs = [...new Set(rawAssetIDs.map(String))].sort();
    const album = await env.DB.prepare('SELECT id, name, revision FROM albums WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; name: string; revision: number }>();
    if (!album || album.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Album has changed' };
    const existing = await env.DB.prepare('SELECT asset_id FROM album_assets WHERE album_id = ? ORDER BY asset_id').bind(operation.targetId)
      .all<{ asset_id: string }>();
    const nextAssetIDs = [...new Set([...existing.results.map((row) => row.asset_id), ...assetIDs])].sort();
    const encodedAssetIDs = JSON.stringify(assetIDs);
    return {
      index, operation, entityType: 'album', revision: album.revision + 1,
      afterState: { id: album.id, name: album.name, assetIds: nextAssetIDs, revision: album.revision + 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM albums WHERE id = ? AND revision = ?)
          AND (SELECT COUNT(*) FROM assets WHERE id IN (SELECT value FROM json_each(?))) = ? THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, operation.baseRevision, encodedAssetIDs, assetIDs.length],
      mutationStatements: [
        { sql: "UPDATE albums SET revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [operation.targetId] },
        { sql: "INSERT OR IGNORE INTO album_assets (album_id, asset_id) SELECT ?, value FROM json_each(?)", params: [operation.targetId, encodedAssetIDs] }
      ]
    };
  }

  if (operation.type === 'rename_folder') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const name = operation.payload.name;
    if (!validName(name)) return { code: 'INVALID_MUTATION', message: 'Folder name is invalid' };
    const folder = await env.DB.prepare('SELECT id, parent_id, revision FROM folders WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; parent_id: string | null; revision: number }>();
    if (!folder || folder.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Folder has changed' };
    return {
      index, operation, entityType: 'folder', revision: folder.revision + 1,
      afterState: { id: folder.id, name: name.trim(), parentId: folder.parent_id, revision: folder.revision + 1 },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM folders WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, operation.targetId, operation.baseRevision],
      mutationStatements: [{ sql: "UPDATE folders SET name = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [name.trim(), operation.targetId] }]
    };
  }

  if (operation.type === 'move_folder') {
    if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };
    const parentID = operation.payload.parentId;
    if (parentID !== null && parentID !== undefined && (!ID.test(String(parentID)) || String(parentID) === operation.targetId)) {
      return { code: 'INVALID_MUTATION', message: 'Folder parent is invalid' };
    }
    const parent = parentID === null || parentID === undefined ? null : String(parentID);
    const folder = await env.DB.prepare('SELECT id, name, revision FROM folders WHERE id = ?').bind(operation.targetId)
      .first<{ id: string; name: string; revision: number }>();
    if (!folder || folder.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Folder has changed' };
    if (parent) {
      const cycle = await env.DB.prepare(`WITH RECURSIVE ancestors(id) AS (
          SELECT parent_id FROM folders WHERE id = ?
          UNION ALL
          SELECT folders.parent_id FROM folders JOIN ancestors ON folders.id = ancestors.id WHERE ancestors.id IS NOT NULL
        ) SELECT EXISTS(SELECT 1 FROM ancestors WHERE id = ?) AS cycle`)
        .bind(parent, operation.targetId).first<{ cycle: number }>();
      if (cycle?.cycle) return { code: 'INVALID_MUTATION', message: 'Folder parent would create a cycle' };
    }
    return {
      index, operation, entityType: 'folder', revision: folder.revision + 1,
      afterState: { id: folder.id, name: folder.name, parentId: parent, revision: folder.revision + 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM folders WHERE id = ? AND revision = ?)
          AND (? IS NULL OR EXISTS (SELECT 1 FROM folders WHERE id = ?)) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, operation.baseRevision, parent, parent],
      mutationStatements: [{ sql: "UPDATE folders SET parent_id = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [parent, operation.targetId] }]
    };
  }

  if (operation.type === 'create_asset') {
    const blobId = operation.payload.blobId;
    const folderId = operation.payload.folderId;
    const displayName = operation.payload.displayName;
    const assetMetadata = operation.payload.assetMetadata;
    if (!ID.test(String(blobId)) || !ID.test(String(folderId)) || !validName(displayName) ||
        (assetMetadata !== undefined && !validAssetMetadata(assetMetadata))) {
      return { code: 'INVALID_MUTATION', message: 'Asset blob, folder, or display name is invalid' };
    }
    const metadata = assetMetadata ?? {};
    const blob = await env.DB.prepare(
      `SELECT sha256, byte_size, media_type, original_extension FROM blobs WHERE id = ? AND upload_state = 'verified'`
    ).bind(String(blobId)).first<{ sha256: string; byte_size: number; media_type: string; original_extension: string }>();
    if (!blob) return { code: 'INVALID_MUTATION', message: 'Asset blob is not verified' };
    return {
      index, operation, entityType: 'asset', revision: 1,
      afterState: {
        id: operation.targetId, blobId, folderId, displayName: displayName.trim(), favorite: false, rating: 0, revision: 1,
        assetMetadata: metadata,
        blob: { sha256: blob.sha256, byteSize: blob.byte_size, mediaType: blob.media_type, originalExtension: blob.original_extension }
      },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM assets WHERE id = ?)
          AND EXISTS (SELECT 1 FROM blobs WHERE id = ? AND upload_state = 'verified')
          AND EXISTS (SELECT 1 FROM folders WHERE id = ?) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, String(blobId), String(folderId)],
      mutationStatements: [{ sql: 'INSERT INTO assets (id, blob_id, display_name, folder_id, asset_metadata, revision) VALUES (?, ?, ?, ?, ?, 1)', params: [operation.targetId, String(blobId), displayName.trim(), String(folderId), JSON.stringify(metadata)] }]
    };
  }

  if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };

  const asset = await env.DB.prepare('SELECT id, blob_id, display_name, folder_id, favorite, rating, status, revision FROM assets WHERE id = ?')
    .bind(operation.targetId)
    .first<{ id: string; blob_id: string; display_name: string; folder_id: string; favorite: number; rating: number; status: string; revision: number }>();
  if (!asset || asset.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Asset has changed' };
  const nextRevision = asset.revision + 1;

  if (operation.type === 'rename_asset') {
    const displayName = operation.payload.displayName;
    if (!validName(displayName)) return { code: 'INVALID_MUTATION', message: 'Asset display name is invalid' };
    return {
      index, operation, entityType: 'asset', revision: nextRevision,
      afterState: { id: asset.id, blobId: asset.blob_id, displayName: displayName.trim(), folderId: asset.folder_id, favorite: Boolean(asset.favorite), rating: asset.rating, status: asset.status, revision: nextRevision },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM assets WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, asset.id, asset.revision],
      mutationStatements: [{ sql: "UPDATE assets SET display_name = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [displayName.trim(), asset.id] }]
    };
  }

  if (operation.type === 'trash_asset') {
    const retentionDays = operation.payload.retentionDays ?? 30;
    if (!Number.isInteger(retentionDays) || Number(retentionDays) < 1 || Number(retentionDays) > 3_650) {
      return { code: 'INVALID_MUTATION', message: 'retentionDays must be between one and 3650' };
    }
    if (asset.status !== 'active') return { code: 'STALE_REVISION', message: 'Asset is already in Trash' };
    const [albums, tags] = await Promise.all([
      env.DB.prepare('SELECT album_id FROM album_assets WHERE asset_id = ? ORDER BY album_id').bind(asset.id).all<{ album_id: string }>(),
      env.DB.prepare('SELECT tag_id FROM asset_tags WHERE asset_id = ? ORDER BY tag_id').bind(asset.id).all<{ tag_id: string }>()
    ]);
    const trashedAt = new Date().toISOString();
    const scheduledPurgeAt = new Date(Date.now() + Number(retentionDays) * 86_400_000).toISOString();
    return {
      index, operation, entityType: 'asset', revision: nextRevision,
      afterState: {
        id: asset.id, blobId: asset.blob_id, displayName: asset.display_name, folderId: asset.folder_id,
        favorite: Boolean(asset.favorite), rating: asset.rating, status: 'trashed', revision: nextRevision,
        trash: {
          priorFolderId: asset.folder_id,
          priorAlbumIds: albums.results.map((row) => row.album_id),
          priorTagIds: tags.results.map((row) => row.tag_id),
          trashedAt,
          scheduledPurgeAt
        }
      },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM assets WHERE id = ? AND revision = ? AND status = \'active\') THEN 1 ELSE 0 END)',
      guardParams: [guardId, asset.id, asset.revision],
      mutationStatements: [
        { sql: "UPDATE assets SET status = 'trashed', revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [asset.id] },
        { sql: 'INSERT INTO asset_trash (asset_id, prior_folder_id, prior_album_ids_json, prior_tag_ids_json, trashed_at, scheduled_purge_at) VALUES (?, ?, ?, ?, ?, ?)', params: [asset.id, asset.folder_id, JSON.stringify(albums.results.map((row) => row.album_id)), JSON.stringify(tags.results.map((row) => row.tag_id)), trashedAt, scheduledPurgeAt] },
        { sql: 'DELETE FROM album_assets WHERE asset_id = ?', params: [asset.id] },
        { sql: 'DELETE FROM asset_tags WHERE asset_id = ?', params: [asset.id] }
      ]
    };
  }

  if (operation.type === 'restore_asset') {
    if (asset.status !== 'trashed') return { code: 'STALE_REVISION', message: 'Asset is not in Trash' };
    const receipt = await env.DB.prepare('SELECT prior_folder_id, prior_album_ids_json, prior_tag_ids_json FROM asset_trash WHERE asset_id = ?').bind(asset.id)
      .first<{ prior_folder_id: string; prior_album_ids_json: string; prior_tag_ids_json: string }>();
    if (!receipt) return { code: 'STALE_REVISION', message: 'Trash receipt is unavailable' };
    const priorAlbumIDs = JSON.parse(receipt.prior_album_ids_json) as string[];
    const priorTagIDs = JSON.parse(receipt.prior_tag_ids_json) as string[];
    const destination = await env.DB.prepare('SELECT id FROM folders WHERE id = ?').bind(receipt.prior_folder_id).first<{ id: string }>();
    const folderID = destination?.id ?? 'system-inbox';
    return {
      index, operation, entityType: 'asset', revision: nextRevision,
      afterState: { id: asset.id, blobId: asset.blob_id, displayName: asset.display_name, folderId: folderID, favorite: Boolean(asset.favorite), rating: asset.rating, status: 'active', revision: nextRevision },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM assets WHERE id = ? AND revision = ? AND status = \'trashed\') AND EXISTS (SELECT 1 FROM asset_trash WHERE asset_id = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, asset.id, asset.revision, asset.id],
      mutationStatements: [
        { sql: "UPDATE assets SET status = 'active', folder_id = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [folderID, asset.id] },
        { sql: 'DELETE FROM album_assets WHERE asset_id = ?', params: [asset.id] },
        { sql: 'DELETE FROM asset_tags WHERE asset_id = ?', params: [asset.id] },
        { sql: "INSERT OR IGNORE INTO album_assets (album_id, asset_id) SELECT value, ? FROM json_each(?) WHERE EXISTS (SELECT 1 FROM albums WHERE id = value)", params: [asset.id, JSON.stringify(priorAlbumIDs)] },
        { sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) SELECT ?, value FROM json_each(?) WHERE EXISTS (SELECT 1 FROM tags WHERE id = value)", params: [asset.id, JSON.stringify(priorTagIDs)] },
        { sql: 'DELETE FROM asset_trash WHERE asset_id = ?', params: [asset.id] }
      ]
    };
  }

  if (operation.type === 'move_asset' || operation.type === 'move_assets') {
    const folderId = operation.payload.folderId;
    if (!ID.test(String(folderId))) return { code: 'INVALID_MUTATION', message: 'Destination folder is invalid' };
    return {
      index, operation, entityType: 'asset', revision: nextRevision,
      afterState: { id: asset.id, blobId: asset.blob_id, displayName: asset.display_name, folderId, favorite: Boolean(asset.favorite), rating: asset.rating, revision: nextRevision },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM assets WHERE id = ? AND revision = ?)
          AND EXISTS (SELECT 1 FROM folders WHERE id = ?) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, asset.id, asset.revision, String(folderId)],
      mutationStatements: [{ sql: "UPDATE assets SET folder_id = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [String(folderId), asset.id] }]
    };
  }

  if (operation.type === 'update_rating') {
    const rating = operation.payload.rating;
    if (!Number.isInteger(rating) || Number(rating) < 0 || Number(rating) > 5) return { code: 'INVALID_MUTATION', message: 'Rating must be between zero and five' };
    return {
      index, operation, entityType: 'asset', revision: nextRevision,
      afterState: { id: asset.id, blobId: asset.blob_id, displayName: asset.display_name, folderId: asset.folder_id, favorite: Boolean(asset.favorite), rating, revision: nextRevision },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM assets WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, asset.id, asset.revision],
      mutationStatements: [{ sql: "UPDATE assets SET rating = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [rating, asset.id] }]
    };
  }

  if (operation.type === 'update_favorite') {
    const favorite = operation.payload.favorite;
    if (typeof favorite !== 'boolean') return { code: 'INVALID_MUTATION', message: 'favorite must be a boolean' };
    return {
      index, operation, entityType: 'asset', revision: nextRevision,
      afterState: { id: asset.id, blobId: asset.blob_id, displayName: asset.display_name, folderId: asset.folder_id, favorite, rating: asset.rating, revision: nextRevision },
      guardSql: 'INSERT INTO mutation_guards (request_id, valid) VALUES (?, CASE WHEN EXISTS (SELECT 1 FROM assets WHERE id = ? AND revision = ?) THEN 1 ELSE 0 END)',
      guardParams: [guardId, asset.id, asset.revision],
      mutationStatements: [{ sql: "UPDATE assets SET favorite = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?", params: [favorite ? 1 : 0, asset.id] }]
    };
  }

  return { code: 'INVALID_MUTATION', message: 'Mutation type is unsupported' };
}

mutationsRouter.post('/mutations', requireAuth(), async (c) => {
  let body: MutationRequest;
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }

  const mutationId = c.req.header('Idempotency-Key') ?? body.clientMutationId;
  if (!mutationId || !ID.test(mutationId)) return apiError(c, 400, 'MISSING_IDEMPOTENCY_KEY', 'A valid Idempotency-Key is required');
  if (!Array.isArray(body.operations) || body.operations.length === 0 || body.operations.length > 25) {
    return apiError(c, 400, 'INVALID_MUTATION', 'operations must contain between one and twenty-five entries');
  }

  const actorId = c.get('deviceId');
  const requestFingerprint = await fingerprint({ operations: body.operations });
  const existing = await c.env.DB.prepare(
    'SELECT actor_id, request_fingerprint, response_code, response_body FROM idempotency_keys WHERE client_mutation_id = ?'
  )
    .bind(mutationId)
    .first<{ actor_id: string; request_fingerprint: string; response_code: number; response_body: string }>();
  if (existing) {
    if (existing.actor_id !== actorId || existing.request_fingerprint !== requestFingerprint) {
      return apiError(c, 409, 'IDEMPOTENCY_KEY_REUSED', 'Idempotency key was used for a different request');
    }
    return c.json(JSON.parse(existing.response_body), existing.response_code as 200);
  }

  const grantedScopes = c.get('scopes') ?? [];
  const missingScopes = new Set<string>();
  for (const operation of body.operations) {
    const required = REQUIRED_SCOPE_BY_OPERATION[operation.type];
    if (!required || !grantedScopes.includes(required)) missingScopes.add(required ?? operation.type);
  }
  if (missingScopes.size > 0) return apiError(c, 403, 'FORBIDDEN', `Missing required scope(s): ${[...missingScopes].join(', ')}`);

  const prepared: PreparedOperation[] = [];
  for (const [index, operation] of body.operations.entries()) {
    const result = await prepareOperation(c.env, operation, index, mutationId);
    if ('code' in result) return apiError(c, result.code === 'STALE_REVISION' ? 409 : 422, result.code, result.message);
    prepared.push(result);
  }

  const responseBody = {
    status: 'applied',
    clientMutationId: mutationId,
    appliedCount: prepared.length,
    results: prepared.map((entry) => ({
      entityType: entry.entityType,
      targetId: entry.operation.targetId,
      operation: entry.operation.type,
      revision: entry.revision
    }))
  };

  const statements = [
    ...prepared.map((entry) => c.env.DB.prepare(entry.guardSql).bind(...entry.guardParams)),
    ...prepared.flatMap((entry) => [
      ...entry.mutationStatements.map((statement) => c.env.DB.prepare(statement.sql).bind(...statement.params)),
      c.env.DB.prepare(
        `INSERT INTO change_events (entity_type, entity_id, operation, payload, actor_id, client_mutation_id)
         VALUES (?, ?, ?, ?, ?, ?)`
      ).bind(entry.entityType, entry.operation.targetId, entry.operation.type, JSON.stringify(entry.afterState), actorId, `${mutationId}:${entry.index}`),
      c.env.DB.prepare(
        `INSERT INTO audit_events (client_mutation_id, actor_id, action, target_type, target_id, after_state)
         VALUES (?, ?, ?, ?, ?, ?)`
      ).bind(mutationId, actorId, entry.operation.type, entry.entityType, entry.operation.targetId, JSON.stringify(entry.afterState))
    ]),
    c.env.DB.prepare(
      `INSERT INTO idempotency_keys (client_mutation_id, actor_id, request_fingerprint, response_code, response_body)
       VALUES (?, ?, ?, 200, ?)`
    ).bind(mutationId, actorId, requestFingerprint, JSON.stringify(responseBody)),
    ...prepared.map((entry) => c.env.DB.prepare('DELETE FROM mutation_guards WHERE request_id = ?').bind(`${mutationId}:${entry.index}`))
  ];

  try {
    await c.env.DB.batch(statements);
  } catch {
    const racedReceipt = await c.env.DB.prepare(
      'SELECT actor_id, request_fingerprint, response_code, response_body FROM idempotency_keys WHERE client_mutation_id = ?'
    )
      .bind(mutationId)
      .first<{ actor_id: string; request_fingerprint: string; response_code: number; response_body: string }>();
    if (racedReceipt) {
      if (racedReceipt.actor_id === actorId && racedReceipt.request_fingerprint === requestFingerprint) {
        return c.json(JSON.parse(racedReceipt.response_body), racedReceipt.response_code as 200);
      }
      return apiError(c, 409, 'IDEMPOTENCY_KEY_REUSED', 'Idempotency key was used for a different request');
    }
    return apiError(c, 409, 'STALE_REVISION', 'One or more target entities changed before the mutation was applied');
  }

  return c.json(responseBody);
});
