import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import { createTestEnv } from './testEnv.js';
import type { Bindings } from '../src/types.js';

describe('GET /v1/health', () => {
  let env: Bindings;

  beforeEach(() => {
    env = createTestEnv();
  });

  it('reports ok status and a reachable database without requiring auth', async () => {
    const res = await app.request('/v1/health', {}, env);

    expect(res.status).toBe(200);
    const body = await res.json<{ status: string; db: string }>();
    expect(body.status).toBe('ok');
    expect(body.db).toBe('ok');
  });
});
