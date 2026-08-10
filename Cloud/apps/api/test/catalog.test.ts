import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

describe('catalog bootstrap', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('returns a paginated snapshot with a stable change-feed watermark', async () => {
    const token = await enrollDevice(env, 'device-bootstrap', ['assets.organize', 'library.read']);
    for (const id of ['folder-bootstrap-a', 'folder-bootstrap-b']) {
      const create = await app.request('/v1/mutations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': `create-${id}` },
        body: JSON.stringify({ operations: [{ type: 'create_folder', targetId: id, payload: { name: id } }] })
      }, env);
      expect(create.status).toBe(200);
    }

    const firstPage = await app.request('/v1/catalog/bootstrap?limit=1', { headers: { Authorization: `Bearer ${token}` } }, env);
    expect(firstPage.status).toBe(200);
    const first = await firstPage.json<{ watermarkRevision: number; entities: Array<{ entityId: string }>; nextCursor: string | null }>();
    expect(first.watermarkRevision).toBe(2);
    expect(first.entities).toHaveLength(1);
    expect(first.nextCursor).not.toBeNull();

    const secondPage = await app.request(`/v1/catalog/bootstrap?limit=10&cursor=${first.nextCursor}`, { headers: { Authorization: `Bearer ${token}` } }, env);
    const second = await secondPage.json<{ entities: Array<{ entityId: string }>; nextCursor: string | null }>();
    const allIds = [...first.entities, ...second.entities].map((entity) => entity.entityId);
    expect(allIds).toContain('folder-bootstrap-a');
    expect(allIds).toContain('folder-bootstrap-b');
    expect(second.nextCursor).toBeNull();
  });

  it('requires library.read for bootstrap and capabilities', async () => {
    const token = await enrollDevice(env, 'device-no-read', ['assets.organize']);
    for (const path of ['/v1/catalog/bootstrap', '/v1/capabilities']) {
      const response = await app.request(path, { headers: { Authorization: `Bearer ${token}` } }, env);
      expect(response.status).toBe(403);
    }
  });

  it('preserves the immutable local asset envelope in bootstrap output', async () => {
    const token = await enrollDevice(env, 'device-asset-envelope', ['assets.import', 'library.read']);
    const digest = 'a'.repeat(64);
    await env.DB.prepare(
      `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
       VALUES (?, ?, ?, ?, ?, ?, 'verified')`
    ).bind(digest, digest, 42, 'image/jpeg', 'jpg', 'blobs/test.jpg').run();
    const metadata = {
      filename: 'portrait.jpg', storageKey: 'aa/asset.jpg', mediaType: 'stillImage',
      fileSize: 42, createdAt: '2026-01-01T00:00:00.000Z', modifiedAt: '2026-01-01T00:00:00.000Z',
      importedAt: '2026-01-01T00:00:00.000Z', metadata: { version: 1 }
    };
    const created = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'create-envelope-asset' },
      body: JSON.stringify({ operations: [{
        type: 'create_asset', targetId: 'asset-envelope',
        payload: { blobId: digest, folderId: 'system-inbox', displayName: 'Portrait', assetMetadata: metadata }
      }] })
    }, env);
    expect(created.status).toBe(200);

    const bootstrap = await app.request('/v1/catalog/bootstrap?limit=20', { headers: { Authorization: `Bearer ${token}` } }, env);
    const body = await bootstrap.json<{ entities: Array<{ entityId: string; payload: { assetMetadata?: typeof metadata } }> }>();
    expect(body.entities.find((entity) => entity.entityId === 'asset-envelope')?.payload.assetMetadata).toEqual(metadata);
  });

  it('includes album membership in the authoritative bootstrap snapshot', async () => {
    const token = await enrollDevice(env, 'device-album-bootstrap', ['assets.organize', 'assets.import', 'library.read']);
    const digest = 'b'.repeat(64);
    await env.DB.prepare(
      `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
       VALUES (?, ?, ?, ?, ?, ?, 'verified')`
    ).bind(digest, digest, 42, 'image/jpeg', 'jpg', 'blobs/test.jpg').run();
    for (const operation of [
      { type: 'create_asset', targetId: 'asset-album-snapshot', payload: { blobId: digest, folderId: 'system-inbox', displayName: 'Album asset' } },
      { type: 'create_album', targetId: 'album-snapshot', payload: { name: 'Favorites' } }
    ]) {
      const response = await app.request('/v1/mutations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': `create-${operation.targetId}` },
        body: JSON.stringify({ operations: [operation] })
      }, env);
      expect(response.status).toBe(200);
    }
    const membership = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'album-membership' },
      body: JSON.stringify({ operations: [{
        type: 'add_assets_to_album', targetId: 'album-snapshot', baseRevision: 1,
        payload: { assetIds: ['asset-album-snapshot'] }
      }] })
    }, env);
    expect(membership.status).toBe(200);

    const bootstrap = await app.request('/v1/catalog/bootstrap?limit=20', { headers: { Authorization: `Bearer ${token}` } }, env);
    const body = await bootstrap.json<{ entities: Array<{ entityId: string; revision: number; payload: { assetIds?: string[] } }> }>();
    expect(body.entities.find((entity) => entity.entityId === 'album-snapshot')).toMatchObject({
      revision: 2,
      payload: { assetIds: ['asset-album-snapshot'] }
    });
  });

  it('includes Phase 4 organization records without exposing original bytes', async () => {
    const token = await enrollDevice(env, 'device-organization-bootstrap', ['library.read']);
    await env.DB.prepare("INSERT INTO tags (id, name, revision) VALUES ('tag-review', 'status:review', 1)").run();
    await env.DB.prepare(
      "INSERT INTO saved_searches (id, name, rules_json, sort_json, revision) VALUES ('search-review', 'Needs Review', ?, ?, 1)"
    ).bind(JSON.stringify({ tagIds: ['tag-review'] }), JSON.stringify({ key: 'modifiedAt', direction: 'descending' })).run();
    await env.DB.prepare(
      "INSERT INTO export_receipts (id, manifest_sha256, asset_ids_json, revision) VALUES ('export-review', ?, '[]', 1)"
    ).bind('c'.repeat(64)).run();
    await env.DB.prepare(
      "INSERT INTO backup_manifests (id, manifest_sha256, last_restore_drill_result, revision) VALUES ('backup-review', ?, 'passed', 1)"
    ).bind('d'.repeat(64)).run();

    const bootstrap = await app.request('/v1/catalog/bootstrap?limit=20', { headers: { Authorization: `Bearer ${token}` } }, env);
    const body = await bootstrap.json<{ entities: Array<{ entityType: string; entityId: string; payload: Record<string, unknown> }> }>();
    expect(body.entities.find((entity) => entity.entityId === 'tag-review')).toMatchObject({
      entityType: 'tag', payload: { name: 'status:review', assetIds: [] }
    });
    expect(body.entities.find((entity) => entity.entityId === 'search-review')).toMatchObject({
      entityType: 'saved_search', payload: { rules: { tagIds: ['tag-review'] } }
    });
    expect(body.entities.find((entity) => entity.entityId === 'export-review')?.payload).toEqual(expect.objectContaining({ manifestSHA256: 'c'.repeat(64), assetIds: [] }));
    expect(body.entities.find((entity) => entity.entityId === 'backup-review')?.payload).toEqual(expect.objectContaining({ lastRestoreDrillResult: 'passed' }));
  });
});
