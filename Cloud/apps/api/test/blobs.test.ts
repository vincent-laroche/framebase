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

  it('resumes multipart parts, requires a local remote-byte verification, then releases the original', async () => {
    const token = await enrollDevice(env, 'device-multipart', ['assets.import', 'originals.download']);
    const partSize = 8 * 1024 * 1024;
    const bytes = new Uint8Array(partSize * 3 + 17);
    bytes.fill(7);
    const digest = await sha256(bytes);
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

    const initiated = await app.request('/v1/blobs/multipart/initiate', {
      method: 'POST', headers,
      body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength, mediaType: 'image/jpeg', originalExtension: 'jpg' })
    }, env);
    expect(initiated.status).toBe(200);
    const manifest = await initiated.json<{ uploadId: string; partByteSize: number; partCount: number }>();
    expect(manifest.partByteSize).toBe(partSize);
    expect(manifest.partCount).toBe(4);

    const resumed = await app.request('/v1/blobs/multipart/initiate', {
      method: 'POST', headers,
      body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength, mediaType: 'image/jpeg', originalExtension: 'jpg' })
    }, env);
    expect((await resumed.json<{ uploadId: string }>()).uploadId).toBe(manifest.uploadId);

    for (let partNumber = 1; partNumber <= manifest.partCount; partNumber += 1) {
      const offset = (partNumber - 1) * partSize;
      const end = Math.min(offset + partSize, bytes.byteLength);
      const uploaded = await app.request(`/v1/blobs/multipart/${manifest.uploadId}/parts/${partNumber}`, {
        method: 'PUT', headers: { Authorization: `Bearer ${token}` }, body: bytes.slice(offset, end)
      }, env);
      expect(uploaded.status).toBe(200);
    }

    const completed = await app.request(`/v1/blobs/multipart/${manifest.uploadId}/complete`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } }, env);
    expect(completed.status).toBe(200);
    expect((await completed.json<{ status: string }>()).status).toBe('awaiting_client_verification');
    expect((await app.request(`/v1/blobs/${digest}/download`, { headers: { Authorization: `Bearer ${token}` } }, env)).status).toBe(404);
    expect((await app.request(`/v1/blobs/${digest}/verification-download`, { headers: { Authorization: `Bearer ${token}` } }, env)).status).toBe(200);

    const confirmed = await app.request(`/v1/blobs/multipart/${manifest.uploadId}/confirm`, {
      method: 'POST', headers,
      body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength })
    }, env);
    expect(confirmed.status).toBe(200);
    expect((await app.request(`/v1/blobs/${digest}/download`, { headers: { Authorization: `Bearer ${token}` } }, env)).status).toBe(200);
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
