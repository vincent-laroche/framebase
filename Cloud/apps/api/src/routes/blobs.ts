import { Hono, type Context } from 'hono';
import { apiError, sha256Hex } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import { createR2Capability } from '../services/r2Capabilities.js';
import type { AppEnv } from '../types.js';

export const blobsRouter = new Hono<AppEnv>();

const SHA256 = /^[a-f0-9]{64}$/;
const EXTENSION = /^[a-z0-9]{1,10}$/;
const IMAGE_MEDIA_TYPE = /^image\/(avif|heic|heif|jpeg|png|tiff|webp)$/;
const MAX_DIRECT_BYTES = 20 * 1024 * 1024;
const MAX_MULTIPART_BYTES = 5 * 1024 * 1024 * 1024 * 1024;
const MULTIPART_PART_BYTES = 8 * 1024 * 1024;

interface BlobIntent {
  sha256?: string;
  byteSize?: number;
  mediaType?: string;
  originalExtension?: string;
}

function normalizedIntent(body: BlobIntent, maximumBytes: number): { sha256: string; byteSize: number; mediaType: string; extension: string } | null {
  const sha256 = body.sha256?.toLowerCase();
  const extension = body.originalExtension?.replace(/^\./, '').toLowerCase();
  if (
    !sha256 ||
    !SHA256.test(sha256) ||
    !Number.isSafeInteger(body.byteSize) ||
    !body.byteSize ||
    body.byteSize < 1 ||
    body.byteSize > maximumBytes ||
    !body.mediaType ||
    !IMAGE_MEDIA_TYPE.test(body.mediaType) ||
    !extension ||
    !EXTENSION.test(extension)
  ) {
    return null;
  }
  return { sha256, byteSize: body.byteSize, mediaType: body.mediaType, extension };
}

async function ensureBlob(
  c: Context<AppEnv>,
  intent: { sha256: string; byteSize: number; mediaType: string; extension: string }
): Promise<{ status: 'verified' | 'pending'; r2Key: string } | Response> {
  const r2Key = `blobs/sha256/${intent.sha256.slice(0, 2)}/${intent.sha256}.${intent.extension}`;
  const existing = await c.env.DB.prepare(
    'SELECT byte_size, media_type, original_extension, r2_key, upload_state FROM blobs WHERE sha256 = ?'
  ).bind(intent.sha256).first<{ byte_size: number; media_type: string; original_extension: string; r2_key: string; upload_state: string }>();
  if (existing && (
    existing.byte_size !== intent.byteSize || existing.media_type !== intent.mediaType ||
    existing.original_extension !== intent.extension || existing.r2_key !== r2Key
  )) return apiError(c, 409, 'BLOB_IDENTITY_CONFLICT', 'Blob digest has conflicting immutable metadata');
  if (!existing) {
    await c.env.DB.prepare(
      `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
       VALUES (?, ?, ?, ?, ?, ?, 'pending')`
    ).bind(intent.sha256, intent.sha256, intent.byteSize, intent.mediaType, intent.extension, r2Key).run();
  }
  return { status: existing?.upload_state === 'verified' ? 'verified' : 'pending', r2Key };
}

blobsRouter.post('/blobs/upload-initiate', requireAuth('assets.import'), async (c) => {
  let body: BlobIntent;
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }
  const intent = normalizedIntent(body, MAX_DIRECT_BYTES);
  if (!intent) {
    return apiError(c, 422, 'INVALID_BLOB_INTENT', 'Invalid fixture blob metadata');
  }

  const blob = await ensureBlob(c, intent);
  if (blob instanceof Response) return blob;
  if (blob.status === 'verified') {
    return c.json({ status: 'already_verified', blobId: intent.sha256 });
  }

  const capability = await createR2Capability(c.env, 'PUT', blob.r2Key, intent.mediaType);
  if (!capability) {
    return apiError(c, 503, 'UPLOAD_CAPABILITY_UNAVAILABLE', 'Direct upload capability is not configured');
  }

  return c.json({ status: 'pending_upload', blobId: intent.sha256, upload: capability });
});

