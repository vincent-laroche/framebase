import { Jwt } from 'hono/utils/jwt';
import { webcrypto } from 'node:crypto';
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

  it('revokes an enrolled development device using the enrollment secret', async () => {
    const enrolled = await app.request('/v1/auth/enroll', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Enrollment-Secret': env.ENROLLMENT_SECRET as string },
      body: JSON.stringify({ deviceId: 'device-revoke', deviceName: 'Revocable', publicKey: 'test-key', scopes: ['library.read'] })
    }, env);
    expect(enrolled.status).toBe(200);

    const revoke = await app.request('/v1/auth/revoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Enrollment-Secret': env.ENROLLMENT_SECRET as string },
      body: JSON.stringify({ deviceId: 'device-revoke' })
    }, env);
    expect(revoke.status).toBe(200);

    const token = (await enrolled.json<{ token: string }>()).token;
    expect((await app.request('/v1/changes', { headers: { Authorization: `Bearer ${token}` } }, env)).status).toBe(401);
  });

  it('requires a P-256 device signature to complete a pairing challenge', async () => {
    const keys = await webcrypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const spki = await webcrypto.subtle.exportKey('spki', keys.publicKey);
    const publicKey = Buffer.from(spki).toString('base64url');
    const challengeResponse = await app.request('/v1/auth/enroll/challenge', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Pairing-Credential': env.ENROLLMENT_SECRET as string },
      body: JSON.stringify({ deviceId: 'keypair-device', deviceName: 'Keypair Mac', publicKey, scopes: ['library.read'] })
    }, env);
    expect(challengeResponse.status).toBe(200);
    const challenge = await challengeResponse.json<{ challengeId: string; challenge: string }>();
    const payload = new TextEncoder().encode(`${challenge.challengeId}.keypair-device.${challenge.challenge}`);
    const signature = await webcrypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, keys.privateKey, payload);
    const complete = await app.request('/v1/auth/enroll/complete', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ challengeId: challenge.challengeId, signature: Buffer.from(signature).toString('base64url') })
    }, env);
    expect(complete.status).toBe(200);
    expect((await complete.json<{ deviceId: string }>()).deviceId).toBe('keypair-device');
  });
});
