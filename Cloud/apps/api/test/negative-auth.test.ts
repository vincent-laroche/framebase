import { Jwt } from 'hono/utils/jwt';
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { createTestEnv } from './testEnv.js';

const PROTECTED_REQUESTS: Array<[string, RequestInit]> = [
  ['/v1/changes', { method: 'GET' }],
  ['/v1/catalog/bootstrap', { method: 'GET' }],
  ['/v1/capabilities', { method: 'GET' }],
  [
    '/v1/mutations',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ clientMutationId: 'x', actorId: 'x', operations: [] })
    }
  ],
  [
    '/v1/blobs/upload-initiate',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sha256: 'a'.repeat(64), byteSize: 1, mediaType: 'image/jpeg', originalExtension: 'jpg' })
    }
  ],
  ['/v1/blobs/nonexistent/download', { method: 'GET' }],
  ['/v1/assets/nonexistent/variants/grid-256', { method: 'GET' }],
  [
    '/v1/auth/enroll',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ deviceId: 'x', deviceName: 'x', publicKey: 'x' })
    }
  ],
  ['/v1/agents', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'x', scopes: ['library.read'] }) }],
  ['/v1/agents/agent-1/revoke', { method: 'POST' }],
  ['/v1/agent-operations/tag-proposals', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ tagId: 'tag-1', targetAssetIds: ['asset-1'], catalogRevision: 0 }) }],
  ['/v1/agent-operations/operation-1/approve', { method: 'POST' }],
  ['/v1/agent-operations/operation-1/apply', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ approvalToken: 'x'.repeat(32) }) }],
  ['/v1/agent-operations/operation-1', { method: 'GET' }]
];

describe('negative auth', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it.each(PROTECTED_REQUESTS)('rejects %s with 401 when no bearer token is present', async (path, init) => {
    const res = await app.request(path, init, env);
    expect(res.status).toBe(401);
  });

  it('rejects a malformed or invalid bearer token with 401', async () => {
    const res = await app.request(
      '/v1/changes',
      { headers: { Authorization: 'Bearer not-a-real-token' } },
      env
    );
    expect(res.status).toBe(401);
  });

  it('rejects a token for a device that was never enrolled', async () => {
    const forgedToken = await Jwt.sign(
      { sub: 'never-enrolled-device', scopes: ['library.read'], iat: 0, exp: Math.floor(Date.now() / 1000) + 3600 },
      env.JWT_SECRET as string,
      'HS256'
    );

    const res = await app.request(
      '/v1/changes',
      { headers: { Authorization: `Bearer ${forgedToken}` } },
      env
    );
    expect(res.status).toBe(401);
  });

  it('rejects an expired token and a revoked enrolled device', async () => {
    const expired = await Jwt.sign(
      { sub: 'expired-device', scopes: ['library.read'], iat: 0, exp: 1 },
      env.JWT_SECRET as string,
      'HS256'
    );
    expect((await app.request('/v1/changes', { headers: { Authorization: `Bearer ${expired}` } }, env)).status).toBe(401);

    await env.DB.prepare(
      "INSERT INTO devices (id, device_name, public_key, scopes, status) VALUES (?, ?, ?, ?, 'revoked')"
    ).bind('revoked-device', 'revoked', 'key', JSON.stringify(['library.read'])).run();
    const revoked = await Jwt.sign(
      { sub: 'revoked-device', scopes: ['library.read'], iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 3600 },
      env.JWT_SECRET as string,
      'HS256'
    );
    expect((await app.request('/v1/changes', { headers: { Authorization: `Bearer ${revoked}` } }, env)).status).toBe(401);
  });

  it('does not emit permissive browser CORS headers', async () => {
    const response = await app.request('/v1/health', { headers: { Origin: 'https://untrusted.example' } }, env);
    expect(response.headers.get('Access-Control-Allow-Origin')).toBeNull();
  });
});
