import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { AppEnv } from './types.js';
import { healthRouter } from './routes/health.js';
import { authRouter } from './routes/auth.js';
import { blobsRouter } from './routes/blobs.js';
import { changesRouter } from './routes/changes.js';
import { mutationsRouter } from './routes/mutations.js';
import { assetsRouter } from './routes/assets.js';

const app = new Hono<AppEnv>();

// CORS & Middleware
app.use('*', cors({ origin: '*', allowHeaders: ['Content-Type', 'Authorization', 'Idempotency-Key'] }));

// Mount /v1 routes
app.route('/v1', healthRouter);
app.route('/v1', authRouter);
app.route('/v1', blobsRouter);
app.route('/v1', changesRouter);
app.route('/v1', mutationsRouter);
app.route('/v1', assetsRouter);

// Root fallback
app.get('/', (c) => c.json({ name: 'Framebase API Dev', version: '0.1.0', docs: '/v1/health' }));

export default app;
