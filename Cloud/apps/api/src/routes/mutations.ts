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
    return c.json(JSON.parse(existing.response_body), existing.response_code as any);
  }

  // Apply operations
  const appliedResults: Array<{ targetId: string; revision: number }> = [];

  for (const op of body.operations) {
    let entityType = 'asset';
    if (op.type.includes('folder')) entityType = 'folder';

    // Insert change event
    const changeResult = await c.env.DB.prepare(
      `INSERT INTO change_events (entity_type, entity_id, operation, payload, actor_id, client_mutation_id)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(
        entityType,
        op.targetId,
        op.type,
        JSON.stringify(op.payload),
        body.actorId || 'unknown',
        `${mutationId}_${op.targetId}`
      )
      .run();

    const newRev = changeResult.meta.last_row_id;
    appliedResults.push({ targetId: op.targetId, revision: newRev });

    // Insert audit event
    await c.env.DB.prepare(
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
      )
      .run();
  }

  const responseBody = {
    status: 'applied',
    clientMutationId: mutationId,
    appliedCount: appliedResults.length,
    results: appliedResults
  };

  // Record idempotency receipt
  await c.env.DB.prepare(
    `INSERT INTO idempotency_keys (client_mutation_id, actor_id, response_code, response_body)
     VALUES (?, ?, 200, ?)`
  )
    .bind(mutationId, body.actorId || 'unknown', JSON.stringify(responseBody))
    .run();

  return c.json(responseBody, 200);
});
