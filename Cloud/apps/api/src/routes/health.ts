import { Hono } from 'hono';
import type { AppEnv } from '../types.js';
import { requireAuth } from '../middleware/auth.js';

export const healthRouter = new Hono<AppEnv>();

healthRouter.get('/health', async (c) => {
  let dbStatus = 'unknown';
  try {
    const result = await c.env.DB.prepare('SELECT 1 as alive').first();
    if (result && result.alive === 1) {
      dbStatus = 'ok';
    }
  } catch {
    dbStatus = 'unreachable';
  }

  return c.json({
    status: 'ok',
    environment: 'development',
    version: '0.2.0',
    db: dbStatus,
    timestamp: new Date().toISOString()
  });
});

healthRouter.get('/capabilities', requireAuth('library.read'), (c) => {
  return c.json({
    version: 'v1',
    environment: 'development',
    capabilities: {
      bootstrap: true,
      orderedChangeFeed: true,
      fixtureMutations: ['create_folder', 'rename_folder', 'create_asset', 'move_asset', 'update_rating', 'update_favorite'],
      directR2Capabilities: Boolean(c.env.R2_ACCOUNT_ID && c.env.R2_ACCESS_KEY_ID && c.env.R2_SECRET_ACCESS_KEY)
    }
  });
});