blobsRouter.post('/blobs/multipart/initiate', requireAuth('assets.import'), async (c) => {
  let body: BlobIntent;
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  const intent = normalizedIntent(body, MAX_MULTIPART_BYTES);
  if (!intent || intent.byteSize <= MAX_DIRECT_BYTES) {
    return apiError(c, 422, 'INVALID_MULTIPART_INTENT', 'Multipart uploads require a valid original larger than the direct-upload limit');
  }
  const blob = await ensureBlob(c, intent);
  if (blob instanceof Response) return blob;
  if (blob.status === 'verified') return c.json({ status: 'already_verified', blobId: intent.sha256 });

  const deviceID = c.get('deviceId');
  const prior = await c.env.DB.prepare(
    `SELECT id, part_byte_size, part_count FROM multipart_uploads
     WHERE blob_sha256 = ? AND device_id = ? AND status = 'active' ORDER BY updated_at DESC LIMIT 1`
  ).bind(intent.sha256, deviceID).first<{ id: string; part_byte_size: number; part_count: number }>();
  if (prior) {
    const parts = await c.env.DB.prepare(
      'SELECT part_number, etag, byte_size FROM multipart_upload_parts WHERE upload_id = ? ORDER BY part_number'
    ).bind(prior.id).all<{ part_number: number; etag: string; byte_size: number }>();
    return c.json({
      status: 'pending_upload', blobId: intent.sha256, uploadId: prior.id, partByteSize: prior.part_byte_size,
      partCount: prior.part_count, uploadedParts: parts.results.map((part) => ({ partNumber: part.part_number, etag: part.etag, byteSize: part.byte_size }))
    });
  }

  const partCount = Math.ceil(intent.byteSize / MULTIPART_PART_BYTES);
  const multipart = await c.env.BLOBS.createMultipartUpload(blob.r2Key, { httpMetadata: { contentType: intent.mediaType } });
  const uploadID = crypto.randomUUID();
  await c.env.DB.prepare(
    `INSERT INTO multipart_uploads (id, blob_sha256, r2_key, r2_upload_id, device_id, media_type, byte_size, part_byte_size, part_count)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(uploadID, intent.sha256, blob.r2Key, multipart.uploadId, deviceID, intent.mediaType, intent.byteSize, MULTIPART_PART_BYTES, partCount).run();
  return c.json({ status: 'pending_upload', blobId: intent.sha256, uploadId: uploadID, partByteSize: MULTIPART_PART_BYTES, partCount, uploadedParts: [] });
});

blobsRouter.put('/blobs/multipart/:uploadId/parts/:partNumber', requireAuth('assets.import'), async (c) => {
  const uploadID = c.req.param('uploadId');
  const partNumber = Number(c.req.param('partNumber'));
  if (!Number.isSafeInteger(partNumber) || partNumber < 1) return apiError(c, 422, 'INVALID_PART_NUMBER', 'Part number must be a positive integer');
  const upload = await c.env.DB.prepare(
    `SELECT r2_key, r2_upload_id, device_id, byte_size, part_byte_size, part_count, status FROM multipart_uploads WHERE id = ?`
  ).bind(uploadID).first<{ r2_key: string; r2_upload_id: string; device_id: string; byte_size: number; part_byte_size: number; part_count: number; status: string }>();
  if (!upload || upload.device_id !== c.get('deviceId')) return apiError(c, 404, 'MULTIPART_UPLOAD_NOT_FOUND', 'Multipart upload was not found');
  if (upload.status !== 'active') return apiError(c, 409, 'MULTIPART_UPLOAD_NOT_ACTIVE', 'Multipart upload is no longer active');
  if (partNumber > upload.part_count) return apiError(c, 422, 'INVALID_PART_NUMBER', 'Part number exceeds the upload manifest');
  const expectedBytes = partNumber === upload.part_count
    ? upload.byte_size - upload.part_byte_size * (upload.part_count - 1)
    : upload.part_byte_size;
  const bytes = await c.req.arrayBuffer();
  if (bytes.byteLength !== expectedBytes) return apiError(c, 422, 'INVALID_PART_SIZE', 'Part bytes do not match the upload manifest');
  try {
    const part = await c.env.BLOBS.resumeMultipartUpload(upload.r2_key, upload.r2_upload_id).uploadPart(partNumber, bytes);
    await c.env.DB.batch([
      c.env.DB.prepare(
        `INSERT INTO multipart_upload_parts (upload_id, part_number, etag, byte_size) VALUES (?, ?, ?, ?)
         ON CONFLICT(upload_id, part_number) DO UPDATE SET etag = excluded.etag, byte_size = excluded.byte_size, created_at = datetime('now')`
      ).bind(uploadID, part.partNumber, part.etag, bytes.byteLength),
      c.env.DB.prepare("UPDATE multipart_uploads SET updated_at = datetime('now') WHERE id = ?").bind(uploadID)
    ]);
    return c.json({ uploadId: uploadID, partNumber: part.partNumber, etag: part.etag });
  } catch {
    return apiError(c, 409, 'MULTIPART_UPLOAD_EXPIRED', 'Multipart upload is no longer available; start a new one');
  }
});

blobsRouter.post('/blobs/multipart/:uploadId/complete', requireAuth('assets.import'), async (c) => {
  const uploadID = c.req.param('uploadId');
  const upload = await c.env.DB.prepare(
    `SELECT blob_sha256, r2_key, r2_upload_id, device_id, byte_size, media_type, part_count, status FROM multipart_uploads WHERE id = ?`
  ).bind(uploadID).first<{ blob_sha256: string; r2_key: string; r2_upload_id: string; device_id: string; byte_size: number; media_type: string; part_count: number; status: string }>();
  if (!upload || upload.device_id !== c.get('deviceId')) return apiError(c, 404, 'MULTIPART_UPLOAD_NOT_FOUND', 'Multipart upload was not found');
  if (upload.status === 'completed') return c.json({ status: 'awaiting_client_verification', blobId: upload.blob_sha256, uploadId: uploadID });
  if (upload.status !== 'active') return apiError(c, 409, 'MULTIPART_UPLOAD_NOT_ACTIVE', 'Multipart upload is no longer active');
  const parts = await c.env.DB.prepare(
    'SELECT part_number, etag FROM multipart_upload_parts WHERE upload_id = ? ORDER BY part_number'
  ).bind(uploadID).all<{ part_number: number; etag: string }>();
  if (parts.results.length !== upload.part_count || parts.results.some((part, index) => part.part_number !== index + 1)) {
    return apiError(c, 409, 'MULTIPART_PARTS_INCOMPLETE', 'Every upload part must be present before completion');
  }
  try {
    const object = await c.env.BLOBS.resumeMultipartUpload(upload.r2_key, upload.r2_upload_id).complete(
      parts.results.map((part) => ({ partNumber: part.part_number, etag: part.etag }))
    );
    if (object.size !== upload.byte_size || object.httpMetadata?.contentType !== upload.media_type) {
      await c.env.BLOBS.delete(upload.r2_key);
      await c.env.DB.batch([
        c.env.DB.prepare("UPDATE blobs SET upload_state = 'abandoned' WHERE sha256 = ?").bind(upload.blob_sha256),
        c.env.DB.prepare("UPDATE multipart_uploads SET status = 'aborted', updated_at = datetime('now') WHERE id = ?").bind(uploadID)
      ]);
      return apiError(c, 422, 'MULTIPART_OBJECT_MISMATCH', 'Completed object did not match its immutable metadata');
    }
    await c.env.DB.prepare("UPDATE multipart_uploads SET status = 'completed', completed_at = datetime('now'), updated_at = datetime('now') WHERE id = ?").bind(uploadID).run();
    return c.json({ status: 'awaiting_client_verification', blobId: upload.blob_sha256, uploadId: uploadID });
  } catch {
    return apiError(c, 409, 'MULTIPART_UPLOAD_EXPIRED', 'Multipart upload is no longer available; start a new one');
  }
});

blobsRouter.get('/blobs/:id/verification-download', requireAuth('assets.import'), async (c) => {
  const blobID = c.req.param('id').toLowerCase();
  const upload = await c.env.DB.prepare(
    `SELECT r2_key FROM multipart_uploads WHERE blob_sha256 = ? AND device_id = ? AND status = 'completed' ORDER BY completed_at DESC LIMIT 1`
  ).bind(blobID, c.get('deviceId')).first<{ r2_key: string }>();
  if (!upload || !(await c.env.BLOBS.head(upload.r2_key))) return apiError(c, 404, 'VERIFICATION_DOWNLOAD_NOT_FOUND', 'No completed upload is available for verification');
  const capability = await createR2Capability(c.env, 'GET', upload.r2_key);
  if (!capability) return apiError(c, 503, 'DOWNLOAD_CAPABILITY_UNAVAILABLE', 'Direct download capability is not configured');
  return c.json({ blobId: blobID, download: capability });
});

blobsRouter.post('/blobs/multipart/:uploadId/confirm', requireAuth('assets.import'), async (c) => {
  let body: { sha256?: string; byteSize?: number };
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  const uploadID = c.req.param('uploadId');
  const upload = await c.env.DB.prepare(
    `SELECT blob_sha256, r2_key, device_id, byte_size, media_type, status FROM multipart_uploads WHERE id = ?`
  ).bind(uploadID).first<{ blob_sha256: string; r2_key: string; device_id: string; byte_size: number; media_type: string; status: string }>();
  if (!upload || upload.device_id !== c.get('deviceId')) return apiError(c, 404, 'MULTIPART_UPLOAD_NOT_FOUND', 'Multipart upload was not found');
  if (upload.status !== 'completed') return apiError(c, 409, 'MULTIPART_UPLOAD_NOT_COMPLETE', 'Multipart upload has not completed');
  if (body.sha256?.toLowerCase() !== upload.blob_sha256 || body.byteSize !== upload.byte_size) {
    return apiError(c, 422, 'CLIENT_VERIFICATION_MISMATCH', 'Client verification does not match the immutable blob');
  }
  const object = await c.env.BLOBS.head(upload.r2_key);
  if (!object || object.size !== upload.byte_size || object.httpMetadata?.contentType !== upload.media_type) {
    return apiError(c, 422, 'MULTIPART_OBJECT_MISMATCH', 'Stored object no longer matches its immutable metadata');
  }
  await c.env.DB.prepare("UPDATE blobs SET upload_state = 'verified' WHERE sha256 = ?").bind(upload.blob_sha256).run();
  return c.json({ status: 'verified', blobId: upload.blob_sha256, size: upload.byte_size });
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
