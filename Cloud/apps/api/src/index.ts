import { Hono } from 'hono';
import type { AppEnv } from './types.js';
import { healthRouter } from './routes/health.js';
import { authRouter } from './routes/auth.js';
import { blobsRouter } from './routes/blobs.js';
import { changesRouter } from './routes/changes.js';
import { mutationsRouter } from './routes/mutations.js';
import { catalogRouter } from './routes/catalog.js';
import { derivativesRouter } from './routes/derivatives.js';
import { agentsRouter } from './routes/agents.js';

const app = new Hono<AppEnv>();

// This is a native-client API. Deliberately do not add permissive browser CORS.
app.use('*', async (c, next) => {
  c.set('requestId', crypto.randomUUID());
  await next();
  c.header('X-Request-Id', c.get('requestId'));
  const sampleRate = Number(c.env.OBSERVABILITY_SAMPLE_RATE ?? '0');
  if (Number.isFinite(sampleRate) && sampleRate > 0 && Math.random() < Math.min(sampleRate, 1)) {
    console.log(JSON.stringify({ event: 'request.completed', requestId: c.get('requestId'), method: c.req.method, status: c.res.status }));
  }
});

// Mount /v1 routes
app.route('/v1', healthRouter);
app.route('/v1', authRouter);
app.route('/v1', blobsRouter);
app.route('/v1', changesRouter);
app.route('/v1', mutationsRouter);
app.route('/v1', catalogRouter);
app.route('/v1', derivativesRouter);
app.route('/v1', agentsRouter);

// Root fallback
app.get('/', (c) => c.json({ name: 'Framebase API Dev', version: '0.1.0', docs: '/v1/health' }));

export default app;
