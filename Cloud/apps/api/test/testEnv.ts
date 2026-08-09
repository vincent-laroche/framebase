import schemaSql from '../src/db/schema.sql?raw';
import type { Bindings } from '../src/types.js';
import { createFakeD1 } from './fakes/d1.js';
import { createFakeR2 } from './fakes/r2.js';

export function createTestEnv(): Bindings {
  return {
    DB: createFakeD1(schemaSql),
    BLOBS: createFakeR2(),
    JWT_SECRET: 'contract-test-only-secret-do-not-reuse'
  };
}
