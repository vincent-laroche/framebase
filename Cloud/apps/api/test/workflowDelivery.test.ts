import { beforeEach, describe, expect, it } from 'vitest';
import {
  createWorkflowDelivery,
  deliverWorkflowMessage,
  enqueuePendingWorkflowDelivery,
  recoverDeadLetteredWorkflowDelivery,
  resumeApprovedWorkflowDelivery,
  type WorkflowDeliveryMessage
} from '../src/workflows/durableDelivery.js';
import type { Bindings } from '../src/types.js';
import { createTestEnv } from './testEnv.js';

class RecordingQueue {
  readonly messages: WorkflowDeliveryMessage[] = [];
  failNext = false;

  async send(message: WorkflowDeliveryMessage): Promise<void> {
    if (this.failNext) {
      this.failNext = false;
      throw new Error('synthetic queue failure');
    }
    this.messages.push(message);
  }
}

async function seedOperation(env: Bindings, operationID: string, status: 'proposed' | 'approved' = 'proposed'): Promise<void> {
  await env.DB.prepare(
    "INSERT INTO devices (id, device_name, public_key, scopes, status) VALUES ('delivery-owner', 'Delivery Owner', 'delivery-key', '[\"assets.organize\"]', 'active')"
  ).run();
  await env.DB.prepare(
    "INSERT INTO agent_identities (id, owner_device_id, name, scopes_json, credential_hash) VALUES ('delivery-agent', 'delivery-owner', 'Delivery Agent', '[\"assets.metadata.write\"]', 'delivery-credential-hash')"
  ).run();
  await env.DB.prepare("INSERT INTO tags (id, name, revision) VALUES ('tag-opaque', 'status:delivery', 1)").run();
  await env.DB.prepare(
    `INSERT INTO agent_operations (id, agent_id, kind, status, target_asset_ids_json, apply_asset_ids_json, tag_id, tag_revision, catalog_revision, snapshot_sha256, approval_token_hash, approval_expires_at)
     VALUES (?, 'delivery-agent', 'addTags', ?, '[\"asset-opaque\"]', '[\"asset-opaque\"]', 'tag-opaque', 1, 0, 'snapshot', 'approval-hash', '2099-01-01T00:00:00.000Z')`
  ).bind(operationID, status).run();
}

describe('source-only Phase 7 durable workflow delivery adapter', () => {
  let env: Bindings;
  let queue: RecordingQueue;

  beforeEach(() => {
    env = createTestEnv();
    queue = new RecordingQueue();
  });

  it('pauses a proposed operation, resumes only after approval, and emits a bounded queue envelope', async () => {
    await seedOperation(env, 'operation-paused');
    const created = await createWorkflowDelivery(env, 'operation-paused');
    expect(created).toMatchObject({ status: 'waiting_approval', attemptCount: 0, maxAttempts: 3 });
    expect(await enqueuePendingWorkflowDelivery(env, queue, created!.id)).toMatchObject({ status: 'waiting_approval' });
    expect(queue.messages).toEqual([]);

    await env.DB.prepare("UPDATE agent_operations SET status = 'approved' WHERE id = 'operation-paused'").run();
    const resumed = await resumeApprovedWorkflowDelivery(env, created!.id);
    expect(resumed).toMatchObject({ status: 'pending' });
    const queued = await enqueuePendingWorkflowDelivery(env, queue, created!.id);
    expect(queued).toMatchObject({ status: 'queued' });
    expect(queue.messages).toEqual([{ schemaVersion: 1, dispatchId: created!.id, operationId: 'operation-paused', attempt: 1 }]);
    expect(JSON.stringify(queue.messages[0])).not.toContain('asset-opaque');
    expect(JSON.stringify(queue.messages[0])).not.toContain('tag-opaque');
    expect(JSON.stringify(queue.messages[0])).not.toContain('approval-hash');
  });

  it('acknowledges duplicate delivery without a second execution', async () => {
    await seedOperation(env, 'operation-duplicate', 'approved');
    const created = await createWorkflowDelivery(env, 'operation-duplicate');
    await enqueuePendingWorkflowDelivery(env, queue, created!.id);
    let calls = 0;
    const executor = { execute: async () => { calls += 1; return { kind: 'succeeded' as const }; } };
    expect(await deliverWorkflowMessage(env, queue.messages[0], executor)).toMatchObject({ status: 'succeeded', attemptCount: 1 });
    expect(await deliverWorkflowMessage(env, queue.messages[0], executor)).toMatchObject({ status: 'succeeded', attemptCount: 1 });
    expect(calls).toBe(1);
    const events = await env.DB.prepare('SELECT event_type FROM workflow_delivery_events WHERE dispatch_id = ? ORDER BY id').bind(created!.id).all<{ event_type: string }>();
    expect(events.results.map((event) => event.event_type)).toContain('duplicate_ignored');
  });

  it('retries a transient interruption then dead-letters, requiring explicit recovery before another attempt', async () => {
    await seedOperation(env, 'operation-retry', 'approved');
    const created = await createWorkflowDelivery(env, 'operation-retry', 2);
    await enqueuePendingWorkflowDelivery(env, queue, created!.id);
    const transient = { execute: async () => ({ kind: 'retryable' as const, code: 'SYNTHETIC_INTERRUPT' }) };
    expect(await deliverWorkflowMessage(env, queue.messages[0], transient)).toMatchObject({ status: 'pending', attemptCount: 1, lastErrorCode: 'SYNTHETIC_INTERRUPT' });
    await enqueuePendingWorkflowDelivery(env, queue, created!.id);
    expect(await deliverWorkflowMessage(env, queue.messages[1], transient)).toMatchObject({ status: 'dead_lettered', attemptCount: 2, lastErrorCode: 'SYNTHETIC_INTERRUPT' });
    expect(await recoverDeadLetteredWorkflowDelivery(env, created!.id)).toMatchObject({ status: 'pending', attemptCount: 0, lastErrorCode: null });
    await enqueuePendingWorkflowDelivery(env, queue, created!.id);
    expect(await deliverWorkflowMessage(env, queue.messages[2], { execute: async () => ({ kind: 'succeeded' as const }) })).toMatchObject({ status: 'succeeded', attemptCount: 1 });
  });

  it('fails closed for malformed or mismatched messages and keeps the outbox pending after an enqueue failure', async () => {
    await seedOperation(env, 'operation-failure', 'approved');
    const created = await createWorkflowDelivery(env, 'operation-failure');
    queue.failNext = true;
    expect(await enqueuePendingWorkflowDelivery(env, queue, created!.id)).toMatchObject({ status: 'pending', lastErrorCode: 'QUEUE_UNAVAILABLE' });
    expect(await deliverWorkflowMessage(env, { schemaVersion: 1, dispatchId: created!.id, operationId: 'different-operation', attempt: 1 }, { execute: async () => ({ kind: 'succeeded' as const }) })).toBeNull();
    expect(await deliverWorkflowMessage(env, { schemaVersion: 2, dispatchId: created!.id, operationId: 'operation-failure', attempt: 1 }, { execute: async () => ({ kind: 'succeeded' as const }) })).toBeNull();
  });
});
