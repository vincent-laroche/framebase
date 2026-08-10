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
});
