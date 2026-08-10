import { Hono } from 'hono';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';
import { apiError, parseBoundedInteger } from '../lib/api.js';

export const changesRouter = new Hono<AppEnv>();

changesRouter.get('/changes', requireAuth('library.read'), async (c) => {
  const afterParam = c.req.query('after');
  const limitParam = c.req.query('limit');

  const afterRevision = parseBoundedInteger(afterParam, 0, Number.MAX_SAFE_INTEGER);
  const limit = parseBoundedInteger(limitParam, 100, 1_000);
  if (afterRevision === null || limit === null || limit === 0) {
    return apiError(c, 400, 'INVALID_CURSOR', 'after and limit must be bounded positive integers');
  }

  const { results } = await c.env.DB.prepare(
    `SELECT revision, entity_type, entity_id, operation, payload, actor_id, client_mutation_id, created_at
     FROM change_events
     WHERE revision > ?
     ORDER BY revision ASC
     LIMIT ?`
  )
    .bind(afterRevision, limit)
    .all();

  const changes = results.map((row) => ({
    revision: row.revision,
    entityType: row.entity_type,
    entityId: row.entity_id,
    operation: row.operation,
    payload: JSON.parse(row.payload as string),
    actorId: row.actor_id,
    clientMutationId: row.client_mutation_id,
    createdAt: row.created_at
  }));

  const lastRevision = changes.length > 0 ? changes[changes.length - 1].revision : afterRevision;

  return c.json({
    changes,
    cursor: {
      after: afterRevision,
      lastRevision,
      nextCursor: lastRevision,
      hasMore: changes.length === limit
    }
  });
});
