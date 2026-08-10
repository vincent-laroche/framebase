import { Hono } from 'hono';
import { apiError, parseBoundedInteger } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const catalogRouter = new Hono<AppEnv>();

interface SnapshotEntity {
  entityType: 'folder' | 'asset' | 'album';
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
  const [folders, assets, albums] = await Promise.all([
    c.env.DB.prepare('SELECT id, name, parent_id, system_kind, sort_order, revision, created_at, updated_at FROM folders ORDER BY id').all<{
      id: string; name: string; parent_id: string | null; system_kind: string | null; sort_order: number; revision: number; created_at: string; updated_at: string;
    }>(),
    c.env.DB.prepare('SELECT id, blob_id, display_name, folder_id, favorite, rating, status, revision, created_at, updated_at FROM assets ORDER BY id').all<{
      id: string; blob_id: string; display_name: string; folder_id: string; favorite: number; rating: number; status: string; revision: number; created_at: string; updated_at: string;
    }>(),
    c.env.DB.prepare('SELECT id, name, revision, created_at, updated_at FROM albums ORDER BY id').all<{
      id: string; name: string; revision: number; created_at: string; updated_at: string;
    }>()
  ]);

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
        createdAt: asset.created_at, updatedAt: asset.updated_at
      }
    })),
    ...albums.results.map((album) => ({
      entityType: 'album' as const,
      entityId: album.id,
      revision: album.revision,
      payload: { id: album.id, name: album.name, createdAt: album.created_at, updatedAt: album.updated_at }
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
