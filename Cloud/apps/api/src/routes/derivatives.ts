import { Hono } from 'hono';
import { apiError } from '../lib/api.js';
import { requireAuth } from '../middleware/auth.js';
import type { AppEnv } from '../types.js';

export const derivativesRouter = new Hono<AppEnv>();

const VARIANTS = {
  'grid-256': 256,
  'grid-512': 512,
  'preview-1600': 1600
} as const;
const IMAGES_INPUT_MAX_BYTES = 20 * 1024 * 1024;

derivativesRouter.get('/assets/:id/variants/:variant', requireAuth('library.read'), async (c) => {
  const assetID = c.req.param('id').toLowerCase();
  const variant = c.req.param('variant') as keyof typeof VARIANTS;
  const width = VARIANTS[variant];
  if (!width) return apiError(c, 404, 'DERIVATIVE_VARIANT_NOT_FOUND', 'Unknown derivative variant');
  if (!c.env.IMAGES) return apiError(c, 503, 'DERIVATIVE_SERVICE_UNAVAILABLE', 'Cloud image transformations are not configured');

  const asset = await c.env.DB.prepare(
    `SELECT blobs.sha256, blobs.r2_key, blobs.byte_size, blobs.upload_state
     FROM assets JOIN blobs ON blobs.id = assets.blob_id WHERE assets.id = ?`
  ).bind(assetID).first<{ sha256: string; r2_key: string; byte_size: number; upload_state: string }>();
  if (!asset || asset.upload_state !== 'verified') return apiError(c, 404, 'ASSET_NOT_FOUND', 'Verified asset was not found');
  if (asset.byte_size > IMAGES_INPUT_MAX_BYTES) {
    return apiError(c, 422, 'DERIVATIVE_SOURCE_TOO_LARGE', 'This original must be materialized locally before rendering a derivative');
  }

  const derivativeKey = `derivatives/sha256/${asset.sha256}/${variant}.webp`;
  const cached = await c.env.BLOBS.get(derivativeKey);
  if (cached?.body) return derivativeResponse(cached.body, 'HIT');

  const original = await c.env.BLOBS.get(asset.r2_key);
  if (!original?.body) return apiError(c, 404, 'R2_OBJECT_MISSING', 'Verified original object is missing');
  try {
    const transformed = await c.env.IMAGES.input(original.body)
      .transform({ width, height: width, fit: 'scale-down' })
      .output({ format: 'image/webp', quality: 82 });
    const body = transformed.image();
    await c.env.BLOBS.put(derivativeKey, body, {
      httpMetadata: { contentType: 'image/webp', cacheControl: 'private, max-age=86400' }
    });
    return derivativeResponse(body, 'MISS');
  } catch {
    return apiError(c, 422, 'DERIVATIVE_GENERATION_FAILED', 'Cloud image transformation failed');
  }
});

function derivativeResponse(body: ReadableStream<Uint8Array>, cache: 'HIT' | 'MISS'): Response {
  return new Response(body, {
    headers: {
      'Content-Type': 'image/webp',
      'Cache-Control': 'private, max-age=86400',
      'X-Framebase-Derivative-Cache': cache
    }
  });
}
