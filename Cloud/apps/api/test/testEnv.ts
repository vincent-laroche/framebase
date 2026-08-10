import initialMigration from '../migrations/0001_initial_schema.sql?raw';
import idempotencyMigration from '../migrations/0002_idempotency_and_mutation_guards.sql?raw';
import type { Bindings } from '../src/types.js';
import { createFakeD1 } from './fakes/d1.js';
import { createFakeR2 } from './fakes/r2.js';

export function createTestEnv(): Bindings {
  return {
    DB: createFakeD1(`${initialMigration}\n${idempotencyMigration}`),
    BLOBS: createFakeR2(),
    JWT_SECRET: 'contract-test-only-secret-do-not-reuse',
    ENROLLMENT_SECRET: 'contract-test-only-enrollment-secret',
    R2_ACCOUNT_ID: 'test-account-id',
    R2_ACCESS_KEY_ID: 'test-access-key',
    R2_SECRET_ACCESS_KEY: 'test-secret-key'
  };
}
