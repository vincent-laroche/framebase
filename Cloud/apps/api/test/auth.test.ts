import { Jwt } from 'hono/utils/jwt';
import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { createTestEnv } from './testEnv.js';

describe('POST /v1/auth/enroll', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('rejects enrollment without the enrollment secret', async () => {
    const res = await app.request(
      '/v1/auth/enroll',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ deviceId: 'device-0', deviceName: 'x', publicKey: 'x' })
      },
      env
    );
    expect(res.status).toBe(401);
  });

  it('rejects enrollment with the wrong enrollment secret', async () => {
    const res = await app.request(
      '/v1/auth/enroll',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Enrollment-Secret': 'wrong' },
        body: JSON.stringify({ deviceId: 'device-0', deviceName: 'x', publicKey: 'x' })
      },
      env
    );
    expect(res.status).toBe(401);
  });

  it('registers a device and issues a signed, scoped bearer token', async () => {
    const res = await app.request(
      '/v1/auth/enroll',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Enrollment-Secret': env.ENROLLMENT_SECRET as string
        },
        body: JSON.stringify({
          deviceId: 'device-1',
          deviceName: "Vincent's Mac",
          publicKey: 'test-public-key'
        })
      },
      env
    );

    expect(res.status).toBe(200);
    const body = await res.json<{ token: string; scopes: string[]; deviceId: string }>();
    expect(body.deviceId).toBe('device-1');
    expect(body.scopes).toContain('library.read');

    const claims = await Jwt.verify(body.token, env.JWT_SECRET as string, 'HS256');
    expect(claims.sub).toBe('device-1');
    expect(claims.scopes).toEqual(body.scopes);
    expect(typeof claims.exp).toBe('number');
  });

  it('rejects enrollment missing required fields', async () => {
    const res = await app.request(
      '/v1/auth/enroll',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Enrollment-Secret': env.ENROLLMENT_SECRET as string
        },
        body: JSON.stringify({ deviceId: 'device-2' })
      },
      env
    );

    expect(res.status).toBe(400);
  });

  it('rejects a request for a scope that is never grantable in Phase 2', async () => {
    const res = await app.request(
      '/v1/auth/enroll',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Enrollment-Secret': env.ENROLLMENT_SECRET as string
        },
        body: JSON.stringify({
          deviceId: 'device-3',
          deviceName: 'x',
          publicKey: 'x',
          scopes: ['library.read', 'purge.approve']
        })
      },
      env
    );

    expect(res.status).toBe(400);
  });
});
