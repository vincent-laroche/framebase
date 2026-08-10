import { Hono } from 'hono';
import { apiError, parseBoundedInteger } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const catalogRouter = new Hono<AppEnv>();

interface SnapshotEntity {
  entityType: 'folder' | 'asset' | 'album' | 'tag' | 'saved_search' | 'export_receipt' | 'backup_manifest';
  entityId: string;
  revision: number;
  payload: Record<string, unknown>;
}

catalogRouter.get('/catalog/bootstrap', requireAuth('library.read'), async (c) => {
  const offset = parseBoundedInteger(c.req.query('cursor'), 0, 100_000);
  const limit = parseBoundedInteger(c.req.query('limit'), 100, 500);
  if (offset === null || limit === null || limit === 0) {
    return apiError(c, 400, 'INVALID_CURSOR', 'cursor and limit must be bounded positive integers');
  }

  const watermarkRow = await c.env.DB.prepare('SELECT COALESCE(MAX(revision), 0) AS revision FROM change_events')
    .first<{ revision: number }>();
  const [folders, assets, albums, albumAssets, tags, tagAssets, savedSearches, exportReceipts, backupManifests, trashRows] = await Promise.all([
    c.env.DB.prepare('SELECT id, name, parent_id, system_kind, sort_order, revision, created_at, updated_at FROM folders ORDER BY id').all<{
      id: string; name: string; parent_id: string | null; system_kind: string | null; sort_order: number; revision: number; created_at: string; updated_at: string;
    }>(),
    c.env.DB.prepare(`SELECT assets.id, assets.blob_id, assets.display_name, assets.folder_id, assets.favorite, assets.rating,
      assets.status, assets.asset_metadata, assets.revision, assets.created_at, assets.updated_at,
      blobs.byte_size AS blob_byte_size, blobs.media_type AS blob_media_type, blobs.original_extension AS blob_original_extension
      FROM assets JOIN blobs ON blobs.id = assets.blob_id ORDER BY assets.id`).all<{
      id: string; blob_id: string; display_name: string; folder_id: string; favorite: number; rating: number; status: string;
      asset_metadata: string; revision: number; created_at: string; updated_at: string; blob_byte_size: number; blob_media_type: string; blob_original_extension: string;
    }>(),
    c.env.DB.prepare('SELECT id, name, sort_order, revision, created_at, updated_at FROM albums ORDER BY sort_order, id').all<{
      id: string; name: string; sort_order: number; revision: number; created_at: string; updated_at: string;
    }>(),
    c.env.DB.prepare('SELECT album_id, asset_id FROM album_assets ORDER BY album_id, sort_order, asset_id').all<{
      album_id: string; asset_id: string;
    }>(),
    c.env.DB.prepare('SELECT id, name, revision, created_at, updated_at FROM tags ORDER BY id').all<{
      id: string; name: string; revision: number; created_at: string; updated_at: string;
    }>(),
    c.env.DB.prepare('SELECT tag_id, asset_id FROM asset_tags ORDER BY tag_id, asset_id').all<{
      tag_id: string; asset_id: string;
    }>(),
    c.env.DB.prepare('SELECT id, name, rules_json, sort_json, revision, created_at, updated_at FROM saved_searches ORDER BY id').all<{
      id: string; name: string; rules_json: string; sort_json: string; revision: number; created_at: string; updated_at: string;
    }>(),
    c.env.DB.prepare('SELECT id, manifest_sha256, asset_ids_json, completed_at, revision FROM export_receipts ORDER BY id').all<{
      id: string; manifest_sha256: string; asset_ids_json: string; completed_at: string; revision: number;
    }>(),
    c.env.DB.prepare('SELECT id, manifest_sha256, recorded_at, last_restore_drill_at, last_restore_drill_result, revision FROM backup_manifests ORDER BY id').all<{
      id: string; manifest_sha256: string; recorded_at: string; last_restore_drill_at: string | null; last_restore_drill_result: string | null; revision: number;
    }>(),
    c.env.DB.prepare('SELECT asset_id, prior_folder_id, prior_album_ids_json, prior_tag_ids_json, trashed_at, scheduled_purge_at FROM asset_trash ORDER BY asset_id').all<{
      asset_id: string; prior_folder_id: string; prior_album_ids_json: string; prior_tag_ids_json: string; trashed_at: string; scheduled_purge_at: string;
    }>()
  ]);
  const assetIDsByAlbum = new Map<string, string[]>();
  for (const membership of albumAssets.results) {
    const assetIDs = assetIDsByAlbum.get(membership.album_id) ?? [];
    assetIDs.push(membership.asset_id);
    assetIDsByAlbum.set(membership.album_id, assetIDs);
  }
  const assetIDsByTag = new Map<string, string[]>();
  for (const membership of tagAssets.results) {
    const assetIDs = assetIDsByTag.get(membership.tag_id) ?? [];
    assetIDs.push(membership.asset_id);
    assetIDsByTag.set(membership.tag_id, assetIDs);
  }
  const trashByAssetID = new Map(trashRows.results.map((trash) => [trash.asset_id, trash]));

  const entities: SnapshotEntity[] = [
    ...folders.results.map((folder) => ({
      entityType: 'folder' as const,
      entityId: folder.id,
      revision: folder.revision,
      payload: {
        id: folder.id, name: folder.name, parentId: folder.parent_id, systemKind: folder.system_kind,
        sortOrder: folder.sort_order, createdAt: folder.created_at, updatedAt: folder.updated_at
      }
    })),
    ...assets.results.map((asset) => ({
      entityType: 'asset' as const,
      entityId: asset.id,
      revision: asset.revision,
      payload: {
        id: asset.id, blobId: asset.blob_id, displayName: asset.display_name, folderId: asset.folder_id,
        favorite: Boolean(asset.favorite), rating: asset.rating, status: asset.status,
        assetMetadata: JSON.parse(asset.asset_metadata),
        blob: { sha256: asset.blob_id, byteSize: asset.blob_byte_size, mediaType: asset.blob_media_type, originalExtension: asset.blob_original_extension },
        createdAt: asset.created_at, updatedAt: asset.updated_at,
        trash: (() => {
          const trash = trashByAssetID.get(asset.id);
          return trash ? {
            priorFolderId: trash.prior_folder_id,
            priorAlbumIds: JSON.parse(trash.prior_album_ids_json),
            priorTagIds: JSON.parse(trash.prior_tag_ids_json),
            trashedAt: trash.trashed_at,
            scheduledPurgeAt: trash.scheduled_purge_at
          } : null;
        })()
      }
    })),
    ...albums.results.map((album) => ({
      entityType: 'album' as const,
      entityId: album.id,
      revision: album.revision,
      payload: { id: album.id, name: album.name, sortOrder: album.sort_order, assetIds: assetIDsByAlbum.get(album.id) ?? [], createdAt: album.created_at, updatedAt: album.updated_at }
    })),
    ...tags.results.map((tag) => ({
      entityType: 'tag' as const,
      entityId: tag.id,
      revision: tag.revision,
      payload: { id: tag.id, name: tag.name, assetIds: assetIDsByTag.get(tag.id) ?? [], createdAt: tag.created_at, updatedAt: tag.updated_at }
    })),
    ...savedSearches.results.map((savedSearch) => ({
      entityType: 'saved_search' as const,
      entityId: savedSearch.id,
      revision: savedSearch.revision,
      payload: { id: savedSearch.id, name: savedSearch.name, rules: JSON.parse(savedSearch.rules_json), sort: JSON.parse(savedSearch.sort_json), createdAt: savedSearch.created_at, updatedAt: savedSearch.updated_at }
    })),
    ...exportReceipts.results.map((receipt) => ({
      entityType: 'export_receipt' as const,
      entityId: receipt.id,
      revision: receipt.revision,
      payload: { id: receipt.id, manifestSHA256: receipt.manifest_sha256, assetIds: JSON.parse(receipt.asset_ids_json), completedAt: receipt.completed_at }
    })),
    ...backupManifests.results.map((manifest) => ({
      entityType: 'backup_manifest' as const,
      entityId: manifest.id,
      revision: manifest.revision,
      payload: { id: manifest.id, manifestSHA256: manifest.manifest_sha256, recordedAt: manifest.recorded_at, lastRestoreDrillAt: manifest.last_restore_drill_at, lastRestoreDrillResult: manifest.last_restore_drill_result }
    }))
  ].sort((left, right) => `${left.entityType}:${left.entityId}`.localeCompare(`${right.entityType}:${right.entityId}`));

  const page = entities.slice(offset, offset + limit);
  const nextOffset = offset + page.length;
  return c.json({
    watermarkRevision: watermarkRow?.revision ?? 0,
    entities: page,
    nextCursor: nextOffset < entities.length ? String(nextOffset) : null
  });
});
