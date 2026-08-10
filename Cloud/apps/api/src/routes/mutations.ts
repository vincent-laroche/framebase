import { Hono } from 'hono';
import { apiError, fingerprint } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const mutationsRouter = new Hono<AppEnv>();

type MutationOperationType =
  | 'create_folder'
  | 'rename_folder'
  | 'create_asset'
  | 'move_asset'
  | 'move_assets'
  | 'update_rating'
  | 'update_favorite';

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
  rename_folder: 'assets.organize',
  create_asset: 'assets.import',
  move_asset: 'assets.organize',
  move_assets: 'assets.organize',
  update_rating: 'assets.metadata.write',
  update_favorite: 'assets.metadata.write'
};
const ID = /^[a-zA-Z0-9_-]{3,128}$/;

interface PreparedOperation {
  index: number;
  operation: MutationOperation;
  entityType: 'folder' | 'asset';
  revision: number;
  afterState: Record<string, unknown>;
  guardSql: string;
  guardParams: unknown[];
  mutationSql: string;
  mutationParams: unknown[];
}

function validName(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= 160;
}

function validRevision(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

async function prepareOperation(
  env: AppEnv['Bindings'],
  operation: MutationOperation,
  index: number,
  mutationId: string
): Promise<PreparedOperation | { code: string; message: string }> {
  if (!ID.test(operation.targetId)) return { code: 'INVALID_MUTATION', message: 'targetId is invalid' };
  const guardId = `${mutationId}:${index}`;

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
      mutationSql: 'INSERT INTO folders (id, name, parent_id, revision) VALUES (?, ?, ?, 1)',
      mutationParams: [operation.targetId, name.trim(), parent]
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
      mutationSql: "UPDATE folders SET name = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?",
      mutationParams: [name.trim(), operation.targetId]
    };
  }

  if (operation.type === 'create_asset') {
    const blobId = operation.payload.blobId;
    const folderId = operation.payload.folderId;
    const displayName = operation.payload.displayName;
    if (!ID.test(String(blobId)) || !ID.test(String(folderId)) || !validName(displayName)) {
      return { code: 'INVALID_MUTATION', message: 'Asset blob, folder, or display name is invalid' };
    }
    return {
      index, operation, entityType: 'asset', revision: 1,
      afterState: { id: operation.targetId, blobId, folderId, displayName: displayName.trim(), favorite: false, rating: 0, revision: 1 },
      guardSql: `INSERT INTO mutation_guards (request_id, valid)
        VALUES (?, CASE WHEN NOT EXISTS (SELECT 1 FROM assets WHERE id = ?)
          AND EXISTS (SELECT 1 FROM blobs WHERE id = ? AND upload_state = 'verified')
          AND EXISTS (SELECT 1 FROM folders WHERE id = ?) THEN 1 ELSE 0 END)`,
      guardParams: [guardId, operation.targetId, String(blobId), String(folderId)],
      mutationSql: 'INSERT INTO assets (id, blob_id, display_name, folder_id, revision) VALUES (?, ?, ?, ?, 1)',
      mutationParams: [operation.targetId, String(blobId), displayName.trim(), String(folderId)]
    };
  }

  if (!validRevision(operation.baseRevision)) return { code: 'BASE_REVISION_REQUIRED', message: 'baseRevision is required for an existing entity' };

  const asset = await env.DB.prepare('SELECT id, blob_id, display_name, folder_id, favorite, rating, revision FROM assets WHERE id = ?')
    .bind(operation.targetId)
    .first<{ id: string; blob_id: string; display_name: string; folder_id: string; favorite: number; rating: number; revision: number }>();
  if (!asset || asset.revision !== operation.baseRevision) return { code: 'STALE_REVISION', message: 'Asset has changed' };
  const nextRevision = asset.revision + 1;

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
      mutationSql: "UPDATE assets SET folder_id = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?",
      mutationParams: [String(folderId), asset.id]
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
      mutationSql: "UPDATE assets SET rating = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?",
      mutationParams: [rating, asset.id]
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
      mutationSql: "UPDATE assets SET favorite = ?, revision = revision + 1, updated_at = datetime('now') WHERE id = ?",
      mutationParams: [favorite ? 1 : 0, asset.id]
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
      c.env.DB.prepare(entry.mutationSql).bind(...entry.mutationParams),
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
