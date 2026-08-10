import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

async function sha256(bytes: Uint8Array): Promise<string> {
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
    const bytes = new TextEncoder().encode('fixture-bytes');
    const digest = await sha256(bytes);

    const initiate = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength, mediaType: 'image/jpeg', originalExtension: 'jpg' })
      },
      env
    );
    expect(initiate.status).toBe(200);

    const complete = await app.request(
      '/v1/blobs/upload-complete',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength })
      },
      env
    );
    expect(complete.status).toBe(422);
  });

  it('issues a signed direct capability, verifies byte identity, and only then grants download', async () => {
    const token = await enrollDevice(env, 'device-blobs-2', ['assets.import', 'originals.download']);
    const bytes = new TextEncoder().encode('fixture-bytes');
    const digest = await sha256(bytes);

    const initiate = await app.request(
      '/v1/blobs/upload-initiate',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength, mediaType: 'image/jpeg', originalExtension: 'jpg' })
      },
      env
    );
    expect(initiate.status).toBe(200);
    const initiated = await initiate.json<{ upload: { url: string; method: string; requiredHeaders: Record<string, string> } }>();
    expect(initiated.upload.method).toBe('PUT');
    expect(initiated.upload.url).toContain('X-Amz-Signature=');
    expect(initiated.upload.requiredHeaders['Content-Type']).toBe('image/jpeg');

    const row = await env.DB.prepare('SELECT r2_key FROM blobs WHERE sha256 = ?').bind(digest).first<{ r2_key: string }>();
    await env.BLOBS.put(row!.r2_key, bytes, { httpMetadata: { contentType: 'image/jpeg' } });

    const complete = await app.request(
      '/v1/blobs/upload-complete',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength })
      },
      env
    );
    expect(complete.status).toBe(200);

    const download = await app.request(
      `/v1/blobs/${digest}/download`,
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );
    expect(download.status).toBe(200);
    const downloaded = await download.json<{ download: { url: string; method: string } }>();
    expect(downloaded.download.method).toBe('GET');
    expect(downloaded.download.url).toContain('X-Amz-Signature=');
  });

  it('deletes a mismatched object and marks its blob abandoned', async () => {
    const token = await enrollDevice(env, 'device-blobs-3', ['assets.import']);
    const expected = new TextEncoder().encode('expected-bytes');
    const digest = await sha256(expected);
    await app.request('/v1/blobs/upload-initiate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: expected.byteLength, mediaType: 'image/png', originalExtension: 'png' })
    }, env);
    const row = await env.DB.prepare('SELECT r2_key FROM blobs WHERE sha256 = ?').bind(digest).first<{ r2_key: string }>();
    await env.BLOBS.put(row!.r2_key, new TextEncoder().encode('wrong-bytes'));

    const complete = await app.request('/v1/blobs/upload-complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: expected.byteLength })
    }, env);
    expect(complete.status).toBe(422);
    const state = await env.DB.prepare('SELECT upload_state FROM blobs WHERE sha256 = ?').bind(digest)
      .first<{ upload_state: string }>();
    expect(state?.upload_state).toBe('abandoned');
    expect(await env.BLOBS.head(row!.r2_key)).toBeNull();
  });

  it('rejects an object whose stored content type differs from its signed intent', async () => {
    const token = await enrollDevice(env, 'device-blobs-4', ['assets.import']);
    const bytes = new TextEncoder().encode('content-type-fixture');
    const digest = await sha256(bytes);
    await app.request('/v1/blobs/upload-initiate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength, mediaType: 'image/png', originalExtension: 'png' })
    }, env);
    const row = await env.DB.prepare('SELECT r2_key FROM blobs WHERE sha256 = ?').bind(digest).first<{ r2_key: string }>();
    await env.BLOBS.put(row!.r2_key, bytes, { httpMetadata: { contentType: 'image/jpeg' } });

    const complete = await app.request('/v1/blobs/upload-complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength })
    }, env);
    expect(complete.status).toBe(422);
  });
});
