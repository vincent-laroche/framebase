import { Hono } from 'hono';
import { Jwt } from 'hono/utils/jwt';
import type { Context } from 'hono';
import type { AppEnv } from '../types.js';
import { apiError } from '../lib/api.js';

export const authRouter = new Hono<AppEnv>();

const SESSION_LIFETIME_SECONDS = 3600;

const DEFAULT_SCOPES = [
  'library.read',
  'assets.import',
  'assets.metadata.write',
  'assets.organize',
  'library.preferences.write',
  'originals.download',
  'trash.write'
];

// purge.approve is deliberately absent: excluded from every device's scopes in Phase 2.
const GRANTABLE_SCOPES = new Set(DEFAULT_SCOPES);
const WINDOW_MS = 10 * 60 * 1000;
const MAX_ENROLLMENTS_PER_WINDOW = 10;
const CHALLENGE_LIFETIME_SECONDS = 5 * 60;
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

interface EnrollmentFields {
  deviceId?: string;
  deviceName?: string;
  publicKey?: string;
  scopes?: string[];
}

function validEnrollmentFields(body: EnrollmentFields): body is Required<Pick<EnrollmentFields, 'deviceId' | 'deviceName' | 'publicKey'>> & EnrollmentFields {
  return Boolean(
    body.deviceId && /^[a-zA-Z0-9_-]{3,128}$/.test(body.deviceId) &&
    body.deviceName && body.deviceName.length <= 120 &&
    body.publicKey && body.publicKey.length <= 16_384 &&
    (body.scopes === undefined || (Array.isArray(body.scopes) && body.scopes.every((scope) => typeof scope === 'string')))
  );
}

function requestedScopes(body: EnrollmentFields): { scopes: string[] } | { error: string } {
  const scopes = body.scopes ?? DEFAULT_SCOPES;
  const ungrantable = scopes.filter((scope) => !GRANTABLE_SCOPES.has(scope));
  return ungrantable.length > 0 || new Set(scopes).size !== scopes.length
    ? { error: 'Requested scope is not grantable' }
    : { scopes };
}

function enrollmentCredentialValid(c: Context<AppEnv>): boolean {
  const credential = c.req.header('X-Pairing-Credential') ?? c.req.header('X-Enrollment-Secret');
  return Boolean(c.env.ENROLLMENT_SECRET && credential && credential === c.env.ENROLLMENT_SECRET);
}

async function issueSession(c: Context<AppEnv>, deviceId: string, scopes: string[]) {
  if (!c.env.JWT_SECRET) return null;
  const nowSeconds = Math.floor(Date.now() / 1000);
  const expiresAtSeconds = nowSeconds + SESSION_LIFETIME_SECONDS;
  const token = await Jwt.sign(
    { sub: deviceId, scopes, iat: nowSeconds, exp: expiresAtSeconds },
    c.env.JWT_SECRET,
    'HS256'
  );
  return { token, expiresAt: new Date(expiresAtSeconds * 1000).toISOString() };
}

