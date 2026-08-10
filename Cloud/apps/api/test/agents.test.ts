import { beforeEach, describe, expect, it } from 'vitest';
import app from '../src/index.js';
import type { Bindings } from '../src/types.js';
import { enrollDevice } from './helpers.js';
import { createTestEnv } from './testEnv.js';

interface CreatedAgent {
  identity: { id: string; name: string; scopes: string[]; status: string };
  credential: string;
}

async function seedTagAndAsset(env: Bindings): Promise<void> {
  const digest = 'a'.repeat(64);
  await env.DB.prepare(
    "INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state) VALUES (?, ?, 10, 'image/jpeg', 'jpg', 'blobs/agent.jpg', 'verified')"
  ).bind(digest, digest).run();
  await env.DB.prepare(
    "INSERT INTO assets (id, blob_id, display_name, folder_id, asset_metadata, revision) VALUES ('asset-agent', ?, 'Agent Fixture', 'system-inbox', '{}', 1)"
  ).bind(digest).run();
  await env.DB.prepare("INSERT INTO tags (id, name, revision) VALUES ('tag-agent', 'status:review', 1)").run();
}

async function createAgent(env: Bindings, ownerToken: string, scopes = ['library.read', 'assets.metadata.write']): Promise<CreatedAgent> {
  const response = await app.request('/v1/agents', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${ownerToken}` },
    body: JSON.stringify({ name: 'Synthetic Agent', scopes })
  }, env);
  expect(response.status).toBe(200);
  return response.json<CreatedAgent>();
}

function agentHeaders(agent: CreatedAgent): HeadersInit {
  return { 'Content-Type': 'application/json', Authorization: `Agent ${agent.credential}` };
}

describe('remote agent proposal adapter', () => {
  let env: Bindings;
  let ownerToken: string;

  beforeEach(async () => {
    env = createTestEnv();
    ownerToken = await enrollDevice(env, 'agent-owner', ['library.read', 'assets.metadata.write', 'assets.organize']);
    await seedTagAndAsset(env);
  });

  it('uses a hashed delegated credential, requires owner approval, applies one exact tag effect, and records attribution', async () => {
    const agent = await createAgent(env, ownerToken);
    const stored = await env.DB.prepare('SELECT credential_hash, scopes_json FROM agent_identities WHERE id = ?')
      .bind(agent.identity.id).first<{ credential_hash: string; scopes_json: string }>();
    expect(stored?.credential_hash).not.toContain(agent.credential);
    expect(JSON.parse(stored?.scopes_json ?? '[]')).toEqual(['assets.metadata.write', 'library.read']);

    const proposalResponse = await app.request('/v1/agent-operations/tag-proposals', {
      method: 'POST', headers: agentHeaders(agent),
      body: JSON.stringify({ tagId: 'tag-agent', targetAssetIds: ['asset-agent'], catalogRevision: 0 })
    }, env);
    expect(proposalResponse.status).toBe(200);
    const proposal = await proposalResponse.json<{ operation: { id: string; status: string; targetAssetIds: string[] } }>();
    expect(proposal.operation.status).toBe('proposed');
    expect(proposal.operation.targetAssetIds).toEqual(['asset-agent']);
    expect(await env.DB.prepare("SELECT * FROM asset_tags WHERE asset_id = 'asset-agent'").first()).toBeNull();

    const otherOwnerToken = await enrollDevice(env, 'other-owner', ['assets.organize']);
    const foreignApproval = await app.request(`/v1/agent-operations/${proposal.operation.id}/approve`, {
      method: 'POST', headers: { Authorization: `Bearer ${otherOwnerToken}` }
    }, env);
    expect(foreignApproval.status).toBe(404);

    const approvalResponse = await app.request(`/v1/agent-operations/${proposal.operation.id}/approve`, {
      method: 'POST', headers: { Authorization: `Bearer ${ownerToken}` }
    }, env);
    expect(approvalResponse.status).toBe(200);
    const approval = await approvalResponse.json<{ approvalToken: string; expiresAt: string }>();
    expect(approval.approvalToken.length).toBeGreaterThan(32);
    expect(new Date(approval.expiresAt).getTime()).toBeGreaterThan(Date.now());

    const otherAgent = await createAgent(env, ownerToken);
    const foreignApply = await app.request(`/v1/agent-operations/${proposal.operation.id}/apply`, {
      method: 'POST', headers: agentHeaders(otherAgent), body: JSON.stringify({ approvalToken: approval.approvalToken })
    }, env);
    expect(foreignApply.status).toBe(404);

    const appliedResponse = await app.request(`/v1/agent-operations/${proposal.operation.id}/apply`, {
      method: 'POST', headers: agentHeaders(agent), body: JSON.stringify({ approvalToken: approval.approvalToken })
    }, env);
    expect(appliedResponse.status).toBe(200);
    const applied = await appliedResponse.json<{ operation: { status: string } }>();
    expect(applied.operation.status).toBe('succeeded');
    expect(await env.DB.prepare("SELECT tag_id FROM asset_tags WHERE asset_id = 'asset-agent'").first<{ tag_id: string }>()).toEqual({ tag_id: 'tag-agent' });
    const agentAudit = await env.DB.prepare("SELECT actor_id, action FROM audit_events WHERE target_id = 'tag-agent'")
      .first<{ actor_id: string; action: string }>();
    expect(agentAudit).toEqual({ actor_id: `agent:${agent.identity.id}`, action: 'add_tag_to_assets' });

    const statusResponse = await app.request(`/v1/agent-operations/${proposal.operation.id}`, { headers: { Authorization: `Agent ${agent.credential}` } }, env);
    expect(statusResponse.status).toBe(200);
    const status = await statusResponse.json<{ audit: Array<{ event: string; details: Record<string, unknown> }> }>();
    expect(status.audit.map((event) => event.event)).toEqual(['proposal_created', 'approval_issued', 'applied']);
    expect(JSON.stringify(status.audit)).not.toContain(approval.approvalToken);

    const revoke = await app.request(`/v1/agents/${agent.identity.id}/revoke`, {
      method: 'POST', headers: { Authorization: `Bearer ${ownerToken}` }
    }, env);
    expect(revoke.status).toBe(200);
    expect((await app.request(`/v1/agent-operations/${proposal.operation.id}`, { headers: { Authorization: `Agent ${agent.credential}` } }, env)).status).toBe(401);
  });

  it('fails closed for missing scope, an expired approval, and snapshot drift without changing membership', async () => {
    const readOnlyAgent = await createAgent(env, ownerToken, ['library.read']);
    const denied = await app.request('/v1/agent-operations/tag-proposals', {
      method: 'POST', headers: agentHeaders(readOnlyAgent),
      body: JSON.stringify({ tagId: 'tag-agent', targetAssetIds: ['asset-agent'], catalogRevision: 0 })
    }, env);
    expect(denied.status).toBe(403);

    const agent = await createAgent(env, ownerToken);
    const proposed = await app.request('/v1/agent-operations/tag-proposals', {
      method: 'POST', headers: agentHeaders(agent),
      body: JSON.stringify({ tagId: 'tag-agent', targetAssetIds: ['asset-agent'], catalogRevision: 0 })
    }, env);
    const { operation } = await proposed.json<{ operation: { id: string } }>();
    const approved = await app.request(`/v1/agent-operations/${operation.id}/approve`, {
      method: 'POST', headers: { Authorization: `Bearer ${ownerToken}` }
    }, env);
    const { approvalToken } = await approved.json<{ approvalToken: string }>();
    await env.DB.prepare("UPDATE agent_operations SET approval_expires_at = '2000-01-01T00:00:00.000Z' WHERE id = ?").bind(operation.id).run();
    const expired = await app.request(`/v1/agent-operations/${operation.id}/apply`, {
      method: 'POST', headers: agentHeaders(agent), body: JSON.stringify({ approvalToken })
    }, env);
    expect(expired.status).toBe(409);
    expect(await env.DB.prepare("SELECT * FROM asset_tags WHERE asset_id = 'asset-agent'").first()).toBeNull();

    const secondProposal = await app.request('/v1/agent-operations/tag-proposals', {
      method: 'POST', headers: agentHeaders(agent),
      body: JSON.stringify({ tagId: 'tag-agent', targetAssetIds: ['asset-agent'], catalogRevision: 0 })
    }, env);
    const second = await secondProposal.json<{ operation: { id: string } }>();
    const secondApproval = await app.request(`/v1/agent-operations/${second.operation.id}/approve`, {
      method: 'POST', headers: { Authorization: `Bearer ${ownerToken}` }
    }, env);
    const { approvalToken: secondToken } = await secondApproval.json<{ approvalToken: string }>();
    await env.DB.prepare("UPDATE assets SET revision = revision + 1 WHERE id = 'asset-agent'").run();
    const stale = await app.request(`/v1/agent-operations/${second.operation.id}/apply`, {
      method: 'POST', headers: agentHeaders(agent), body: JSON.stringify({ approvalToken: secondToken })
    }, env);
    expect(stale.status).toBe(409);
    const status = await env.DB.prepare('SELECT status FROM agent_operations WHERE id = ?').bind(second.operation.id).first<{ status: string }>();
    expect(status?.status).toBe('stale');
    expect(await env.DB.prepare("SELECT * FROM asset_tags WHERE asset_id = 'asset-agent'").first()).toBeNull();
  });

  it('preserves an existing tag membership and applies only the exact missing membership', async () => {
    const digest = 'b'.repeat(64);
    await env.DB.prepare(
      "INSERT INTO blobs (id, sha256, byte_size, media_type, original_extension, r2_key, upload_state) VALUES (?, ?, 11, 'image/jpeg', 'jpg', 'blobs/existing.jpg', 'verified')"
    ).bind(digest, digest).run();
    await env.DB.prepare(
      "INSERT INTO assets (id, blob_id, display_name, folder_id, asset_metadata, revision) VALUES ('asset-existing', ?, 'Existing Fixture', 'system-inbox', '{}', 1)"
    ).bind(digest).run();
    await env.DB.prepare("INSERT INTO asset_tags (asset_id, tag_id) VALUES ('asset-existing', 'tag-agent')").run();
    const agent = await createAgent(env, ownerToken);
    const proposed = await app.request('/v1/agent-operations/tag-proposals', {
      method: 'POST', headers: agentHeaders(agent),
      body: JSON.stringify({ tagId: 'tag-agent', targetAssetIds: ['asset-existing', 'asset-agent'], catalogRevision: 0 })
    }, env);
    expect(proposed.status).toBe(200);
    const { operation } = await proposed.json<{ operation: { id: string } }>();
    const stored = await env.DB.prepare('SELECT apply_asset_ids_json FROM agent_operations WHERE id = ?').bind(operation.id)
      .first<{ apply_asset_ids_json: string }>();
    expect(JSON.parse(stored?.apply_asset_ids_json ?? '[]')).toEqual(['asset-agent']);
    const approved = await app.request(`/v1/agent-operations/${operation.id}/approve`, {
      method: 'POST', headers: { Authorization: `Bearer ${ownerToken}` }
    }, env);
    const { approvalToken } = await approved.json<{ approvalToken: string }>();
    expect((await app.request(`/v1/agent-operations/${operation.id}/apply`, {
      method: 'POST', headers: agentHeaders(agent), body: JSON.stringify({ approvalToken })
    }, env)).status).toBe(200);
    const memberships = await env.DB.prepare('SELECT asset_id FROM asset_tags WHERE tag_id = ? ORDER BY asset_id').bind('tag-agent')
      .all<{ asset_id: string }>();
    expect(memberships.results.map((row) => row.asset_id)).toEqual(['asset-agent', 'asset-existing']);
  });
});
