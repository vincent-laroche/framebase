import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

describe('GET /v1/changes', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('returns applied mutations in monotonic revision order', async () => {
    const token = await enrollDevice(env, 'device-changes', ['assets.organize', 'library.read']);

    for (const targetId of ['folder-a', 'folder-b', 'folder-c']) {
      await app.request(
        '/v1/mutations',
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${token}`,
            'Idempotency-Key': `create-${targetId}`
          },
          body: JSON.stringify({
            clientMutationId: `create-${targetId}`,
            actorId: 'device-changes',
            operations: [{ type: 'create_folder', targetId, payload: { name: targetId } }]
          })
        },
        env
      );
    }

    const res = await app.request(
      '/v1/changes?after=0&limit=100',
      { headers: { Authorization: `Bearer ${token}` } },
      env
    );

    expect(res.status).toBe(200);
    const body = await res.json<{ changes: Array<{ revision: number; entityId: string }> }>();
    expect(body.changes.length).toBe(3);
    const revisions = body.changes.map((change) => change.revision);
    const sorted = [...revisions].sort((a, b) => a - b);
    expect(revisions).toEqual(sorted);
  });
});
