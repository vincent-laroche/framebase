import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

const ONE_PIXEL_PNG = Uint8Array.from(
  atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9oQAAAABJRU5ErkJggg=='),
  (character) => character.charCodeAt(0)
);

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

describe('Phase 2 fixture acceptance', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('rebuilds a fresh catalog from bootstrap plus ordered changes after a private fixture upload', async () => {
    const token = await enrollDevice(env, 'fixture-acceptance-device', [
      'library.read', 'assets.import', 'assets.metadata.write', 'assets.organize', 'originals.download'
    ]);
    const digest = await sha256(ONE_PIXEL_PNG);

    const initiated = await app.request('/v1/blobs/upload-initiate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: ONE_PIXEL_PNG.byteLength, mediaType: 'image/png', originalExtension: 'png' })
    }, env);
    expect(initiated.status).toBe(200);
    const initiatedBody = await initiated.json<{ upload: { url: string } }>();
    expect(initiatedBody.upload.url).toContain('X-Amz-Signature=');

    const blob = await env.DB.prepare('SELECT r2_key FROM blobs WHERE id = ?').bind(digest).first<{ r2_key: string }>();
    await env.BLOBS.put(blob!.r2_key, ONE_PIXEL_PNG, { httpMetadata: { contentType: 'image/png' } });
    expect((await app.request('/v1/blobs/upload-complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ sha256: digest, byteSize: ONE_PIXEL_PNG.byteLength })
    }, env)).status).toBe(200);

    const mutate = async (key: string, operations: unknown[]) => app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': key },
      body: JSON.stringify({ operations })
    }, env);
    expect((await mutate('fixture-create-folder', [
      { type: 'create_folder', targetId: 'fixture-folder', payload: { name: 'Fixture Folder' } }
    ])).status).toBe(200);
    expect((await mutate('fixture-create-asset', [
      { type: 'create_asset', targetId: 'fixture-asset', payload: { blobId: digest, folderId: 'fixture-folder', displayName: 'fixture.png' } }
    ])).status).toBe(200);

    const bootstrapResponse = await app.request('/v1/catalog/bootstrap?limit=500', { headers: { Authorization: `Bearer ${token}` } }, env);
    expect(bootstrapResponse.status).toBe(200);
    const bootstrap = await bootstrapResponse.json<{
      watermarkRevision: number;
      entities: Array<{ entityType: string; entityId: string; revision: number; payload: Record<string, unknown> }>;
    }>();
    const freshCatalog = new Map(bootstrap.entities.map((entity) => [`${entity.entityType}:${entity.entityId}`, entity]));
    expect(freshCatalog.get('asset:fixture-asset')?.payload.displayName).toBe('fixture.png');

    expect((await mutate('fixture-rate-asset', [
      { type: 'update_rating', targetId: 'fixture-asset', baseRevision: 1, payload: { rating: 5 } }
    ])).status).toBe(200);
    const changesResponse = await app.request(`/v1/changes?after=${bootstrap.watermarkRevision}&limit=100`, { headers: { Authorization: `Bearer ${token}` } }, env);
    const changes = await changesResponse.json<{
      changes: Array<{ revision: number; entityType: string; entityId: string; payload: Record<string, unknown> }>;
    }>();
    expect(changes.changes).toHaveLength(1);
    expect(changes.changes[0].revision).toBeGreaterThan(bootstrap.watermarkRevision);
    freshCatalog.set(`${changes.changes[0].entityType}:${changes.changes[0].entityId}`, {
      entityType: changes.changes[0].entityType,
      entityId: changes.changes[0].entityId,
      revision: 2,
      payload: changes.changes[0].payload
    });
    expect(freshCatalog.get('asset:fixture-asset')?.payload.rating).toBe(5);

    const download = await app.request(`/v1/blobs/${digest}/download`, { headers: { Authorization: `Bearer ${token}` } }, env);
    expect(download.status).toBe(200);
  });
});
