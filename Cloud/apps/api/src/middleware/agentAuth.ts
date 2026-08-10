import type { MiddlewareHandler } from 'hono';
import { apiError, sha256Hex } from '../lib/api.js';
import type { AppEnv } from '../types.js';

const AGENT_CREDENTIAL = /^Agent ([A-Za-z0-9_-]{3,128})\.([A-Za-z0-9_-]{32,128})$/;

function constantTimeEqual(left: string, right: string): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function utf8Buffer(value: string): ArrayBuffer {
  const bytes = new TextEncoder().encode(value);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

/**
 * Authenticates an explicitly delegated remote agent. Credentials are a
 * one-time return value from the owner-device endpoint and the catalog stores
 * only their SHA-256 digest. This middleware intentionally does not accept a
 * device JWT, avoiding accidental scope inheritance by an agent.
 */
export function requireAgentAuth(...requiredScopes: string[]): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const match = c.req.header('Authorization')?.match(AGENT_CREDENTIAL);
    if (!match) return apiError(c, 401, 'UNAUTHORIZED', 'Missing or invalid agent credential');
    const [, agentId, secret] = match;
    const credentialHash = await sha256Hex(utf8Buffer(`${agentId}.${secret}`));
    const agent = await c.env.DB.prepare(
      'SELECT credential_hash, scopes_json, status FROM agent_identities WHERE id = ?'
    ).bind(agentId).first<{ credential_hash: string; scopes_json: string; status: string }>();
    if (!agent || agent.status !== 'active' || !constantTimeEqual(agent.credential_hash, credentialHash)) {
      return apiError(c, 401, 'UNAUTHORIZED', 'Agent identity is unavailable or revoked');
    }

    let scopes: string[];
    try {
      scopes = JSON.parse(agent.scopes_json);
    } catch {
      return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Agent scope record is invalid');
    }
    if (!Array.isArray(scopes) || scopes.some((scope) => typeof scope !== 'string')) {
      return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Agent scope record is invalid');
    }
    const missing = requiredScopes.filter((scope) => !scopes.includes(scope));
    if (missing.length > 0) return apiError(c, 403, 'FORBIDDEN', `Missing required scope(s): ${missing.join(', ')}`);

    c.set('agentId', agentId);
    c.set('agentScopes', scopes);
    await next();
  };
}
