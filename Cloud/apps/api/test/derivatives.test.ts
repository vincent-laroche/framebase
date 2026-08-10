import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

describe('fixed cloud derivatives', () => {
  let env: Bindings;

  beforeEach(() => { env = createTestEnv(); });

  it('fails closed when the paid Images binding is not configured', async () => {
    const token = await enrollDevice(env, 'device-derivative', ['library.read']);
    const response = await app.request('/v1/assets/missing/variants/grid-256', {
      headers: { Authorization: `Bearer ${token}` }
    }, env);
    expect(response.status).toBe(503);
    expect((await response.json<{ error: { code: string } }>()).error.code).toBe('DERIVATIVE_SERVICE_UNAVAILABLE');
  });

  it('rejects arbitrary variants before any source lookup', async () => {
    const token = await enrollDevice(env, 'device-derivative-variant', ['library.read']);
    const response = await app.request('/v1/assets/missing/variants/anything', {
      headers: { Authorization: `Bearer ${token}` }
    }, env);
    expect(response.status).toBe(404);
  });
});
