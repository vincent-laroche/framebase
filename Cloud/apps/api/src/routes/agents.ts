import { Hono } from 'hono';
import { apiError, fingerprint, sha256Hex } from '../lib/api.js';
import { requireAgentAuth } from '../middleware/agentAuth.js';
import { requireAuth } from '../middleware/auth.js';
import { applyMutationBatch } from './mutations.js';
import type { AppEnv } from '../types.js';

export const agentsRouter = new Hono<AppEnv>();

const ID = /^[A-Za-z0-9_-]{3,128}$/;
const AGENT_SCOPES = new Set([
  'library.read',
  'assets.metadata.write',
  'assets.organize',
  'intelligence.run',
  'workflows.run',
  'exports.read'
]);
const APPROVAL_LIFETIME_MS = 15 * 60 * 1000;

interface AgentRow {
  id: string;
  owner_device_id: string;
  name: string;
  scopes_json: string;
  status: 'active' | 'revoked';
}

interface OperationRow {
  id: string;
  agent_id: string;
  kind: 'addTags';
  status: 'proposed' | 'approved' | 'succeeded' | 'stale' | 'expired' | 'failed';
  target_asset_ids_json: string;
  apply_asset_ids_json: string;
  tag_id: string;
  tag_revision: number;
  catalog_revision: number;
  snapshot_sha256: string;
  approval_token_hash: string | null;
  approval_expires_at: string | null;
  applied_mutation_id: string | null;
  result_json: string | null;
  created_at: string;
  updated_at: string;
}

interface Snapshot {
  catalogRevision: number;
  tagRevision: number;
  targetAssetIDs: string[];
  applyAssetIDs: string[];
  sha256: string;
}

function randomBase64URL(byteLength: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

function utf8Buffer(value: string): ArrayBuffer {
  const bytes = new TextEncoder().encode(value);
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function isExactRecord(value: unknown, fields: string[]): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value as Record<string, unknown>).every((key) => fields.includes(key));
}

function parseAssetIDs(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length === 0 || value.length > 500 || value.some((id) => typeof id !== 'string' || !ID.test(id))) return null;
  const ids = [...new Set(value)].sort();
  return ids.length === value.length ? ids : null;
}

function parseScopes(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length === 0 || value.length > AGENT_SCOPES.size || value.some((scope) => typeof scope !== 'string' || !AGENT_SCOPES.has(scope))) return null;
  const scopes = [...new Set(value)].sort();
  return scopes.length === value.length ? scopes : null;
}

function publicIdentity(agent: AgentRow) {
  return { id: agent.id, name: agent.name, scopes: JSON.parse(agent.scopes_json), status: agent.status };
}

function publicOperation(operation: OperationRow) {
  return {
    id: operation.id,
    operation: operation.kind,
    status: operation.status,
    targetAssetIds: JSON.parse(operation.target_asset_ids_json),
    catalogRevision: operation.catalog_revision,
    tagId: operation.tag_id,
    createdAt: operation.created_at,
    updatedAt: operation.updated_at,
    expiresAt: operation.approval_expires_at,
    result: operation.result_json ? JSON.parse(operation.result_json) : null
  };
}

