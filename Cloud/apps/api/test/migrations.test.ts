import initialMigration from '../migrations/0001_initial_schema.sql?raw';
import idempotencyMigration from '../migrations/0002_idempotency_and_mutation_guards.sql?raw';
import completeOrganizationMigration from '../migrations/0006_complete_organization.sql?raw';
import { describe, expect, it } from 'vitest';
import { createFakeD1 } from './fakes/d1.js';

describe('D1 migrations', () => {
  it('creates a clean catalog schema and seeds exactly one Inbox', async () => {
    const db = createFakeD1(`${initialMigration}\n${idempotencyMigration}\n${completeOrganizationMigration}`);
    const inboxes = await db.prepare("SELECT COUNT(*) AS count FROM folders WHERE id = 'system-inbox'").first<{ count: number }>();
    const fingerprintColumn = await db.prepare("SELECT request_fingerprint FROM idempotency_keys LIMIT 1").all();
    expect(inboxes?.count).toBe(1);
    expect(fingerprintColumn.success).toBe(true);
    const tagTable = await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tags'").first<{ name: string }>();
    const eventType = await db.prepare("INSERT INTO change_events (entity_type, entity_id, operation, payload, actor_id) VALUES ('tag', 'tag-test', 'create_tag', '{}', 'device')").all();
    expect(tagTable?.name).toBe('tags');
    expect(eventType.success).toBe(true);
  });
});
