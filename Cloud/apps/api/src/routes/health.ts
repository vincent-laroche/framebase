import { Hono } from 'hono';
import type { AppEnv } from '../types.js';

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
    version: '0.1.0',
    db: dbStatus,
    timestamp: new Date().toISOString()
  });
});
