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
});
