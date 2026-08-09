import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

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

  it('marks a blob verified once its bytes exist in R2, then serves it back with matching content', async () => {
    const token = await enrollDevice(env, 'device-blobs-2', ['assets.import', 'originals.download']);
    const sha256 = 'c'.repeat(64);
    const bytes = new TextEncoder().encode('fixture-bytes');

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
