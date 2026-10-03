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

    const stored = await env.DB.prepare(
      'SELECT r2_key, r2_upload_id FROM multipart_uploads WHERE id = ?'
    ).bind(manifest.uploadId).first<{ r2_key: string; r2_upload_id: string }>();
    expect(stored?.r2_key.startsWith('blobs/sha256/')).toBe(true);

    const refused = await app.request(`/v1/blobs/multipart/${manifest.uploadId}/parts/1`, {
      method: 'PUT', headers: { Authorization: `Bearer ${token}` }, body: bytes.slice(0, 16)
    }, env);
    expect(refused.status).toBe(413);
    expect((await refused.json<{ error: { code: string } }>()).error.code).toBe('DIRECT_R2_REQUIRED');

    for (let partNumber = 1; partNumber <= manifest.partCount; partNumber += 1) {
      const offset = (partNumber - 1) * partSize;
      const end = Math.min(offset + partSize, bytes.byteLength);
      const presign = await app.request(`/v1/blobs/multipart/${manifest.uploadId}/parts/${partNumber}/presign`, {
        method: 'POST', headers: { Authorization: `Bearer ${token}` }
      }, env);
      expect(presign.status).toBe(200);
      const signed = await presign.json<{ upload: { url: string; method: string } }>();
      const partURL = new URL(signed.upload.url);
      expect(signed.upload.method).toBe('PUT');
      expect(partURL.host).toBe('test-account-id.r2.cloudflarestorage.com');
      expect(partURL.pathname.startsWith('/framebase-blobs-dev/blobs/sha256/')).toBe(true);
      expect(partURL.searchParams.get('partNumber')).toBe(String(partNumber));
      expect(partURL.searchParams.get('uploadId')).toBe(stored!.r2_upload_id);
      expect(partURL.host).not.toContain('workers.dev');
      const partBytes = bytes.slice(offset, end);
      const uploaded = await env.BLOBS.resumeMultipartUpload(stored!.r2_key, stored!.r2_upload_id).uploadPart(partNumber, partBytes);
      const recorded = await app.request(`/v1/blobs/multipart/${manifest.uploadId}/parts/${partNumber}/record`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ etag: uploaded.etag, byteSize: partBytes.byteLength })
      }, env);
      expect(recorded.status).toBe(200);
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

  it('stores one original in framebase-blobs-dev and does not duplicate a second upload of the same bytes', async () => {
    const token = await enrollDevice(env, 'device-receive-original', ['assets.import', 'originals.download']);
    const bytes = new TextEncoder().encode('personal-original');
    const digest = await sha256(bytes);
    const intent = { sha256: digest, byteSize: bytes.byteLength, mediaType: 'image/jpeg', originalExtension: 'jpg' };
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };

    const initiate = await app.request('/v1/blobs/upload-initiate', {
      method: 'POST', headers, body: JSON.stringify(intent)
    }, env);
    expect(initiate.status).toBe(200);
    const initiated = await initiate.json<{ status: string; blobId: string; upload: { url: string; method: string } }>();
    expect(initiated.status).toBe('pending_upload');
    expect(initiated.blobId).toBe(digest);
    const uploadURL = new URL(initiated.upload.url);
    expect(initiated.upload.method).toBe('PUT');
    expect(uploadURL.host).toBe('test-account-id.r2.cloudflarestorage.com');
    expect(uploadURL.pathname).toBe(`/framebase-blobs-dev/blobs/sha256/${digest.slice(0, 2)}/${digest}.jpg`);
    expect(uploadURL.host).not.toContain('workers.dev');

    const row = await env.DB.prepare('SELECT r2_key, upload_state FROM blobs WHERE sha256 = ?')
      .bind(digest).first<{ r2_key: string; upload_state: string }>();
    expect(row?.upload_state).toBe('pending');
    expect(row?.r2_key).toBe(`blobs/sha256/${digest.slice(0, 2)}/${digest}.jpg`);
    await env.BLOBS.put(row!.r2_key, bytes, { httpMetadata: { contentType: 'image/jpeg' } });

    const complete = await app.request('/v1/blobs/upload-complete', {
      method: 'POST', headers, body: JSON.stringify({ sha256: digest, byteSize: bytes.byteLength })
    }, env);
    expect(complete.status).toBe(200);
    expect((await complete.json<{ status: string }>()).status).toBe('verified');

    const again = await app.request('/v1/blobs/upload-initiate', {
      method: 'POST', headers, body: JSON.stringify(intent)
    }, env);
    expect(again.status).toBe(200);
    const repeated = await again.json<{ status: string; upload?: { url: string } }>();
    expect(repeated.status).toBe('already_verified');
    expect(repeated.upload).toBeUndefined();

    const blobs = await env.DB.prepare('SELECT COUNT(*) AS count FROM blobs WHERE sha256 = ?')
      .bind(digest).first<{ count: number }>();
    expect(blobs?.count).toBe(1);
    expect((await env.BLOBS.head(row!.r2_key))?.size).toBe(bytes.byteLength);

    const assetID = 'receive-asset-one';
    const mutation = () => app.request('/v1/mutations', {
      method: 'POST',
      headers: { ...headers, 'Idempotency-Key': `receive-asset-${assetID}` },
      body: JSON.stringify({
        operations: [{
          type: 'create_asset',
          targetId: assetID,
          payload: {
            blobId: digest,
            folderId: 'system-inbox',
            displayName: 'Original',
            assetMetadata: { librarySpace: 'personal', mediaType: 'stillImage' }
          }
        }]
      })
    }, env);
    const created = await mutation();
    expect(created.status).toBe(200);
    const createdBody = await created.json();
    const replayed = await mutation();
    expect(replayed.status).toBe(200);
    expect(await replayed.json()).toEqual(createdBody);
    const assets = await env.DB.prepare('SELECT COUNT(*) AS count FROM assets WHERE blob_id = ?')
      .bind(digest).first<{ count: number }>();
    expect(assets?.count).toBe(1);
  });

  it('presigns a single direct upload past the Worker body cap and below 5 GiB', async () => {
    const token = await enrollDevice(env, 'device-large-original', ['assets.import']);
    const digest = 'ab'.repeat(32);
    const initiate = await app.request('/v1/blobs/upload-initiate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: 100 * 1024 * 1024, mediaType: 'image/jpeg', originalExtension: 'jpg' })
    }, env);
    expect(initiate.status).toBe(200);
    const body = await initiate.json<{ upload: { url: string } }>();
    const uploadURL = new URL(body.upload.url);
    expect(uploadURL.host.endsWith('.r2.cloudflarestorage.com')).toBe(true);
    expect(uploadURL.pathname.startsWith('/framebase-blobs-dev/')).toBe(true);

    const tooLargeForOnePart = await app.request('/v1/blobs/upload-initiate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: 'cd'.repeat(32), byteSize: 5 * 1024 * 1024 * 1024 + 1, mediaType: 'image/jpeg', originalExtension: 'jpg' })
    }, env);
    expect(tooLargeForOnePart.status).toBe(422);
  });

  it('refuses an original posted as the Worker JSON body', async () => {
    const token = await enrollDevice(env, 'device-body-cap', ['assets.import']);
    const response = await app.request('/v1/blobs/upload-complete', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
        'Content-Length': String(9 * 1024)
      },
      body: JSON.stringify({ sha256: 'a'.repeat(64), byteSize: 1 })
    }, env);
    expect(response.status).toBe(413);
    expect((await response.json<{ error: { code: string } }>()).error.code).toBe('DIRECT_R2_REQUIRED');
  });
});
