import type { AppEnv } from '../types.js';

/**
 * The payload contract for the eventual Queue binding. It intentionally
 * contains no asset IDs, tag IDs, approval token, filenames, or model output.
 * Those details are loaded from the durable operation record only after the
 * Worker receives a trusted queue delivery.
 */
export interface WorkflowDeliveryMessage {
  schemaVersion: 1;
  dispatchId: string;
  operationId: string;
  attempt: number;
}

export interface WorkflowDeliveryQueue {
  send(message: WorkflowDeliveryMessage): Promise<void>;
}

export type WorkflowExecutionOutcome =
  | { kind: 'succeeded' }
  | { kind: 'stale'; code: string }
  | { kind: 'retryable'; code: string }
  | { kind: 'failed'; code: string };

export interface WorkflowDeliveryExecutor {
  execute(operationId: string): Promise<WorkflowExecutionOutcome>;
}

export interface WorkflowDispatchView {
  id: string;
  operationId: string;
  status: 'waiting_approval' | 'pending' | 'dispatching' | 'queued' | 'succeeded' | 'stale' | 'dead_lettered';
  attemptCount: number;
  maxAttempts: number;
  lastErrorCode: string | null;
}

interface DispatchRow {
  id: string;
  operation_id: string;
  status: WorkflowDispatchView['status'];
  attempt_count: number;
  max_attempts: number;
  last_error_code: string | null;
}

interface OperationRow {
  id: string;
  status: 'proposed' | 'approved' | 'succeeded' | 'stale' | 'expired' | 'failed';
}

const ID = /^[A-Za-z0-9_-]{3,128}$/;
const MAX_ATTEMPTS = 3;

function view(row: DispatchRow): WorkflowDispatchView {
  return {
    id: row.id,
    operationId: row.operation_id,
    status: row.status,
    attemptCount: row.attempt_count,
    maxAttempts: row.max_attempts,
    lastErrorCode: row.last_error_code
  };
}

function messageFor(row: DispatchRow): WorkflowDeliveryMessage {
  return { schemaVersion: 1, dispatchId: row.id, operationId: row.operation_id, attempt: row.attempt_count + 1 };
}

function isMessage(value: unknown): value is WorkflowDeliveryMessage {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const candidate = value as Record<string, unknown>;
  return candidate.schemaVersion === 1
    && typeof candidate.dispatchId === 'string' && ID.test(candidate.dispatchId)
    && typeof candidate.operationId === 'string' && ID.test(candidate.operationId)
    && Number.isSafeInteger(candidate.attempt) && Number(candidate.attempt) >= 1 && Number(candidate.attempt) <= 10
    && Object.keys(candidate).every((key) => ['schemaVersion', 'dispatchId', 'operationId', 'attempt'].includes(key));
}

async function event(
  env: AppEnv['Bindings'], dispatchID: string,
  eventType: 'created' | 'approval_paused' | 'approval_resumed' | 'enqueued' | 'duplicate_ignored' | 'attempt_started' | 'retry_scheduled' | 'succeeded' | 'stale' | 'dead_lettered' | 'recovered',
  attempt: number,
  details: Record<string, unknown>
): Promise<void> {
  await env.DB.prepare(
    'INSERT INTO workflow_delivery_events (dispatch_id, event_type, attempt, details_json) VALUES (?, ?, ?, ?)'
  ).bind(dispatchID, eventType, attempt, JSON.stringify(details)).run();
}

async function dispatch(env: AppEnv['Bindings'], dispatchID: string): Promise<DispatchRow | null> {
  return env.DB.prepare('SELECT id, operation_id, status, attempt_count, max_attempts, last_error_code FROM workflow_delivery_dispatches WHERE id = ?')
    .bind(dispatchID).first<DispatchRow>();
}

async function operation(env: AppEnv['Bindings'], operationID: string): Promise<OperationRow | null> {
  return env.DB.prepare('SELECT id, status FROM agent_operations WHERE id = ?').bind(operationID).first<OperationRow>();
}

