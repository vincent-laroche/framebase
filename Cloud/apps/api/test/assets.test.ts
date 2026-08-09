import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

async function seedVerifiedBlobAndFolder(env: Bindings, blobID: string, folderID: string): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
     VALUES (?, ?, 13, 'image/jpeg', 'jpg', 'blobs/fixture.jpg', 'verified')`
  )
    .bind(blobID, blobID)
    .run();
  await env.DB.prepare(
    `INSERT INTO folders (id, name, parent_id, system_kind, sort_order, created_at, updated_at, revision)
     VALUES (?, 'Fixture', NULL, NULL, 0.0, datetime('now'), datetime('now'), 1)`
  )
    .bind(folderID)
    .run();
}

describe('POST /v1/assets/register', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('creates one canonical asset and change event for an existing verified blob', async () => {
    const token = await enrollDevice(env, 'device-asset-register', ['assets.import']);
    const blobID = 'b'.repeat(64);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f70';
    const assetID = '5f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f70';
    await seedVerifiedBlobAndFolder(env, blobID, folderID);

    const request = () => app.request(
      '/v1/assets/register',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'register-fixture-asset'
        },
        body: JSON.stringify({
          clientMutationId: 'register-fixture-asset',
          assetId: assetID,
          blobId: blobID,
          folderId: folderID,
          filename: 'fixture.jpg',
          displayName: 'Fixture',
          width: 2,
          height: 2,
          createdAt: '2026-08-09T12:00:00.000Z',
          modifiedAt: '2026-08-09T12:00:00.000Z',
          importedAt: '2026-08-09T12:00:00.000Z',
          favorite: false,
          rating: 0,
          metadata: { source: 'fixture' }
        })
      },
      env
    );

    const res = await request();
    expect(res.status).toBe(200);
    const firstBody = await res.json();
    const replay = await request();
    expect(replay.status).toBe(200);
    expect(await replay.json()).toEqual(firstBody);
    const asset = await env.DB.prepare('SELECT id, blob_id, display_name, folder_id FROM assets WHERE id = ?')
      .bind(assetID)
      .first<{ id: string; blob_id: string; display_name: string; folder_id: string }>();
    expect(asset).toMatchObject({ id: assetID, blob_id: blobID, display_name: 'Fixture', folder_id: folderID });
    const { results } = await env.DB.prepare(
      "SELECT COUNT(*) as count FROM change_events WHERE entity_type = 'asset' AND entity_id = ? AND operation = 'create_asset'"
    )
      .bind(assetID)
      .all<{ count: number }>();
    expect(results[0].count).toBe(1);
  });

  it('rejects a conflicting registration for an already-registered Asset ID without another event', async () => {
    const token = await enrollDevice(env, 'device-asset-conflict', ['assets.import']);
    const blobID = 'c'.repeat(64);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f71';
    const assetID = '5f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f71';
    await seedVerifiedBlobAndFolder(env, blobID, folderID);
    const request = (key: string, displayName: string) => app.request(
      '/v1/assets/register',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': key },
        body: JSON.stringify({
          clientMutationId: key, assetId: assetID, blobId: blobID, folderId: folderID,
          filename: 'fixture.jpg', displayName, width: 2, height: 2,
          createdAt: '2026-08-09T12:00:00.000Z', modifiedAt: '2026-08-09T12:00:00.000Z',
          importedAt: '2026-08-09T12:00:00.000Z', favorite: false, rating: 0, metadata: {}
        })
      },
      env
    );

    expect((await request('first-registration', 'Original')).status).toBe(200);
    expect((await request('conflicting-registration', 'Changed')).status).toBe(409);
    const { results } = await env.DB.prepare('SELECT COUNT(*) as count FROM change_events WHERE entity_id = ?')
      .bind(assetID)
      .all<{ count: number }>();
    expect(results[0].count).toBe(1);
  });

  it('rejects malformed logical IDs before registering an asset or change event', async () => {
    const token = await enrollDevice(env, 'device-asset-invalid-id', ['assets.import']);
    const blobID = 'd'.repeat(64);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f72';
    await seedVerifiedBlobAndFolder(env, blobID, folderID);

    const res = await app.request(
      '/v1/assets/register',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'invalid-asset-id' },
        body: JSON.stringify({
          clientMutationId: 'invalid-asset-id', assetId: 'not-a-uuid', blobId: blobID, folderId: folderID,
          filename: 'fixture.jpg', displayName: 'Fixture', width: 2, height: 2,
          createdAt: '2026-08-09T12:00:00.000Z', modifiedAt: '2026-08-09T12:00:00.000Z',
          importedAt: '2026-08-09T12:00:00.000Z', favorite: false, rating: 0, metadata: {}
        })
      },
      env
    );

    expect(res.status).toBe(400);
    const { results } = await env.DB.prepare("SELECT COUNT(*) as count FROM change_events WHERE operation = 'create_asset'")
      .all<{ count: number }>();
    expect(results[0].count).toBe(0);
  });
});
