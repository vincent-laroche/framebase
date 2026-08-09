import { Hono } from 'hono';
import { Jwt } from 'hono/utils/jwt';
import type { AppEnv } from '../types.js';

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

authRouter.post('/auth/enroll', async (c) => {
  const enrollmentSecret = c.req.header('X-Enrollment-Secret');
  if (!c.env.ENROLLMENT_SECRET || enrollmentSecret !== c.env.ENROLLMENT_SECRET) {
    return c.json({ error: { code: 'UNAUTHORIZED', message: 'Invalid or missing enrollment secret' } }, 401);
  }

  const body = await c.req.json<{
    deviceId: string;
    deviceName: string;
    publicKey: string;
    scopes?: string[];
  }>();

  if (!body.deviceId || !body.deviceName || !body.publicKey) {
    return c.json(
      { error: { code: 'INVALID_REQUEST', message: 'deviceId, deviceName, and publicKey are required' } },
      400
    );
  }

  if (!c.env.JWT_SECRET) {
    return c.json(
      { error: { code: 'SERVER_MISCONFIGURED', message: 'JWT_SECRET is not configured' } },
      500
    );
  }

  const requestedScopes = body.scopes || DEFAULT_SCOPES;
  const ungrantable = requestedScopes.filter((scope) => !GRANTABLE_SCOPES.has(scope));
  if (ungrantable.length > 0) {
    return c.json(
      { error: { code: 'INVALID_SCOPE', message: `Not grantable in Phase 2: ${ungrantable.join(', ')}` } },
      400
    );
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
