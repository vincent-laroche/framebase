import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

describe('blob upload verification', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('rejects upload-complete when no bytes were ever written to R2', async () => {
    const token = await enrollDevice(env, 'device-blobs', ['assets.import']);
    const sha256 = 'b'.repeat(64);

    const initiate = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256, byteSize: 4, mediaType: 'image/jpeg', originalExtension: 'jpg' })
      },
      env
    );
    expect(initiate.status).toBe(200);

    const complete = await app.request(
      '/v1/blobs/upload-complete',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256, byteSize: 4 })
      },
      env
    );
    expect(complete.status).toBe(400);
  });

  it('rejects a malformed SHA-256 before creating a pending blob', async () => {
    const token = await enrollDevice(env, 'device-invalid-sha', ['assets.import']);

    const res = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          sha256: 'not-a-sha256',
          byteSize: 10,
          mediaType: 'image/jpeg',
          originalExtension: 'jpg'
        })
      },
      env
    );

    expect(res.status).toBe(400);
    const { results } = await env.DB.prepare('SELECT COUNT(*) as count FROM blobs').all<{ count: number }>();
    expect(results[0].count).toBe(0);
  });

  it('rejects a direct upload addressed to an arbitrary R2 key', async () => {
    const token = await enrollDevice(env, 'device-arbitrary-key', ['assets.import']);

    const res = await app.request(
      '/v1/blobs/upload-direct?key=blobs/other-library/unregistered.jpg',
      {
        method: 'PUT',
        headers: { Authorization: `Bearer ${token}` },
        body: new TextEncoder().encode('fixture-bytes')
      },
      env
    );

    expect(res.status).toBe(400);
  });

  it('rejects uploaded bytes whose digest differs from the registered blob', async () => {
    const token = await enrollDevice(env, 'device-digest-mismatch', ['assets.import']);
    const declaredBytes = new TextEncoder().encode('expected-fixture-bytes');
    const uploadedBytes = new TextEncoder().encode('different-fixture-bytes');
    const sha256 = await sha256Hex(declaredBytes);

    const initiate = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          sha256,
          byteSize: declaredBytes.byteLength,
          mediaType: 'image/jpeg',
          originalExtension: 'jpg'
        })
      },
      env
    );
    const { uploadUrl } = await initiate.json<{ uploadUrl: string }>();

    const upload = await app.request(
      uploadUrl,
      { method: 'PUT', headers: { Authorization: `Bearer ${token}` }, body: uploadedBytes },
      env
    );

    expect(upload.status).toBe(409);
  });

  it('rejects completion when its declared size differs from the registered verified bytes', async () => {
    const token = await enrollDevice(env, 'device-complete-size-mismatch', ['assets.import']);
    const bytes = new TextEncoder().encode('fixture-bytes');
    const sha256 = await sha256Hex(bytes);

    const initiate = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256, byteSize: bytes.byteLength, mediaType: 'image/jpeg', originalExtension: 'jpg' })
      },
      env
    );
    const { uploadUrl } = await initiate.json<{ uploadUrl: string }>();
    await app.request(uploadUrl, { method: 'PUT', headers: { Authorization: `Bearer ${token}` }, body: bytes }, env);

    const complete = await app.request(
      '/v1/blobs/upload-complete',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256, byteSize: bytes.byteLength + 1 })
      },
      env
    );

    expect(complete.status).toBe(409);
  });

  it('marks a blob verified once its bytes exist in R2, then serves it back with matching content', async () => {
    const token = await enrollDevice(env, 'device-blobs-2', ['assets.import', 'originals.download']);
    const bytes = new TextEncoder().encode('fixture-bytes');
    const sha256 = await sha256Hex(bytes);

    const initiate = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          sha256,
          byteSize: bytes.byteLength,
          mediaType: 'image/jpeg',
          originalExtension: 'jpg'
        })
      },
      env
    );
    const { uploadUrl } = await initiate.json<{ uploadUrl: string }>();

    const uploadRes = await app.request(
      uploadUrl,
      { method: 'PUT', headers: { Authorization: `Bearer ${token}` }, body: bytes },
      env
    );
    expect(uploadRes.status).toBe(200);

    const complete = await app.request(
      '/v1/blobs/upload-complete',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256, byteSize: bytes.byteLength })
      },
      env
    );
    expect(complete.status).toBe(200);

    const download = await app.request(
      `/v1/blobs/${sha256}/download`,
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    expect(download.status).toBe(200);
    expect(await download.text()).toBe('fixture-bytes');
  });
});
