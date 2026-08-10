import { Hono } from 'hono';
import { Jwt } from 'hono/utils/jwt';
import type { AppEnv } from '../types.js';
import { apiError } from '../lib/api.js';

export const authRouter = new Hono<AppEnv>();

const SESSION_LIFETIME_SECONDS = 3600;

const DEFAULT_SCOPES = [
  'library.read',
  'assets.import',
  'assets.metadata.write',
  'assets.organize',
  'originals.download',
  'trash.write'
];

// purge.approve is deliberately absent: excluded from every device's scopes in Phase 2.
const GRANTABLE_SCOPES = new Set(DEFAULT_SCOPES);
const WINDOW_MS = 10 * 60 * 1000;
const MAX_ENROLLMENTS_PER_WINDOW = 10;
const enrollmentAttempts = new Map<string, number[]>();

function enrollmentAllowed(identity: string): boolean {
  const now = Date.now();
  const attempts = (enrollmentAttempts.get(identity) ?? []).filter((value) => value > now - WINDOW_MS);
  if (attempts.length >= MAX_ENROLLMENTS_PER_WINDOW) {
    enrollmentAttempts.set(identity, attempts);
    return false;
  }
  attempts.push(now);
  enrollmentAttempts.set(identity, attempts);
  return true;
}

authRouter.post('/auth/enroll', async (c) => {
  const requestIdentity = c.req.header('CF-Connecting-IP') ?? c.req.header('X-Forwarded-For') ?? 'unknown';
  if (!enrollmentAllowed(requestIdentity)) {
    return apiError(c, 429, 'ENROLLMENT_RATE_LIMITED', 'Try enrollment again later');
  }

  const enrollmentSecret = c.req.header('X-Enrollment-Secret');
  if (!c.env.ENROLLMENT_SECRET || enrollmentSecret !== c.env.ENROLLMENT_SECRET) {
    return apiError(c, 401, 'UNAUTHORIZED', 'Invalid or missing enrollment secret');
  }

  let body: { deviceId?: string; deviceName?: string; publicKey?: string; scopes?: string[] };
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }

  if (
    !body.deviceId ||
    !/^[a-zA-Z0-9_-]{3,128}$/.test(body.deviceId) ||
    !body.deviceName ||
    body.deviceName.length > 120 ||
    !body.publicKey ||
    body.publicKey.length > 16_384 ||
    (body.scopes !== undefined && (!Array.isArray(body.scopes) || body.scopes.some((scope) => typeof scope !== 'string')))
  ) {
    return apiError(c, 400, 'INVALID_REQUEST', 'Invalid device enrollment fields');
  }

  if (!c.env.JWT_SECRET) {
    return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Authentication is not configured');
  }

  const requestedScopes = body.scopes ?? DEFAULT_SCOPES;
  const ungrantable = requestedScopes.filter((scope) => !GRANTABLE_SCOPES.has(scope));
  if (ungrantable.length > 0 || new Set(requestedScopes).size !== requestedScopes.length) {
    return apiError(c, 400, 'INVALID_SCOPE', 'Requested scope is not grantable in Phase 2');
  }

  const scopesJson = JSON.stringify(requestedScopes);

  await c.env.DB.prepare(
    `INSERT INTO devices (id, device_name, public_key, scopes, status)
     VALUES (?, ?, ?, ?, 'active')
     ON CONFLICT(id) DO UPDATE SET
       device_name = excluded.device_name,
       public_key = excluded.public_key,
       scopes = excluded.scopes,
       status = 'active',
       revoked_at = NULL`
  )
    .bind(body.deviceId, body.deviceName, body.publicKey, scopesJson)
    .run();

  const nowSeconds = Math.floor(Date.now() / 1000);
  const expiresAtSeconds = nowSeconds + SESSION_LIFETIME_SECONDS;
  const sessionToken = await Jwt.sign(
    { sub: body.deviceId, scopes: requestedScopes, iat: nowSeconds, exp: expiresAtSeconds },
    c.env.JWT_SECRET,
    'HS256'
  );

  return c.json({
    status: 'enrolled',
    deviceId: body.deviceId,
    scopes: requestedScopes,
    token: sessionToken,
    expiresAt: new Date(expiresAtSeconds * 1000).toISOString()
  });
});

authRouter.post('/auth/revoke', async (c) => {
  const enrollmentSecret = c.req.header('X-Enrollment-Secret');
  if (!c.env.ENROLLMENT_SECRET || enrollmentSecret !== c.env.ENROLLMENT_SECRET) {
    return apiError(c, 401, 'UNAUTHORIZED', 'Invalid or missing enrollment secret');
  }
  let body: { deviceId?: string };
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }
  if (!body.deviceId || !/^[a-zA-Z0-9_-]{3,128}$/.test(body.deviceId)) {
    return apiError(c, 400, 'INVALID_REQUEST', 'deviceId is invalid');
  }

  const result = await c.env.DB.prepare(
    "UPDATE devices SET status = 'revoked', revoked_at = datetime('now') WHERE id = ? AND status = 'active'"
  )
    .bind(body.deviceId)
    .run();
  if (result.meta.changes === 0) return apiError(c, 404, 'DEVICE_NOT_FOUND', 'Active device was not found');
  return c.json({ status: 'revoked', deviceId: body.deviceId });
});
