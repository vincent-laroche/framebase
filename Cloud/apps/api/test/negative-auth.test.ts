import { Jwt } from 'hono/utils/jwt';
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { createTestEnv } from './testEnv.js';

const PROTECTED_REQUESTS: Array<[string, RequestInit]> = [
  ['/v1/changes', { method: 'GET' }],
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
  ['/v1/blobs/nonexistent/download', { method: 'GET' }]
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
});