function randomBase64URL(byteLength: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

function base64URLBytes(value: string): Uint8Array | null {
  try {
    const normalized = value.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - value.length % 4) % 4);
    return Uint8Array.from(atob(normalized), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

async function verifyEnrollmentSignature(publicKey: string, payload: string, signature: string): Promise<boolean> {
  const keyBytes = base64URLBytes(publicKey);
  const signatureBytes = base64URLBytes(signature);
  if (!keyBytes || !signatureBytes) return false;
  try {
    const key = await crypto.subtle.importKey('spki', keyBytes, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, signatureBytes, new TextEncoder().encode(payload));
  } catch {
    return false;
  }
}

authRouter.post('/auth/enroll/challenge', async (c) => {
  const requestIdentity = c.req.header('CF-Connecting-IP') ?? c.req.header('X-Forwarded-For') ?? 'unknown';
  if (!enrollmentAllowed(requestIdentity)) return apiError(c, 429, 'ENROLLMENT_RATE_LIMITED', 'Try enrollment again later');
  if (!enrollmentCredentialValid(c)) return apiError(c, 401, 'UNAUTHORIZED', 'Invalid or missing pairing credential');
  let body: EnrollmentFields;
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  if (!validEnrollmentFields(body)) return apiError(c, 400, 'INVALID_REQUEST', 'Invalid device enrollment fields');
  const scopeResult = requestedScopes(body);
  if ('error' in scopeResult) return apiError(c, 400, 'INVALID_SCOPE', scopeResult.error);

  const challengeID = randomBase64URL(18);
  const challenge = randomBase64URL(32);
  const expiresAt = new Date(Date.now() + CHALLENGE_LIFETIME_SECONDS * 1000).toISOString();
  await c.env.DB.prepare('DELETE FROM device_enrollment_challenges WHERE datetime(expires_at) < datetime(\'now\') OR used_at IS NOT NULL').run();
  await c.env.DB.prepare(
    `INSERT INTO device_enrollment_challenges (id, device_id, device_name, public_key, scopes, challenge, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).bind(challengeID, body.deviceId, body.deviceName, body.publicKey, JSON.stringify(scopeResult.scopes), challenge, expiresAt).run();
  return c.json({ challengeId: challengeID, challenge, expiresAt });
});

authRouter.post('/auth/enroll/complete', async (c) => {
  let body: { challengeId?: string; signature?: string };
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  if (!body.challengeId || !body.signature || body.challengeId.length > 128 || body.signature.length > 1024) {
    return apiError(c, 400, 'INVALID_REQUEST', 'challengeId and signature are required');
  }
  const challenge = await c.env.DB.prepare(
    `SELECT device_id, device_name, public_key, scopes, challenge, expires_at FROM device_enrollment_challenges
     WHERE id = ? AND used_at IS NULL AND datetime(expires_at) > datetime('now')`
  ).bind(body.challengeId).first<{ device_id: string; device_name: string; public_key: string; scopes: string; challenge: string; expires_at: string }>();
  if (!challenge) return apiError(c, 404, 'ENROLLMENT_CHALLENGE_EXPIRED', 'Enrollment challenge is invalid or expired');
  const payload = `${body.challengeId}.${challenge.device_id}.${challenge.challenge}`;
  if (!(await verifyEnrollmentSignature(challenge.public_key, payload, body.signature))) {
    return apiError(c, 401, 'ENROLLMENT_PROOF_INVALID', 'Device signature did not verify');
  }
  const scopes = JSON.parse(challenge.scopes) as string[];
  const issued = await issueSession(c, challenge.device_id, scopes);
  if (!issued) return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Authentication is not configured');
  await c.env.DB.batch([
    c.env.DB.prepare(
      `INSERT INTO devices (id, device_name, public_key, scopes, status)
       VALUES (?, ?, ?, ?, 'active')
       ON CONFLICT(id) DO UPDATE SET device_name = excluded.device_name, public_key = excluded.public_key,
       scopes = excluded.scopes, status = 'active', revoked_at = NULL`
    ).bind(challenge.device_id, challenge.device_name, challenge.public_key, challenge.scopes),
    c.env.DB.prepare('UPDATE device_enrollment_challenges SET used_at = datetime(\'now\') WHERE id = ?').bind(body.challengeId)
  ]);
  return c.json({ status: 'enrolled', deviceId: challenge.device_id, scopes, token: issued.token, expiresAt: issued.expiresAt });
});

authRouter.post('/auth/enroll', async (c) => {
  const requestIdentity = c.req.header('CF-Connecting-IP') ?? c.req.header('X-Forwarded-For') ?? 'unknown';
  if (!enrollmentAllowed(requestIdentity)) {
    return apiError(c, 429, 'ENROLLMENT_RATE_LIMITED', 'Try enrollment again later');
  }

  if (!enrollmentCredentialValid(c)) {
    return apiError(c, 401, 'UNAUTHORIZED', 'Invalid or missing enrollment secret');
  }

  let body: { deviceId?: string; deviceName?: string; publicKey?: string; scopes?: string[] };
  try {
    body = await c.req.json();
  } catch {
    return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON');
  }

  if (!validEnrollmentFields(body)) {
    return apiError(c, 400, 'INVALID_REQUEST', 'Invalid device enrollment fields');
  }

  const scopeResult = requestedScopes(body);
  if ('error' in scopeResult) {
    return apiError(c, 400, 'INVALID_SCOPE', 'Requested scope is not grantable in Phase 2');
  }
  const grantableScopes = scopeResult.scopes;

  const scopesJson = JSON.stringify(grantableScopes);

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

  const issued = await issueSession(c, body.deviceId, grantableScopes);
  if (!issued) return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Authentication is not configured');

  return c.json({
    status: 'enrolled',
    deviceId: body.deviceId,
    scopes: grantableScopes,
    token: issued.token,
    expiresAt: issued.expiresAt
  });
});

authRouter.post('/auth/revoke', async (c) => {
  if (!enrollmentCredentialValid(c)) {
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
