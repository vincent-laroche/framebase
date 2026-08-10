import { Jwt } from 'hono/utils/jwt';
import type { MiddlewareHandler } from 'hono';
import type { AppEnv } from '../types.js';
import { apiError } from '../lib/api.js';

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
      return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Authentication is not configured');
    }

    const authHeader = c.req.header('Authorization');
    const token = authHeader?.startsWith('Bearer ') ? authHeader.slice('Bearer '.length).trim() : '';
    if (!token) {
      return apiError(c, 401, 'UNAUTHORIZED', 'Missing bearer token');
    }

    let claims: DeviceClaims;
    try {
      claims = (await Jwt.verify(token, secret, 'HS256')) as unknown as DeviceClaims;
    } catch {
      return apiError(c, 401, 'UNAUTHORIZED', 'Invalid or expired token');
    }

    if (typeof claims.sub !== 'string' || !claims.sub) {
      return apiError(c, 401, 'UNAUTHORIZED', 'Invalid device token');
    }

    const device = await c.env.DB.prepare('SELECT status, scopes FROM devices WHERE id = ?')
      .bind(claims.sub)
      .first<{ status: string; scopes: string }>();

    if (!device || device.status !== 'active') {
      return apiError(c, 401, 'UNAUTHORIZED', 'Device is not enrolled or has been revoked');
    }

    const deviceScopes: string[] = JSON.parse(device.scopes);
    const missing = requiredScopes.filter((scope) => !deviceScopes.includes(scope));
    if (missing.length > 0) {
      return apiError(c, 403, 'FORBIDDEN', `Missing required scope(s): ${missing.join(', ')}`);
    }

    c.set('deviceId', claims.sub);
    c.set('scopes', deviceScopes);
    await next();
  };
}
