import { Hono } from 'hono';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const assetsRouter = new Hono<AppEnv>();

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface AssetRegistrationRequest {
  clientMutationId: string;
  assetId: string;
  blobId: string;
  folderId: string;
  filename: string;
  displayName: string;
  width: number | null;
  height: number | null;
  createdAt: string;
  modifiedAt: string;
  importedAt: string;
  favorite: boolean;
  rating: number;
  metadata: Record<string, unknown>;
}

assetsRouter.post('/assets/register', requireAuth('assets.import'), async (c) => {
  const idempotencyKey = c.req.header('Idempotency-Key');
  const body = await c.req.json<AssetRegistrationRequest>();
  const mutationId = idempotencyKey || body.clientMutationId;
  if (!mutationId || !body.assetId || !body.blobId || !body.folderId || !body.filename || !body.displayName) {
    return c.json({ error: { code: 'INVALID_REQUEST', message: 'asset, blob, folder, filename, displayName, and idempotency ids are required' } }, 400);
  }
  if (!UUID_PATTERN.test(body.assetId) || !UUID_PATTERN.test(body.folderId)) {
    return c.json({ error: { code: 'INVALID_REQUEST', message: 'assetId and folderId must be UUIDs' } }, 400);
  }
  if (!Number.isInteger(body.rating) || body.rating < 0 || body.rating > 5 || typeof body.favorite !== 'boolean') {
    return c.json({ error: { code: 'INVALID_REQUEST', message: 'favorite and rating are invalid' } }, 400);
  }

  const existing = await c.env.DB.prepare('SELECT response_code, response_body FROM idempotency_keys WHERE client_mutation_id = ?')
    .bind(mutationId)
    .first<{ response_code: number; response_body: string }>();
  if (existing) {
    if (existing.response_body === '{}') {
      const asset = await c.env.DB.prepare('SELECT blob_id, revision FROM assets WHERE id = ?')
        .bind(body.assetId)
        .first<{ blob_id: string; revision: number }>();
      if (asset) return c.json({ status: 'registered', assetId: body.assetId, blobId: asset.blob_id, revision: asset.revision }, existing.response_code as 200);
    }
    return c.json(JSON.parse(existing.response_body), existing.response_code as 200);
  }

  const blob = await c.env.DB.prepare('SELECT id FROM blobs WHERE id = ? AND upload_state = \'verified\'')
    .bind(body.blobId)
    .first<{ id: string }>();
  if (!blob) return c.json({ error: { code: 'BLOB_NOT_VERIFIED', message: 'A verified blob is required' } }, 409);
  const folder = await c.env.DB.prepare('SELECT id FROM folders WHERE id = ?').bind(body.folderId).first<{ id: string }>();
  if (!folder) return c.json({ error: { code: 'FOLDER_NOT_FOUND', message: 'Folder not found' } }, 404);
  const existingAsset = await c.env.DB.prepare('SELECT id FROM assets WHERE id = ?').bind(body.assetId).first<{ id: string }>();
  if (existingAsset) {
    return c.json({ error: { code: 'ASSET_ALREADY_REGISTERED', message: 'Asset ID is already registered' } }, 409);
  }

  const now = new Date().toISOString();
  await c.env.DB.batch([
    c.env.DB.prepare(
      `INSERT INTO change_events (entity_type, entity_id, operation, payload, actor_id, client_mutation_id)
       VALUES ('asset', ?, 'create_asset', ?, ?, ?)`
    ).bind(body.assetId, JSON.stringify(body), c.get('deviceId') ?? 'unknown', mutationId),
    c.env.DB.prepare(
      `INSERT INTO assets (id, blob_id, filename, display_name, folder_id, favorite, rating, status,
                          source_created_at, source_modified_at, imported_at, metadata_json, created_at, updated_at, revision)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, last_insert_rowid())`
    ).bind(body.assetId, body.blobId, body.filename, body.displayName, body.folderId, body.favorite ? 1 : 0, body.rating,
      body.createdAt, body.modifiedAt, body.importedAt, JSON.stringify(body.metadata), now, now),
    c.env.DB.prepare(
      `INSERT INTO idempotency_keys (client_mutation_id, actor_id, response_code, response_body)
       VALUES (?, ?, 200, '{}')`
    ).bind(mutationId, c.get('deviceId') ?? 'unknown')
  ]);
  const asset = await c.env.DB.prepare('SELECT blob_id, revision FROM assets WHERE id = ?')
    .bind(body.assetId)
    .first<{ blob_id: string; revision: number }>();
  if (!asset) throw new Error('Atomic asset registration committed without an asset row');
  return c.json({ status: 'registered', assetId: body.assetId, blobId: asset.blob_id, revision: asset.revision });
});
