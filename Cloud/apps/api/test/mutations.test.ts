import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

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

  it('rejects an idempotency key reused for a different request', async () => {
    const token = await enrollDevice(env, 'device-reused-key', ['assets.organize']);
    const request = (name: string) => app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'reused-key' },
      body: JSON.stringify({ operations: [{ type: 'create_folder', targetId: 'folder-reused', payload: { name } }] })
    }, env);
    expect((await request('First')).status).toBe(200);
    expect((await request('Different')).status).toBe(409);
  });

  it('persists a folder and rejects a stale revision without writing another change event', async () => {
    const token = await enrollDevice(env, 'device-revisions', ['assets.organize']);
    const create = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'create-revision-folder' },
      body: JSON.stringify({ operations: [{ type: 'create_folder', targetId: 'folder-revision', payload: { name: 'Initial' } }] })
    }, env);
    expect(create.status).toBe(200);

    const rename = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'rename-revision-folder' },
      body: JSON.stringify({ operations: [{ type: 'rename_folder', targetId: 'folder-revision', baseRevision: 1, payload: { name: 'Renamed' } }] })
    }, env);
    expect(rename.status).toBe(200);

    const stale = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'stale-revision-folder' },
      body: JSON.stringify({ operations: [{ type: 'rename_folder', targetId: 'folder-revision', baseRevision: 1, payload: { name: 'Stale' } }] })
    }, env);
    expect(stale.status).toBe(409);
    const folder = await env.DB.prepare('SELECT name, revision FROM folders WHERE id = ?').bind('folder-revision')
      .first<{ name: string; revision: number }>();
    expect(folder).toEqual({ name: 'Renamed', revision: 2 });
    const events = await env.DB.prepare('SELECT COUNT(*) AS count FROM change_events WHERE entity_id = ?').bind('folder-revision')
      .first<{ count: number }>();
    expect(events?.count).toBe(2);
  });

  it('moves a folder with revision protection and rejects a remote cycle', async () => {
    const token = await enrollDevice(env, 'device-folder-move', ['assets.organize']);
    for (const operation of [
      { type: 'create_folder', targetId: 'folder-parent', payload: { name: 'Parent' } },
      { type: 'create_folder', targetId: 'folder-child', payload: { name: 'Child', parentId: 'folder-parent' } }
    ]) {
      const response = await app.request('/v1/mutations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': `create-${operation.targetId}` },
        body: JSON.stringify({ operations: [operation] })
      }, env);
      expect(response.status).toBe(200);
    }
    const cycle = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'move-parent-under-child' },
      body: JSON.stringify({ operations: [{ type: 'move_folder', targetId: 'folder-parent', baseRevision: 1, payload: { parentId: 'folder-child' } }] })
    }, env);
    expect(cycle.status).toBe(422);

    const move = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'move-child-to-root' },
      body: JSON.stringify({ operations: [{ type: 'move_folder', targetId: 'folder-child', baseRevision: 1, payload: { parentId: null } }] })
    }, env);
    expect(move.status).toBe(200);
    const child = await env.DB.prepare('SELECT parent_id, revision FROM folders WHERE id = ?').bind('folder-child')
      .first<{ parent_id: string | null; revision: number }>();
    expect(child).toEqual({ parent_id: null, revision: 2 });
  });

  it('derives audit attribution from the authenticated device rather than request JSON', async () => {
    const token = await enrollDevice(env, 'device-audit', ['assets.organize']);
    const response = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'audit-actor' },
      body: JSON.stringify({ actorId: 'forged-actor', operations: [{ type: 'create_folder', targetId: 'folder-audit', payload: { name: 'Audit' } }] })
    }, env);
    expect(response.status).toBe(200);
    const audit = await env.DB.prepare('SELECT actor_id FROM audit_events WHERE target_id = ?').bind('folder-audit')
      .first<{ actor_id: string }>();
    expect(audit?.actor_id).toBe('device-audit');
  });

  it('applies revisioned tag membership and saved-search mutations with replay protection', async () => {
    const token = await enrollDevice(env, 'device-organization', ['assets.metadata.write', 'library.preferences.write']);
    const createTag = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'create-review-tag' },
      body: JSON.stringify({ operations: [{ type: 'create_tag', targetId: 'tag-review', payload: { name: 'status:review' } }] })
    }, env);
    expect(createTag.status).toBe(200);

    const tag = await env.DB.prepare('SELECT revision FROM tags WHERE id = ?').bind('tag-review').first<{ revision: number }>();
    expect(tag?.revision).toBe(1);
    const invalidTag = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'create-invalid-tag' },
      body: JSON.stringify({ operations: [{ type: 'create_tag', targetId: 'tag-invalid', payload: { name: 'Not normalized' } }] })
    }, env);
    expect(invalidTag.status).toBe(422);

    const createSearch = () => app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'create-review-search' },
      body: JSON.stringify({ operations: [{
        type: 'create_saved_search', targetId: 'search-review',
        payload: { name: 'Needs Review', rules: { tagIds: ['tag-review'] }, sort: { key: 'modifiedAt', direction: 'descending' } }
      }] })
    }, env);
    expect((await createSearch()).status).toBe(200);
    expect((await createSearch()).status).toBe(200);
    const savedSearch = await env.DB.prepare('SELECT name, revision FROM saved_searches WHERE id = ?').bind('search-review').first<{ name: string; revision: number }>();
    expect(savedSearch).toEqual({ name: 'Needs Review', revision: 1 });
    const changes = await env.DB.prepare("SELECT COUNT(*) AS count FROM change_events WHERE entity_type IN ('tag', 'saved_search')").first<{ count: number }>();
    expect(changes?.count).toBe(2);
  });

  it('renames, trashes, and restores an asset without losing its tag receipt', async () => {
    const token = await enrollDevice(env, 'device-recovery', ['assets.import', 'assets.metadata.write', 'trash.write']);
    const digest = 'e'.repeat(64);
    await env.DB.prepare(
      "INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state) VALUES (?, ?, 11, 'image/jpeg', 'jpg', 'blobs/recovery.jpg', 'verified')"
    ).bind(digest, digest).run();
    const mutation = (idempotencyKey: string, operation: Record<string, unknown>) => app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': idempotencyKey },
      body: JSON.stringify({ operations: [operation] })
    }, env);
    expect((await mutation('asset-recovery-create', {
      type: 'create_asset', targetId: 'asset-recovery', payload: { blobId: digest, folderId: 'system-inbox', displayName: 'Before' }
    })).status).toBe(200);
    expect((await mutation('asset-recovery-tag-create', {
      type: 'create_tag', targetId: 'tag-recovery', payload: { name: 'status:review' }
    })).status).toBe(200);
    expect((await mutation('asset-recovery-tag-attach', {
      type: 'add_tag_to_assets', targetId: 'tag-recovery', baseRevision: 1, payload: { assetIds: ['asset-recovery'] }
    })).status).toBe(200);
    expect((await mutation('asset-recovery-trash', {
      type: 'trash_asset', targetId: 'asset-recovery', baseRevision: 1, payload: { retentionDays: 30 }
    })).status).toBe(200);
    const trashed = await env.DB.prepare('SELECT status, revision FROM assets WHERE id = ?').bind('asset-recovery').first<{ status: string; revision: number }>();
    expect(trashed).toEqual({ status: 'trashed', revision: 2 });
    expect(await env.DB.prepare('SELECT tag_id FROM asset_tags WHERE asset_id = ?').bind('asset-recovery').first()).toBeNull();
    expect((await mutation('asset-recovery-restore', {
      type: 'restore_asset', targetId: 'asset-recovery', baseRevision: 2, payload: {}
    })).status).toBe(200);
    const restored = await env.DB.prepare('SELECT display_name, status, revision FROM assets WHERE id = ?').bind('asset-recovery').first<{ display_name: string; status: string; revision: number }>();
    expect(restored).toEqual({ display_name: 'Before', status: 'active', revision: 3 });
    const restoredTag = await env.DB.prepare('SELECT tag_id FROM asset_tags WHERE asset_id = ?').bind('asset-recovery').first<{ tag_id: string }>();
    expect(restoredTag?.tag_id).toBe('tag-recovery');
    expect((await mutation('asset-recovery-rename', {
      type: 'rename_asset', targetId: 'asset-recovery', baseRevision: 3, payload: { displayName: 'After' }
    })).status).toBe(200);
    expect((await env.DB.prepare('SELECT display_name FROM assets WHERE id = ?').bind('asset-recovery').first<{ display_name: string }>())?.display_name).toBe('After');
  });

  it('records an idempotent export receipt without any original-byte payload', async () => {
    const token = await enrollDevice(env, 'device-export-receipt', ['library.preferences.write']);
    const response = await app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': 'export-receipt-1' },
      body: JSON.stringify({ operations: [{
        type: 'record_export_receipt', targetId: 'export-receipt-1',
        payload: { manifestSHA256: 'f'.repeat(64), assetIds: [] }
      }] })
    }, env);
    expect(response.status).toBe(200);
    const receipt = await env.DB.prepare('SELECT manifest_sha256, asset_ids_json, revision FROM export_receipts WHERE id = ?')
      .bind('export-receipt-1').first<{ manifest_sha256: string; asset_ids_json: string; revision: number }>();
    expect(receipt).toEqual({ manifest_sha256: 'f'.repeat(64), asset_ids_json: '[]', revision: 1 });
    const event = await env.DB.prepare("SELECT entity_type, payload FROM change_events WHERE entity_id = ?").bind('export-receipt-1').first<{ entity_type: string; payload: string }>();
    expect(event?.entity_type).toBe('export_receipt');
    expect(event?.payload).not.toContain('original');
  });

  it('records a backup manifest and revision-guarded restore drill without private bytes', async () => {
    const token = await enrollDevice(env, 'device-backup-manifest', ['library.preferences.write']);
    const mutation = (idempotencyKey: string, operation: Record<string, unknown>) => app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': idempotencyKey },
      body: JSON.stringify({ operations: [operation] })
    }, env);
    expect((await mutation('backup-manifest-1', {
      type: 'record_backup_manifest', targetId: 'backup-manifest-1', payload: { manifestSHA256: 'a'.repeat(64) }
    })).status).toBe(200);
    expect((await mutation('backup-drill-1', {
      type: 'record_backup_restore_drill', targetId: 'backup-manifest-1', baseRevision: 1, payload: { result: 'passed' }
    })).status).toBe(200);
    const manifest = await env.DB.prepare('SELECT manifest_sha256, last_restore_drill_result, revision FROM backup_manifests WHERE id = ?')
      .bind('backup-manifest-1').first<{ manifest_sha256: string; last_restore_drill_result: string; revision: number }>();
    expect(manifest).toEqual({ manifest_sha256: 'a'.repeat(64), last_restore_drill_result: 'passed', revision: 2 });
  });

  it('supports revisioned album rename, reorder, membership removal, and deletion', async () => {
    const token = await enrollDevice(env, 'device-album-lifecycle', ['assets.organize']);
    const mutation = (idempotencyKey: string, operation: Record<string, unknown>) => app.request('/v1/mutations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'Idempotency-Key': idempotencyKey },
      body: JSON.stringify({ operations: [operation] })
    }, env);
    expect((await mutation('album-a-create', { type: 'create_album', targetId: 'album-a', payload: { name: 'A' } })).status).toBe(200);
    expect((await mutation('album-b-create', { type: 'create_album', targetId: 'album-b', payload: { name: 'B' } })).status).toBe(200);
    expect((await mutation('album-b-rename', { type: 'rename_album', targetId: 'album-b', baseRevision: 1, payload: { name: 'Renamed B' } })).status).toBe(200);
    expect((await mutation('album-b-reorder', { type: 'reorder_album', targetId: 'album-b', baseRevision: 2, payload: { predecessorId: null } })).status).toBe(200);
    const ordered = await env.DB.prepare('SELECT id FROM albums ORDER BY sort_order, id').all<{ id: string }>();
    expect(ordered.results.map((album) => album.id)).toEqual(['album-b', 'album-a']);
    expect((await mutation('album-b-delete', { type: 'delete_album', targetId: 'album-b', baseRevision: 3, payload: {} })).status).toBe(200);
    expect((await env.DB.prepare('SELECT id FROM albums WHERE id = ?').bind('album-b').first()) ?? null).toBeNull();
  });
});
