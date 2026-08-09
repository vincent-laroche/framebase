import { Jwt } from 'hono/utils/jwt';
import type { MiddlewareHandler } from 'hono';
import type { AppEnv } from '../types.js';

export interface DeviceClaims {
  sub: string;
  scopes: string[];
  exp: number;
  iat: number;
}

export function requireAuth(...requiredScopes: string[]): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const secret = c.env.JWT_SECRET;
    if (!secret) {
      return c.json(
        { error: { code: 'SERVER_MISCONFIGURED', message: 'JWT_SECRET is not configured' } },
        500
      );
    }

    const authHeader = c.req.header('Authorization');
    const token = authHeader?.startsWith('Bearer ') ? authHeader.slice('Bearer '.length).trim() : '';
    if (!token) {
      return c.json({ error: { code: 'UNAUTHORIZED', message: 'Missing bearer token' } }, 401);
    }

    let claims: DeviceClaims;
    try {
      claims = (await Jwt.verify(token, secret, 'HS256')) as unknown as DeviceClaims;
    } catch {
      return c.json({ error: { code: 'UNAUTHORIZED', message: 'Invalid or expired token' } }, 401);
    }

    if (typeof claims.sub !== 'string' || !claims.sub) {
      return c.json({ error: { code: 'UNAUTHORIZED', message: 'Token is missing a device id' } }, 401);
    }

    const device = await c.env.DB.prepare('SELECT status, scopes FROM devices WHERE id = ?')
      .bind(claims.sub)
      .first<{ status: string; scopes: string }>();

    if (!device || device.status !== 'active') {
      return c.json({ error: { code: 'UNAUTHORIZED', message: 'Device is not enrolled or has been revoked' } }, 401);
    }

    const deviceScopes: string[] = JSON.parse(device.scopes);
    const missing = requiredScopes.filter((scope) => !deviceScopes.includes(scope));
    if (missing.length > 0) {
      return c.json(
        { error: { code: 'FORBIDDEN', message: `Missing required scope(s): ${missing.join(', ')}` } },
        403
      );
    }

    c.set('deviceId', claims.sub);
    c.set('scopes', deviceScopes);
    await next();
  };
}
