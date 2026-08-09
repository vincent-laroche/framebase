import { Hono } from 'hono';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const mutationsRouter = new Hono<AppEnv>();

type MutationOperationType =
  | 'create_folder'
  | 'rename_folder'
  | 'move_assets'
  | 'update_rating'
  | 'update_favorite';

interface MutationRequest {
  clientMutationId: string;
  actorId: string;
  operations: Array<{
    type: MutationOperationType;
    targetId: string;
    payload: Record<string, unknown>;
  }>;
}

const REQUIRED_SCOPE_BY_OPERATION: Record<MutationOperationType, string> = {
  create_folder: 'assets.organize',
  rename_folder: 'assets.organize',
  move_assets: 'assets.organize',
  update_rating: 'assets.metadata.write',
  update_favorite: 'assets.metadata.write'
};

mutationsRouter.post('/mutations', requireAuth(), async (c) => {
  const idempotencyKey = c.req.header('Idempotency-Key');
  const body = await c.req.json<MutationRequest>();

  const grantedScopes = c.get('scopes') ?? [];
  const missingScopes = new Set<string>();
  for (const op of body.operations) {
    const requiredScope = REQUIRED_SCOPE_BY_OPERATION[op.type];
    if (!requiredScope || !grantedScopes.includes(requiredScope)) {
      missingScopes.add(requiredScope ?? op.type);
    }
  }
  if (missingScopes.size > 0) {
    return c.json(
      {
        error: {
          code: 'FORBIDDEN',
          message: `Missing required scope(s): ${Array.from(missingScopes).join(', ')}`
        }
      },
      403
    );
  }

  const mutationId = idempotencyKey || body.clientMutationId;
  if (!mutationId) {
    return c.json(
      { error: { code: 'MISSING_IDEMPOTENCY_KEY', message: 'Idempotency-Key header or clientMutationId required' } },
      400
    );
  }

  // Check idempotency receipt
  const existing = await c.env.DB.prepare('SELECT response_code, response_body FROM idempotency_keys WHERE client_mutation_id = ?')
    .bind(mutationId)
    .first<{ response_code: number; response_body: string }>();

  if (existing) {
    if (existing.response_body === '{}') {
      const { results } = await c.env.DB.prepare(
        `SELECT entity_id, revision FROM change_events
         WHERE client_mutation_id LIKE ? ESCAPE '\\' ORDER BY revision ASC`
      )
        .bind(`${mutationId.replace(/[\\%_]/g, '\\$&')}:%`)
        .all<{ entity_id: string; revision: number }>();
      return c.json({
        status: 'applied',
        clientMutationId: mutationId,
        appliedCount: results.length,
        results: results.map((event) => ({ targetId: event.entity_id, revision: event.revision }))
      }, existing.response_code as any);
    }
    return c.json(JSON.parse(existing.response_body), existing.response_code as any);
  }

  // Validate the entire batch before the first write. D1 does not expose a
  // long-lived transaction API here, so this prevents a malformed later
  // operation from leaving an earlier valid operation half-applied.
  for (const op of body.operations) {
    const folderName = typeof op.payload.name === 'string' ? op.payload.name.trim() : '';
    const rating = typeof op.payload.rating === 'number' ? op.payload.rating : NaN;
    const favorite = op.payload.favorite;
    const targetFolderID = typeof op.payload.targetFolderId === 'string' ? op.payload.targetFolderId : '';
    if ((op.type === 'create_folder' || op.type === 'rename_folder') && !folderName) {
      return c.json({ error: { code: 'INVALID_REQUEST', message: `${op.type} requires a non-empty name` } }, 400);
    }
    if (op.type === 'update_rating' && (!Number.isInteger(rating) || rating < 0 || rating > 5)) {
      return c.json({ error: { code: 'INVALID_REQUEST', message: 'update_rating requires an integer rating from 0 through 5' } }, 400);
    }
    if (op.type === 'update_favorite' && typeof favorite !== 'boolean') {
      return c.json({ error: { code: 'INVALID_REQUEST', message: 'update_favorite requires a boolean favorite value' } }, 400);
    }
    if (op.type === 'move_assets' && !targetFolderID) {
      return c.json({ error: { code: 'INVALID_REQUEST', message: 'move_assets requires a targetFolderId' } }, 400);
    }
  }

  // One D1 batch is an all-or-nothing transaction. Each operation adds its
  // immutable change event, canonical state update, and audit row, followed
  // by the idempotency marker in that same transaction.
  const statements: D1PreparedStatement[] = [];
  const now = new Date().toISOString();
  for (const [index, op] of body.operations.entries()) {
    const folderName = typeof op.payload.name === 'string' ? op.payload.name.trim() : '';
    const rating = typeof op.payload.rating === 'number' ? op.payload.rating : NaN;
    const favorite = op.payload.favorite;
    const targetFolderID = typeof op.payload.targetFolderId === 'string' ? op.payload.targetFolderId : '';
    let entityType = 'asset';
    if (op.type.includes('folder')) entityType = 'folder';

    statements.push(c.env.DB.prepare(
      `INSERT INTO change_events (entity_type, entity_id, operation, payload, actor_id, client_mutation_id)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(
        entityType,
        op.targetId,
        op.type,
        JSON.stringify(op.payload),
        body.actorId || 'unknown',
        `${mutationId}:${index}`
      ));

    if (op.type === 'create_folder') {
      const parentID = typeof op.payload.parentId === 'string' ? op.payload.parentId : null;
      statements.push(c.env.DB.prepare(
        `INSERT INTO folders (id, name, parent_id, system_kind, sort_order, created_at, updated_at, revision)
         VALUES (?, ?, ?, NULL, 0.0, ?, ?, last_insert_rowid())`
      )
        .bind(op.targetId, folderName, parentID, now, now));
    }
    if (op.type === 'rename_folder') {
      statements.push(c.env.DB.prepare('UPDATE folders SET name = ?, updated_at = ?, revision = last_insert_rowid() WHERE id = ?')
        .bind(folderName, now, op.targetId));
    }
    if (op.type === 'update_rating') {
      statements.push(c.env.DB.prepare('UPDATE assets SET rating = ?, updated_at = ?, revision = last_insert_rowid() WHERE id = ?')
        .bind(rating, now, op.targetId));
    }
    if (op.type === 'update_favorite') {
      statements.push(c.env.DB.prepare('UPDATE assets SET favorite = ?, updated_at = ?, revision = last_insert_rowid() WHERE id = ?')
        .bind(favorite ? 1 : 0, now, op.targetId));
    }
    if (op.type === 'move_assets') {
      statements.push(c.env.DB.prepare('UPDATE assets SET folder_id = ?, updated_at = ?, revision = last_insert_rowid() WHERE id = ?')
        .bind(targetFolderID, now, op.targetId));
    }

    statements.push(c.env.DB.prepare(
      `INSERT INTO audit_events (client_mutation_id, actor_id, action, target_type, target_id, after_state)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(
        mutationId,
        body.actorId || 'unknown',
        op.type,
        entityType,
        op.targetId,
        JSON.stringify(op.payload)
      ));
  }
  statements.push(c.env.DB.prepare(
    `INSERT INTO idempotency_keys (client_mutation_id, actor_id, response_code, response_body)
     VALUES (?, ?, 200, ?)`
  )
    .bind(mutationId, body.actorId || 'unknown', '{}'));
  await c.env.DB.batch(statements);

  const { results } = await c.env.DB.prepare(
    `SELECT entity_id, revision FROM change_events
     WHERE client_mutation_id LIKE ? ESCAPE '\\' ORDER BY revision ASC`
  )
    .bind(`${mutationId.replace(/[\\%_]/g, '\\$&')}:%`)
    .all<{ entity_id: string; revision: number }>();
  return c.json({
    status: 'applied',
    clientMutationId: mutationId,
    appliedCount: results.length,
    results: results.map((event) => ({ targetId: event.entity_id, revision: event.revision }))
  }, 200);
});
