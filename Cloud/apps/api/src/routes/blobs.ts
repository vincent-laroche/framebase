import { Hono } from 'hono';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const blobsRouter = new Hono<AppEnv>();

blobsRouter.post('/blobs/upload-initiate', requireAuth('assets.import'), async (c) => {
  const body = await c.req.json<{
    sha256: string;
    byteSize: number;
    mediaType: string;
    originalExtension: string;
  }>();

  if (!body.sha256 || !body.byteSize || !body.mediaType || !body.originalExtension) {
    return c.json(
      { error: { code: 'INVALID_REQUEST', message: 'sha256, byteSize, mediaType, and originalExtension are required' } },
      400
    );
  }

  const prefix = body.sha256.substring(0, 2);
  const ext = body.originalExtension.startsWith('.') ? body.originalExtension.substring(1) : body.originalExtension;
  const r2Key = `blobs/sha256/${prefix}/${body.sha256}.${ext}`;

  await c.env.DB.prepare(
    `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
     VALUES (?, ?, ?, ?, ?, ?, 'pending')
     ON CONFLICT(sha256) DO NOTHING`
  )
    .bind(body.sha256, body.sha256, body.byteSize, body.mediaType, ext, r2Key)
    .run();

  return c.json({
    blobId: body.sha256,
    r2Key,
    uploadUrl: `/v1/blobs/upload-direct?key=${encodeURIComponent(r2Key)}`,
    expiresAt: new Date(Date.now() + 900 * 1000).toISOString()
  });
});

blobsRouter.put('/blobs/upload-direct', requireAuth('assets.import'), async (c) => {
  const key = c.req.query('key');
  if (!key) {
    return c.json({ error: { code: 'MISSING_KEY', message: 'key query param required' } }, 400);
  }

  const body = await c.req.arrayBuffer();
  await c.env.BLOBS.put(key, body);

  return c.json({ status: 'uploaded', key, size: body.byteLength });
});

blobsRouter.post('/blobs/upload-complete', requireAuth('assets.import'), async (c) => {
  const body = await c.req.json<{
    sha256: string;
    byteSize: number;
  }>();

  if (!body.sha256) {
    return c.json({ error: { code: 'INVALID_REQUEST', message: 'sha256 required' } }, 400);
  }

  const blob = await c.env.DB.prepare('SELECT * FROM blobs WHERE sha256 = ?')
    .bind(body.sha256)
    .first<{ r2_key: string; byte_size: number }>();

  if (!blob) {
    return c.json({ error: { code: 'BLOB_NOT_FOUND', message: 'Blob not found' } }, 404);
  }

  const head = await c.env.BLOBS.head(blob.r2_key);
  if (!head) {
    return c.json({ error: { code: 'R2_OBJECT_MISSING', message: 'Object missing in R2 storage' } }, 400);
  }

  await c.env.DB.prepare("UPDATE blobs SET upload_state = 'verified' WHERE sha256 = ?")
    .bind(body.sha256)
    .run();

  return c.json({
    status: 'verified',
    blobId: body.sha256,
    size: head.size
  });
});

blobsRouter.get('/blobs/:id/download', requireAuth('originals.download'), async (c) => {
  const blobId = c.req.param('id');
  const blob = await c.env.DB.prepare('SELECT * FROM blobs WHERE id = ? OR sha256 = ?')
    .bind(blobId, blobId)
    .first<{ r2_key: string; media_type: string }>();

  if (!blob) {
    return c.json({ error: { code: 'BLOB_NOT_FOUND', message: 'Blob not found' } }, 404);
  }

  const object = await c.env.BLOBS.get(blob.r2_key);
  if (!object) {
    return c.json({ error: { code: 'OBJECT_NOT_FOUND', message: 'Object not found in R2' } }, 404);
  }

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('etag', object.httpEtag);
  headers.set('Content-Type', blob.media_type || 'application/octet-stream');

  return new Response(object.body, { headers });
});