/** Creates one durable dispatch per exact operation. A proposed operation pauses; it never enters a queue before approval. */
export async function createWorkflowDelivery(
  env: AppEnv['Bindings'], operationID: string, maxAttempts = MAX_ATTEMPTS
): Promise<WorkflowDispatchView | null> {
  if (!ID.test(operationID) || !Number.isSafeInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 10) return null;
  const existing = await env.DB.prepare('SELECT id, operation_id, status, attempt_count, max_attempts, last_error_code FROM workflow_delivery_dispatches WHERE operation_id = ?')
    .bind(operationID).first<DispatchRow>();
  if (existing) return view(existing);
  const source = await operation(env, operationID);
  if (!source || !['proposed', 'approved'].includes(source.status)) return null;
  const id = crypto.randomUUID();
  const status = source.status === 'approved' ? 'pending' : 'waiting_approval';
  await env.DB.prepare(
    'INSERT INTO workflow_delivery_dispatches (id, operation_id, status, max_attempts) VALUES (?, ?, ?, ?)'
  ).bind(id, operationID, status, maxAttempts).run();
  await event(env, id, 'created', 0, { status });
  if (status === 'waiting_approval') await event(env, id, 'approval_paused', 0, {});
  return dispatch(env, id).then((row) => row ? view(row) : null);
}

/** Moves a previously paused exact operation into the durable outbox after its owner has approved it. */
export async function resumeApprovedWorkflowDelivery(
  env: AppEnv['Bindings'], dispatchID: string
): Promise<WorkflowDispatchView | null> {
  const current = await dispatch(env, dispatchID);
  if (!current || current.status !== 'waiting_approval') return current ? view(current) : null;
  const source = await operation(env, current.operation_id);
  if (!source || source.status !== 'approved') return view(current);
  await env.DB.prepare(
    "UPDATE workflow_delivery_dispatches SET status = 'pending', updated_at = datetime('now') WHERE id = ? AND status = 'waiting_approval'"
  ).bind(dispatchID).run();
  await event(env, dispatchID, 'approval_resumed', current.attempt_count, {});
  const resumed = await dispatch(env, dispatchID);
  return resumed ? view(resumed) : null;
}

/**
 * Sends a pending dispatch to an injected queue adapter. This is intentionally
 * not mounted in the Worker or wrangler configuration, so source code cannot
 * create a Cloudflare Queue or schedule work by itself.
 */
export async function enqueuePendingWorkflowDelivery(
  env: AppEnv['Bindings'], queue: WorkflowDeliveryQueue, dispatchID: string
): Promise<WorkflowDispatchView | null> {
  const current = await dispatch(env, dispatchID);
  if (!current || current.status !== 'pending') return current ? view(current) : null;
  await env.DB.prepare(
    "UPDATE workflow_delivery_dispatches SET status = 'dispatching', updated_at = datetime('now') WHERE id = ? AND status = 'pending'"
  ).bind(dispatchID).run();
  const claimed = await dispatch(env, dispatchID);
  if (!claimed || claimed.status !== 'dispatching') return claimed ? view(claimed) : null;
  try {
    await queue.send(messageFor(claimed));
  } catch {
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'pending', last_error_code = 'QUEUE_UNAVAILABLE', last_error_summary = 'Queue enqueue failed', updated_at = datetime('now') WHERE id = ? AND status = 'dispatching'"
    ).bind(dispatchID).run();
    const retry = await dispatch(env, dispatchID);
    return retry ? view(retry) : null;
  }
  await env.DB.prepare(
    "UPDATE workflow_delivery_dispatches SET status = 'queued', queued_at = datetime('now'), last_error_code = NULL, last_error_summary = NULL, updated_at = datetime('now') WHERE id = ? AND status = 'dispatching'"
  ).bind(dispatchID).run();
  await event(env, dispatchID, 'enqueued', claimed.attempt_count, { schemaVersion: 1 });
  const queued = await dispatch(env, dispatchID);
  return queued ? view(queued) : null;
}

