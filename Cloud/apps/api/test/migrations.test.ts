import initialMigration from '../migrations/0001_initial_schema.sql?raw';
import idempotencyMigration from '../migrations/0002_idempotency_and_mutation_guards.sql?raw';
import { describe, expect, it } from 'vitest';
import { createFakeD1 } from './fakes/d1.js';

describe('D1 migrations', () => {
  it('creates a clean catalog schema and seeds exactly one Inbox', async () => {
    const db = createFakeD1(`${initialMigration}\n${idempotencyMigration}`);
    const inboxes = await db.prepare("SELECT COUNT(*) AS count FROM folders WHERE id = 'system-inbox'").first<{ count: number }>();
    const fingerprintColumn = await db.prepare("SELECT request_fingerprint FROM idempotency_keys LIMIT 1").all();
    expect(inboxes?.count).toBe(1);
    expect(fingerprintColumn.success).toBe(true);
  });
});