async function writeAudit(
  env: AppEnv['Bindings'],
  agentID: string,
  operationID: string | null,
  actorID: string,
  eventType: 'identity_created' | 'identity_revoked' | 'proposal_created' | 'approval_issued' | 'applied' | 'stale' | 'expired' | 'failed',
  details: Record<string, unknown>
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO agent_operation_audit_events (agent_id, operation_id, actor_id, event_type, details_json)
     VALUES (?, ?, ?, ?, ?)`
  ).bind(agentID, operationID, actorID, eventType, JSON.stringify(details)).run();
}

async function loadOperation(env: AppEnv['Bindings'], operationID: string, agentID: string): Promise<OperationRow | null> {
  return env.DB.prepare('SELECT * FROM agent_operations WHERE id = ? AND agent_id = ?')
    .bind(operationID, agentID).first<OperationRow>();
}

async function snapshotFor(
  env: AppEnv['Bindings'],
  tagID: string,
  targetAssetIDs: string[]
): Promise<Snapshot | null> {
  const encodedIDs = JSON.stringify(targetAssetIDs);
  const [revisionRow, tag, assets, memberships] = await Promise.all([
    env.DB.prepare('SELECT COALESCE(MAX(revision), 0) AS revision FROM change_events').first<{ revision: number }>(),
    env.DB.prepare('SELECT id, revision FROM tags WHERE id = ?').bind(tagID).first<{ id: string; revision: number }>(),
    env.DB.prepare(`SELECT id, revision, status FROM assets WHERE id IN (SELECT value FROM json_each(?)) ORDER BY id`)
      .bind(encodedIDs).all<{ id: string; revision: number; status: string }>(),
    env.DB.prepare(`SELECT asset_id FROM asset_tags WHERE tag_id = ? AND asset_id IN (SELECT value FROM json_each(?)) ORDER BY asset_id`)
      .bind(tagID, encodedIDs).all<{ asset_id: string }>()
  ]);
  if (!tag || assets.results.length !== targetAssetIDs.length || assets.results.some((asset) => asset.status !== 'active')) return null;
  const existing = new Set(memberships.results.map((row) => row.asset_id));
  const applyAssetIDs = targetAssetIDs.filter((assetID) => !existing.has(assetID));
  const sha256 = await fingerprint({
    catalogRevision: revisionRow?.revision ?? 0,
    tag: { id: tag.id, revision: tag.revision },
    assets: assets.results.map((asset) => ({ id: asset.id, revision: asset.revision, status: asset.status })),
    existingMembershipAssetIDs: memberships.results.map((row) => row.asset_id)
  });
  return {
    catalogRevision: revisionRow?.revision ?? 0,
    tagRevision: tag.revision,
    targetAssetIDs,
    applyAssetIDs,
    sha256
  };
}

function snapshotMatches(operation: OperationRow, current: Snapshot | null): boolean {
  if (!current) return false;
  return current.catalogRevision === operation.catalog_revision
    && current.tagRevision === operation.tag_revision
    && current.sha256 === operation.snapshot_sha256
    && JSON.stringify(current.applyAssetIDs) === operation.apply_asset_ids_json;
}

async function markOperation(
  env: AppEnv['Bindings'], operation: OperationRow, status: 'stale' | 'expired' | 'failed', actorID: string, event: 'stale' | 'expired' | 'failed'
): Promise<void> {
  if (operation.status === status) return;
  await env.DB.prepare("UPDATE agent_operations SET status = ?, updated_at = datetime('now') WHERE id = ? AND status IN ('proposed', 'approved')")
    .bind(status, operation.id).run();
  await writeAudit(env, operation.agent_id, operation.id, actorID, event, { status });
}

agentsRouter.post('/agents', requireAuth('assets.organize'), async (c) => {
  let body: { name?: unknown; scopes?: unknown };
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  if (!isExactRecord(body, ['name', 'scopes']) || typeof body.name !== 'string' || body.name.trim().length === 0 || body.name.trim().length > 120) {
    return apiError(c, 400, 'INVALID_REQUEST', 'Agent name is invalid');
  }
  const scopes = parseScopes(body.scopes);
  const ownerDeviceID = c.get('deviceId');
  const ownerScopes = c.get('scopes') ?? [];
  if (!ownerDeviceID) return apiError(c, 401, 'UNAUTHORIZED', 'Authenticated device identity is unavailable');
  if (!scopes || scopes.some((scope) => !ownerScopes.includes(scope))) {
    return apiError(c, 403, 'FORBIDDEN', 'Delegated scopes must be a subset of the owner device scopes');
  }

  const agentID = crypto.randomUUID();
  const secret = randomBase64URL(32);
  const credential = `${agentID}.${secret}`;
  const credentialHash = await sha256Hex(utf8Buffer(credential));
  const agent: AgentRow = { id: agentID, owner_device_id: ownerDeviceID, name: body.name.trim(), scopes_json: JSON.stringify(scopes), status: 'active' };
  await c.env.DB.prepare(
    `INSERT INTO agent_identities (id, owner_device_id, name, scopes_json, credential_hash, status)
     VALUES (?, ?, ?, ?, ?, 'active')`
  ).bind(agent.id, agent.owner_device_id, agent.name, agent.scopes_json, credentialHash).run();
  await writeAudit(c.env, agent.id, null, ownerDeviceID, 'identity_created', { scopeCount: scopes.length });
  return c.json({ identity: publicIdentity(agent), credential });
});

agentsRouter.post('/agents/:agentId/revoke', requireAuth('assets.organize'), async (c) => {
  const agentID = c.req.param('agentId');
  const deviceID = c.get('deviceId');
  if (!ID.test(agentID)) return apiError(c, 400, 'INVALID_REQUEST', 'agentId is invalid');
  if (!deviceID) return apiError(c, 401, 'UNAUTHORIZED', 'Authenticated device identity is unavailable');
  const agent = await c.env.DB.prepare('SELECT id, owner_device_id, name, scopes_json, status FROM agent_identities WHERE id = ?')
    .bind(agentID).first<AgentRow>();
  if (!agent) return apiError(c, 404, 'AGENT_NOT_FOUND', 'Agent identity was not found');
  if (agent.owner_device_id !== deviceID) return apiError(c, 403, 'FORBIDDEN', 'Only the owning device can revoke this agent');
  await c.env.DB.prepare("UPDATE agent_identities SET status = 'revoked', revoked_at = datetime('now') WHERE id = ? AND status = 'active'")
    .bind(agentID).run();
  await writeAudit(c.env, agentID, null, deviceID, 'identity_revoked', {});
  return c.json({ identity: { ...publicIdentity(agent), status: 'revoked' } });
});

agentsRouter.post('/agent-operations/tag-proposals', requireAgentAuth('assets.metadata.write'), async (c) => {
  let body: { tagId?: unknown; targetAssetIds?: unknown; catalogRevision?: unknown };
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  if (!isExactRecord(body, ['tagId', 'targetAssetIds', 'catalogRevision']) || typeof body.tagId !== 'string' || !ID.test(body.tagId)
    || !Number.isSafeInteger(body.catalogRevision) || Number(body.catalogRevision) < 0) {
    return apiError(c, 400, 'INVALID_REQUEST', 'Tag proposal fields are invalid');
  }
  const targetAssetIDs = parseAssetIDs(body.targetAssetIds);
  const agentID = c.get('agentId');
  if (!targetAssetIDs || !agentID) return apiError(c, 400, 'INVALID_REQUEST', 'Tag proposal target assets are invalid');
  const snapshot = await snapshotFor(c.env, body.tagId, targetAssetIDs);
  if (!snapshot) return apiError(c, 409, 'STALE_REVISION', 'The tag or target assets are unavailable or changed');
  if (snapshot.catalogRevision !== body.catalogRevision) return apiError(c, 409, 'STALE_REVISION', 'Catalog revision changed; create a new proposal');
  if (snapshot.applyAssetIDs.length === 0) return apiError(c, 409, 'NO_EFFECT', 'Every target already has this tag');

  const operationID = crypto.randomUUID();
  await c.env.DB.prepare(
    `INSERT INTO agent_operations (id, agent_id, kind, status, target_asset_ids_json, apply_asset_ids_json, tag_id, tag_revision, catalog_revision, snapshot_sha256)
     VALUES (?, ?, 'addTags', 'proposed', ?, ?, ?, ?, ?, ?)`
  ).bind(operationID, agentID, JSON.stringify(snapshot.targetAssetIDs), JSON.stringify(snapshot.applyAssetIDs), body.tagId, snapshot.tagRevision, snapshot.catalogRevision, snapshot.sha256).run();
  const operation = await loadOperation(c.env, operationID, agentID);
  if (!operation) return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Operation record was unavailable');
  await writeAudit(c.env, agentID, operationID, `agent:${agentID}`, 'proposal_created', { targetCount: snapshot.targetAssetIDs.length, applyCount: snapshot.applyAssetIDs.length, catalogRevision: snapshot.catalogRevision });
  return c.json({ operation: publicOperation(operation) });
});

agentsRouter.post('/agent-operations/:operationId/approve', requireAuth('assets.organize'), async (c) => {
  const operationID = c.req.param('operationId');
  const deviceID = c.get('deviceId');
  if (!ID.test(operationID) || !deviceID) return apiError(c, 400, 'INVALID_REQUEST', 'operationId is invalid');
  const operation = await c.env.DB.prepare(
    `SELECT operations.* FROM agent_operations AS operations
     JOIN agent_identities AS agents ON agents.id = operations.agent_id
     WHERE operations.id = ? AND agents.owner_device_id = ?`
  ).bind(operationID, deviceID).first<OperationRow>();
  if (!operation) return apiError(c, 404, 'OPERATION_NOT_FOUND', 'Reviewable operation was not found');
  if (operation.status !== 'proposed') return apiError(c, 409, 'OPERATION_NOT_REVIEWABLE', 'Operation is no longer awaiting approval');
  if (!snapshotMatches(operation, await snapshotFor(c.env, operation.tag_id, JSON.parse(operation.target_asset_ids_json)))) {
    await markOperation(c.env, operation, 'stale', deviceID, 'stale');
    return apiError(c, 409, 'STALE_REVISION', 'Operation targets changed; create a new proposal');
  }

  const approvalToken = randomBase64URL(32);
  const tokenHash = await sha256Hex(utf8Buffer(approvalToken));
  const expiresAt = new Date(Date.now() + APPROVAL_LIFETIME_MS).toISOString();
  await c.env.DB.prepare(
    "UPDATE agent_operations SET status = 'approved', approval_token_hash = ?, approval_expires_at = ?, updated_at = datetime('now') WHERE id = ? AND status = 'proposed'"
  ).bind(tokenHash, expiresAt, operation.id).run();
  await writeAudit(c.env, operation.agent_id, operation.id, deviceID, 'approval_issued', { expiresAt });
  return c.json({ operationId: operation.id, approvalToken, expiresAt });
});

agentsRouter.post('/agent-operations/:operationId/apply', requireAgentAuth('assets.metadata.write'), async (c) => {
  const operationID = c.req.param('operationId');
  const agentID = c.get('agentId');
  if (!ID.test(operationID) || !agentID) return apiError(c, 400, 'INVALID_REQUEST', 'operationId is invalid');
  let body: { approvalToken?: unknown };
  try { body = await c.req.json(); } catch { return apiError(c, 400, 'INVALID_REQUEST', 'Request body must be JSON'); }
  if (!isExactRecord(body, ['approvalToken']) || typeof body.approvalToken !== 'string' || body.approvalToken.length < 32 || body.approvalToken.length > 128) {
    return apiError(c, 400, 'INVALID_REQUEST', 'approvalToken is invalid');
  }
  const operation = await loadOperation(c.env, operationID, agentID);
  if (!operation) return apiError(c, 404, 'OPERATION_NOT_FOUND', 'Operation was not found');
  if (operation.status === 'succeeded') return c.json({ operation: publicOperation(operation) });
  if (operation.status !== 'approved' || !operation.approval_token_hash || !operation.approval_expires_at) {
    return apiError(c, 409, 'OPERATION_NOT_APPROVED', 'Operation does not have a valid approval');
  }
  if (new Date(operation.approval_expires_at).getTime() < Date.now()) {
    await markOperation(c.env, operation, 'expired', `agent:${agentID}`, 'expired');
    return apiError(c, 409, 'APPROVAL_EXPIRED', 'Approval has expired; create a new proposal');
  }
  const tokenHash = await sha256Hex(utf8Buffer(body.approvalToken));
  if (!constantTimeEqual(operation.approval_token_hash, tokenHash)) return apiError(c, 403, 'FORBIDDEN', 'Approval does not match this operation');
  if (!snapshotMatches(operation, await snapshotFor(c.env, operation.tag_id, JSON.parse(operation.target_asset_ids_json)))) {
    await markOperation(c.env, operation, 'stale', `agent:${agentID}`, 'stale');
    return apiError(c, 409, 'STALE_REVISION', 'Operation targets changed; create a new proposal');
  }

  const applied = await applyMutationBatch(
    c.env,
    `agent:${agentID}`,
    c.get('agentScopes') ?? [],
    `agent-op-${operation.id}`,
    [{ type: 'add_tag_to_assets', targetId: operation.tag_id, baseRevision: operation.tag_revision, payload: { assetIds: JSON.parse(operation.apply_asset_ids_json) } }]
  );
  if (!applied.ok) {
    if (applied.status === 409) await markOperation(c.env, operation, 'stale', `agent:${agentID}`, 'stale');
    else await markOperation(c.env, operation, 'failed', `agent:${agentID}`, 'failed');
    return apiError(c, applied.status, applied.code, applied.message);
  }
  await c.env.DB.prepare(
    "UPDATE agent_operations SET status = 'succeeded', applied_mutation_id = ?, result_json = ?, updated_at = datetime('now') WHERE id = ?"
  ).bind(`agent-op-${operation.id}`, JSON.stringify(applied.body), operation.id).run();
  await writeAudit(c.env, agentID, operation.id, `agent:${agentID}`, 'applied', { appliedCount: JSON.parse(operation.apply_asset_ids_json).length });
  const completed = await loadOperation(c.env, operationID, agentID);
  if (!completed) return apiError(c, 500, 'SERVER_MISCONFIGURED', 'Completed operation was unavailable');
  return c.json({ operation: publicOperation(completed) });
});

agentsRouter.get('/agent-operations/:operationId', requireAgentAuth('library.read'), async (c) => {
  const operationID = c.req.param('operationId');
  const agentID = c.get('agentId');
  if (!ID.test(operationID) || !agentID) return apiError(c, 400, 'INVALID_REQUEST', 'operationId is invalid');
  const operation = await loadOperation(c.env, operationID, agentID);
  if (!operation) return apiError(c, 404, 'OPERATION_NOT_FOUND', 'Operation was not found');
  const audit = await c.env.DB.prepare(
    'SELECT actor_id, event_type, details_json, created_at FROM agent_operation_audit_events WHERE operation_id = ? ORDER BY id'
  ).bind(operationID).all<{ actor_id: string; event_type: string; details_json: string; created_at: string }>();
  return c.json({
    operation: publicOperation(operation),
    audit: audit.results.map((event) => ({ actorId: event.actor_id, event: event.event_type, details: JSON.parse(event.details_json), createdAt: event.created_at }))
  });
});

function constantTimeEqual(left: string, right: string): boolean {
  let difference = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  return difference === 0;
}