/** Handles a trusted queue message. Duplicate deliveries are acknowledged as no-ops after success. */
export async function deliverWorkflowMessage(
  env: AppEnv['Bindings'], rawMessage: unknown, executor: WorkflowDeliveryExecutor
): Promise<WorkflowDispatchView | null> {
  if (!isMessage(rawMessage)) return null;
  const current = await dispatch(env, rawMessage.dispatchId);
  if (!current || current.operation_id !== rawMessage.operationId) return null;
  if (current.status === 'succeeded' || current.status === 'stale' || current.status === 'dead_lettered') {
    await event(env, current.id, 'duplicate_ignored', current.attempt_count, { status: current.status });
    return view(current);
  }
  if (current.status !== 'queued' || rawMessage.attempt !== current.attempt_count + 1) return view(current);
  const source = await operation(env, current.operation_id);
  if (!source || source.status === 'proposed') {
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'waiting_approval', updated_at = datetime('now') WHERE id = ? AND status = 'queued'"
    ).bind(current.id).run();
    await event(env, current.id, 'approval_paused', current.attempt_count, {});
    const paused = await dispatch(env, current.id);
    return paused ? view(paused) : null;
  }
  if (source.status !== 'approved') {
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'stale', last_error_code = 'OPERATION_NOT_APPROVED', updated_at = datetime('now') WHERE id = ?"
    ).bind(current.id).run();
    await event(env, current.id, 'stale', current.attempt_count, { code: 'OPERATION_NOT_APPROVED' });
    const stale = await dispatch(env, current.id);
    return stale ? view(stale) : null;
  }
  const attempt = current.attempt_count + 1;
  await env.DB.prepare(
    "UPDATE workflow_delivery_dispatches SET attempt_count = ?, updated_at = datetime('now') WHERE id = ? AND status = 'queued'"
  ).bind(attempt, current.id).run();
  await event(env, current.id, 'attempt_started', attempt, {});
  const outcome = await executor.execute(current.operation_id);
  if (outcome.kind === 'succeeded') {
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'succeeded', completed_at = datetime('now'), last_error_code = NULL, last_error_summary = NULL, updated_at = datetime('now') WHERE id = ?"
    ).bind(current.id).run();
    await event(env, current.id, 'succeeded', attempt, {});
  } else if (outcome.kind === 'stale') {
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'stale', last_error_code = ?, last_error_summary = 'Operation snapshot is stale', updated_at = datetime('now') WHERE id = ?"
    ).bind(outcome.code, current.id).run();
    await event(env, current.id, 'stale', attempt, { code: outcome.code });
  } else if (outcome.kind === 'retryable' && attempt < current.max_attempts) {
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'pending', last_error_code = ?, last_error_summary = 'Retry scheduled with adapter backoff', updated_at = datetime('now') WHERE id = ?"
    ).bind(outcome.code, current.id).run();
    await event(env, current.id, 'retry_scheduled', attempt, { code: outcome.code });
  } else {
    const code = outcome.code;
    await env.DB.prepare(
      "UPDATE workflow_delivery_dispatches SET status = 'dead_lettered', last_error_code = ?, last_error_summary = 'Manual recovery required', updated_at = datetime('now') WHERE id = ?"
    ).bind(code, current.id).run();
    await event(env, current.id, 'dead_lettered', attempt, { code });
  }
  const updated = await dispatch(env, current.id);
  return updated ? view(updated) : null;
}

/** Explicit owner-initiated recovery; a dead letter is never retried automatically. */
export async function recoverDeadLetteredWorkflowDelivery(
  env: AppEnv['Bindings'], dispatchID: string
): Promise<WorkflowDispatchView | null> {
  const current = await dispatch(env, dispatchID);
  if (!current || current.status !== 'dead_lettered') return current ? view(current) : null;
  const source = await operation(env, current.operation_id);
  if (!source || source.status !== 'approved') return view(current);
  await env.DB.prepare(
    "UPDATE workflow_delivery_dispatches SET status = 'pending', attempt_count = 0, last_error_code = NULL, last_error_summary = NULL, updated_at = datetime('now') WHERE id = ? AND status = 'dead_lettered'"
  ).bind(dispatchID).run();
  await event(env, dispatchID, 'recovered', 0, {});
  const recovered = await dispatch(env, dispatchID);
  return recovered ? view(recovered) : null;
}
