import initialMigration from '../migrations/0001_initial_schema.sql?raw';
import idempotencyMigration from '../migrations/0002_idempotency_and_mutation_guards.sql?raw';
import keypairEnrollmentMigration from '../migrations/0003_device_keypair_enrollment.sql?raw';
import multipartUploadMigration from '../migrations/0004_resumable_multipart_uploads.sql?raw';
import catalogReconciliationMigration from '../migrations/0005_catalog_reconciliation_metadata.sql?raw';
import completeOrganizationMigration from '../migrations/0006_complete_organization.sql?raw';
import agentOperationsMigration from '../migrations/0007_agent_operations.sql?raw';
import type { Bindings } from '../src/types.js';
import { createFakeD1 } from './fakes/d1.js';
import { createFakeR2 } from './fakes/r2.js';

export function createTestEnv(): Bindings {
  return {
    DB: createFakeD1(`${initialMigration}\n${idempotencyMigration}\n${keypairEnrollmentMigration}\n${multipartUploadMigration}\n${catalogReconciliationMigration}\n${completeOrganizationMigration}\n${agentOperationsMigration}`),
    BLOBS: createFakeR2(),
    JWT_SECRET: 'contract-test-only-secret-do-not-reuse',
    ENROLLMENT_SECRET: 'contract-test-only-enrollment-secret',
    R2_ACCOUNT_ID: 'test-account-id',
    R2_ACCESS_KEY_ID: 'test-access-key',
    R2_SECRET_ACCESS_KEY: 'test-secret-key'
  };
}
