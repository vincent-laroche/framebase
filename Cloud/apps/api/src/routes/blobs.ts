import { Hono } from 'hono';
import { apiError, sha256Hex } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import { createR2Capability } from '../services/r2Capabilities.js';
import type { AppEnv } from '../types.js';

export const blobsRouter = new Hono<AppEnv>();

const SHA256 = /^[a-f0-9]{64}$/;
const EXTENSION = /^[a-z0-9]{1,10}$/;
const IMAGE_MEDIA_TYPE = /^image\/(avif|heic|heif|jpeg|png|tiff|webp)$/;
const MAX_FIXTURE_BYTES = 20 * 1024 * 1024;

interface BlobIntent {
  sha256?: string;
  byteSize?: number;
  mediaType?: string;
  originalExtension?: string;
}

function normalizedIntent(body: BlobIntent): { sha256: string; byteSize: number; mediaType: string; extension: string } | null {
  const sha256 = body.sha256?.toLowerCase();
  const extension = body.originalExtension?.replace(/^\./, '').toLowerCase();
  if (
    !sha256 ||
    !SHA256.test(sha256) ||
    !Number.isSafeInteger(body.byteSize) ||
    !body.byteSize ||
    body.byteSize < 1 ||
    body.byteSize > MAX_FIXTURE_BYTES ||
    !body.mediaType ||
    !IMAGE_MEDIA_TYPE.test(body.mediaType) ||
    !extension ||
    !EXTENSION.test(extension)
  ) {
    return null;
  }
  return { sha256, byteSize: body.byteSize, mediaType: body.mediaType, extension };
}

blobsRouter.post('/blobs/upload-initiate', requireAuth('assets.import'), async (c) => {
  let body: BlobIntent;
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }
  const intent = normalizedIntent(body);
  if (!intent) {
    return apiError(c, 422, 'INVALID_BLOB_INTENT', 'Invalid fixture blob metadata');
  }

  const r2Key = `blobs/sha256/${intent.sha256.slice(0, 2)}/${intent.sha256}.${intent.extension}`;
  const existing = await c.env.DB.prepare(
    'SELECT byte_size, media_type, original_extension, r2_key, upload_state FROM blobs WHERE sha256 = ?'
  )
    .bind(intent.sha256)
    .first<{ byte_size: number; media_type: string; original_extension: string; r2_key: string; upload_state: string }>();

  if (existing && (
    existing.byte_size !== intent.byteSize ||
    existing.media_type !== intent.mediaType ||
    existing.original_extension !== intent.extension ||
    existing.r2_key !== r2Key
  )) {
    return apiError(c, 409, 'BLOB_IDENTITY_CONFLICT', 'Blob digest has conflicting immutable metadata');
  }

  if (!existing) {
    await c.env.DB.prepare(
      `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
       VALUES (?, ?, ?, ?, ?, ?, 'pending')`
    )
      .bind(intent.sha256, intent.sha256, intent.byteSize, intent.mediaType, intent.extension, r2Key)
      .run();
  }

  if (existing?.upload_state === 'verified') {
    return c.json({ status: 'already_verified', blobId: intent.sha256 });
  }

  const capability = await createR2Capability(c.env, 'PUT', r2Key, intent.mediaType);
  if (!capability) {
    return apiError(c, 503, 'UPLOAD_CAPABILITY_UNAVAILABLE', 'Direct upload capability is not configured');
  }

  return c.json({ status: 'pending_upload', blobId: intent.sha256, upload: capability });
});

blobsRouter.post('/blobs/upload-complete', requireAuth('assets.import'), async (c) => {
  let body: { sha256?: string; byteSize?: number };
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }
  const sha256 = body.sha256?.toLowerCase();
  if (!sha256 || !SHA256.test(sha256) || !Number.isSafeInteger(body.byteSize)) {
    return apiError(c, 422, 'INVALID_REQUEST', 'sha256 and byteSize are required');
  }

  const blob = await c.env.DB.prepare(
    'SELECT r2_key, byte_size, media_type, upload_state FROM blobs WHERE sha256 = ?'
  )
    .bind(sha256)
    .first<{ r2_key: string; byte_size: number; media_type: string; upload_state: string }>();
  if (!blob) return apiError(c, 404, 'BLOB_NOT_FOUND', 'Blob was not initiated');
  if (blob.upload_state === 'verified') return c.json({ status: 'already_verified', blobId: sha256, size: blob.byte_size });

  const object = await c.env.BLOBS.get(blob.r2_key);
  if (!object) return apiError(c, 422, 'R2_OBJECT_MISSING', 'Uploaded object is missing');

  const bytes = await object.arrayBuffer();
  const actualDigest = await sha256Hex(bytes);
  const valid =
    object.size === blob.byte_size &&
    body.byteSize === blob.byte_size &&
    object.httpMetadata?.contentType === blob.media_type &&
    actualDigest === sha256;
  if (!valid) {
    await c.env.BLOBS.delete(blob.r2_key);
    await c.env.DB.prepare("UPDATE blobs SET upload_state = 'abandoned' WHERE sha256 = ?").bind(sha256).run();
    return apiError(c, 422, 'BLOB_VERIFICATION_FAILED', 'Uploaded bytes do not match the initiated blob');
  }

  await c.env.DB.prepare("UPDATE blobs SET upload_state = 'verified' WHERE sha256 = ?").bind(sha256).run();
  return c.json({ status: 'verified', blobId: sha256, size: object.size });
});

blobsRouter.get('/blobs/:id/download', requireAuth('originals.download'), async (c) => {
  const blobId = c.req.param('id').toLowerCase();
  const blob = await c.env.DB.prepare(
    "SELECT r2_key FROM blobs WHERE id = ? AND upload_state = 'verified'"
  )
    .bind(blobId)
    .first<{ r2_key: string }>();
  if (!blob) return apiError(c, 404, 'BLOB_NOT_FOUND', 'Verified blob was not found');

  if (!(await c.env.BLOBS.head(blob.r2_key))) {
    return apiError(c, 404, 'R2_OBJECT_MISSING', 'Verified blob object is missing');
  }

  const capability = await createR2Capability(c.env, 'GET', blob.r2_key);
  if (!capability) {
    return apiError(c, 503, 'DOWNLOAD_CAPABILITY_UNAVAILABLE', 'Direct download capability is not configured');
  }
  return c.json({ blobId, download: capability });
});
