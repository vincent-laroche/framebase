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
});
