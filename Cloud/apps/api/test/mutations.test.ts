import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

async function seedCanonicalAsset(env: Bindings, assetID: string, folderID: string): Promise<void> {
  const blobID = 'a'.repeat(64);
  await env.DB.prepare(
    `INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state)
     VALUES (?, ?, 1, 'image/jpeg', 'jpg', 'blobs/fixture.jpg', 'verified')`
  )
    .bind(blobID, blobID)
    .run();
  await env.DB.prepare(
    `INSERT INTO folders (id, name, parent_id, system_kind, sort_order, created_at, updated_at, revision)
     VALUES (?, 'Fixture', NULL, NULL, 0.0, datetime('now'), datetime('now'), 1)`
  )
    .bind(folderID)
    .run();
  await env.DB.prepare(
    `INSERT INTO assets (id, blob_id, filename, display_name, folder_id, favorite, rating, status,
                        source_created_at, source_modified_at, imported_at, metadata_json, created_at, updated_at, revision)
     VALUES (?, ?, 'fixture.jpg', 'fixture.jpg', ?, 0, 0, 'active', datetime('now'), datetime('now'), datetime('now'), '{}', datetime('now'), datetime('now'), 1)`
  )
    .bind(assetID, blobID, folderID)
    .run();
}

describe('POST /v1/mutations', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('rejects a batch when the device lacks the scope an operation requires', async () => {
    const token = await enrollDevice(env, 'device-scope-check', ['library.read']);

    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          clientMutationId: 'batch-1',
          actorId: 'device-scope-check',
          operations: [{ type: 'create_folder', targetId: 'folder-1', payload: { name: 'Trip' } }]
        })
      },
      env
    );

    expect(res.status).toBe(403);
  });

  it('applies a mutation once and replays the exact cached response for a repeated Idempotency-Key', async () => {
    const token = await enrollDevice(env, 'device-idempotent', ['assets.organize']);
    const request = () =>
      app.request(
        '/v1/mutations',
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
            'Idempotency-Key': 'fixed-key-1'
          },
          body: JSON.stringify({
            clientMutationId: 'fixed-key-1',
            actorId: 'device-idempotent',
            operations: [{ type: 'create_folder', targetId: 'folder-2', payload: { name: 'Trip' } }]
          })
        },
        env
      );

    const first = await request();
    expect(first.status).toBe(200);
    const firstBody = await first.json();

    const second = await request();
    expect(second.status).toBe(200);
    const secondBody = await second.json();
    expect(secondBody).toEqual(firstBody);

    const { results } = await env.DB.prepare(
      'SELECT COUNT(*) as count FROM change_events WHERE entity_id = ?'
    )
      .bind('folder-2')
      .all<{ count: number }>();
    expect(results[0].count).toBe(1);
  });

  it('validates an entire batch before writing any canonical state, change event, or receipt', async () => {
    const token = await enrollDevice(env, 'device-atomic-validation', ['assets.organize', 'assets.metadata.write']);
    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'all-or-nothing-validation'
        },
        body: JSON.stringify({
          clientMutationId: 'all-or-nothing-validation',
          actorId: 'device-atomic-validation',
          operations: [
            { type: 'create_folder', targetId: 'folder-should-not-exist', payload: { name: 'Valid first operation' } },
            { type: 'update_rating', targetId: 'asset-ignored', payload: { rating: 9 } }
          ]
        })
      },
      env
    );

    expect(res.status).toBe(400);
    const folder = await env.DB.prepare('SELECT id FROM folders WHERE id = ?').bind('folder-should-not-exist').first<{ id: string }>();
    expect(folder).toBeNull();
    const changes = await env.DB.prepare('SELECT COUNT(*) as count FROM change_events WHERE client_mutation_id LIKE ?')
      .bind('all-or-nothing-validation%')
      .first<{ count: number }>();
    expect(changes?.count).toBe(0);
    const receipt = await env.DB.prepare('SELECT client_mutation_id FROM idempotency_keys WHERE client_mutation_id = ?')
      .bind('all-or-nothing-validation')
      .first<{ client_mutation_id: string }>();
    expect(receipt).toBeNull();
  });

  it('rolls back every earlier operation when a later canonical database write fails', async () => {
    const token = await enrollDevice(env, 'device-atomic-database', ['assets.organize']);
    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'all-or-nothing-database'
        },
        body: JSON.stringify({
          clientMutationId: 'all-or-nothing-database',
          actorId: 'device-atomic-database',
          operations: [
            { type: 'create_folder', targetId: 'folder-rollback-first', payload: { name: 'First' } },
            { type: 'create_folder', targetId: 'folder-rollback-second', payload: { name: 'Second', parentId: 'missing-parent' } }
          ]
        })
      },
      env
    );

    expect(res.status).toBe(500);
    const folder = await env.DB.prepare('SELECT id FROM folders WHERE id = ?').bind('folder-rollback-first').first<{ id: string }>();
    expect(folder).toBeNull();
    const changes = await env.DB.prepare('SELECT COUNT(*) as count FROM change_events WHERE client_mutation_id LIKE ?')
      .bind('all-or-nothing-database:%')
      .first<{ count: number }>();
    expect(changes?.count).toBe(0);
    const receipt = await env.DB.prepare('SELECT client_mutation_id FROM idempotency_keys WHERE client_mutation_id = ?')
      .bind('all-or-nothing-database')
      .first<{ client_mutation_id: string }>();
    expect(receipt).toBeNull();
  });

  it('persists a created folder as canonical state before exposing its change event', async () => {
    const token = await enrollDevice(env, 'device-folder-state', ['assets.organize']);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f45';

    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'create-canonical-folder'
        },
        body: JSON.stringify({
          clientMutationId: 'create-canonical-folder',
          actorId: 'device-folder-state',
          operations: [{ type: 'create_folder', targetId: folderID, payload: { name: 'Fixture Folder', parentId: null } }]
        })
      },
      env
    );

    expect(res.status).toBe(200);
    const folder = await env.DB.prepare('SELECT id, name, parent_id, revision FROM folders WHERE id = ?')
      .bind(folderID)
      .first<{ id: string; name: string; parent_id: string | null; revision: number }>();
    expect(folder).toMatchObject({ id: folderID, name: 'Fixture Folder', parent_id: null, revision: 1 });
  });

  it('updates the canonical folder name for a rename mutation', async () => {
    const token = await enrollDevice(env, 'device-folder-rename', ['assets.organize']);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f46';
    await env.DB.prepare(
      `INSERT INTO folders (id, name, parent_id, system_kind, sort_order, created_at, updated_at, revision)
       VALUES (?, 'Before', NULL, NULL, 0.0, datetime('now'), datetime('now'), 1)`
    )
      .bind(folderID)
      .run();

    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'rename-canonical-folder'
        },
        body: JSON.stringify({
          clientMutationId: 'rename-canonical-folder',
          actorId: 'device-folder-rename',
          operations: [{ type: 'rename_folder', targetId: folderID, payload: { name: 'After' } }]
        })
      },
      env
    );

    expect(res.status).toBe(200);
    const folder = await env.DB.prepare('SELECT name, revision FROM folders WHERE id = ?')
      .bind(folderID)
      .first<{ name: string; revision: number }>();
    expect(folder).toMatchObject({ name: 'After', revision: 1 });
  });

  it('updates the canonical asset rating for a metadata mutation', async () => {
    const token = await enrollDevice(env, 'device-asset-rating', ['assets.metadata.write']);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f47';
    const assetID = '5f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f47';
    await seedCanonicalAsset(env, assetID, folderID);

    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'rate-canonical-asset'
        },
        body: JSON.stringify({
          clientMutationId: 'rate-canonical-asset',
          actorId: 'device-asset-rating',
          operations: [{ type: 'update_rating', targetId: assetID, payload: { rating: 4 } }]
        })
      },
      env
    );

    expect(res.status).toBe(200);
    const asset = await env.DB.prepare('SELECT rating, revision FROM assets WHERE id = ?')
      .bind(assetID)
      .first<{ rating: number; revision: number }>();
    expect(asset).toMatchObject({ rating: 4, revision: 1 });
  });

  it('updates the canonical asset favorite flag for a metadata mutation', async () => {
    const token = await enrollDevice(env, 'device-asset-favorite', ['assets.metadata.write']);
    const folderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f48';
    const assetID = '5f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f48';
    await seedCanonicalAsset(env, assetID, folderID);

    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'favorite-canonical-asset'
        },
        body: JSON.stringify({
          clientMutationId: 'favorite-canonical-asset',
          actorId: 'device-asset-favorite',
          operations: [{ type: 'update_favorite', targetId: assetID, payload: { favorite: true } }]
        })
      },
      env
    );

    expect(res.status).toBe(200);
    const asset = await env.DB.prepare('SELECT favorite, revision FROM assets WHERE id = ?')
      .bind(assetID)
      .first<{ favorite: number; revision: number }>();
    expect(asset).toMatchObject({ favorite: 1, revision: 1 });
  });

  it('updates the canonical asset folder for a move mutation', async () => {
    const token = await enrollDevice(env, 'device-asset-move', ['assets.organize']);
    const sourceFolderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f49';
    const targetFolderID = '4f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f50';
    const assetID = '5f73b9b5-1d4f-4ec2-9fe3-f7ddcd812f49';
    await seedCanonicalAsset(env, assetID, sourceFolderID);
    await env.DB.prepare(
      `INSERT INTO folders (id, name, parent_id, system_kind, sort_order, created_at, updated_at, revision)
       VALUES (?, 'Target', NULL, NULL, 1024.0, datetime('now'), datetime('now'), 1)`
    )
      .bind(targetFolderID)
      .run();

    const res = await app.request(
      '/v1/mutations',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
          'Idempotency-Key': 'move-canonical-asset'
        },
        body: JSON.stringify({
          clientMutationId: 'move-canonical-asset',
          actorId: 'device-asset-move',
          operations: [{ type: 'move_assets', targetId: assetID, payload: { targetFolderId: targetFolderID } }]
        })
      },
      env
    );

    expect(res.status).toBe(200);
    const asset = await env.DB.prepare('SELECT folder_id, revision FROM assets WHERE id = ?')
      .bind(assetID)
      .first<{ folder_id: string; revision: number }>();
    expect(asset).toMatchObject({ folder_id: targetFolderID, revision: 1 });
  });
});
