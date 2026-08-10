import { describe, expect, it, vi } from 'vitest';
import { FramebaseAgentAPI, FramebaseMcpError } from '../src/api.js';

const credential = '550e8400-e29b-41d4-a716-446655440000.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

describe('Framebase MCP HTTP adapter', () => {
  it('maps proposal, inspection, and exact apply to the remote agent contract without logging credential values', async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(new Response(JSON.stringify({ operation: { id: 'op-1', operation: 'addTags', status: 'proposed', targetAssetIds: ['asset-1'], catalogRevision: 7, tagId: 'tag-1', createdAt: '2026-08-10T00:00:00Z', updatedAt: '2026-08-10T00:00:00Z', expiresAt: null, result: null } }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ operation: { id: 'op-1', operation: 'addTags', status: 'approved', targetAssetIds: ['asset-1'], catalogRevision: 7, tagId: 'tag-1', createdAt: '2026-08-10T00:00:00Z', updatedAt: '2026-08-10T00:00:01Z', expiresAt: '2026-08-10T00:15:01Z', result: null }, audit: [] }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ operation: { id: 'op-1', operation: 'addTags', status: 'succeeded', targetAssetIds: ['asset-1'], catalogRevision: 7, tagId: 'tag-1', createdAt: '2026-08-10T00:00:00Z', updatedAt: '2026-08-10T00:00:02Z', expiresAt: '2026-08-10T00:15:01Z', result: { status: 'applied' } } }), { status: 200 }));
    const api = new FramebaseAgentAPI('https://framebase-api-dev.example.test', credential, fetcher);
    await api.proposeTag('tag-1', ['asset-1'], 7);
    await api.getOperation('op-1');
    await api.applyTagProposal('op-1', 'b'.repeat(43));
    expect(fetcher).toHaveBeenCalledTimes(3);
    const [proposalURL, proposalInit] = fetcher.mock.calls[0];
    expect(String(proposalURL)).toBe('https://framebase-api-dev.example.test/v1/agent-operations/tag-proposals');
    expect(proposalInit?.headers).toMatchObject({ Authorization: `Agent ${credential}` });
    expect(proposalInit?.body).toBe(JSON.stringify({ tagId: 'tag-1', targetAssetIds: ['asset-1'], catalogRevision: 7 }));
    expect(String(fetcher.mock.calls[1][0])).toContain('/v1/agent-operations/op-1');
    expect(String(fetcher.mock.calls[2][0])).toContain('/v1/agent-operations/op-1/apply');
  });

  it('fails closed for an insecure non-local endpoint and surfaces only bounded API errors', async () => {
    expect(() => new FramebaseAgentAPI('http://framebase.example.test', credential)).toThrow(FramebaseMcpError);
    const api = new FramebaseAgentAPI('https://framebase.example.test', credential, vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ error: { code: 'STALE_REVISION', message: 'Operation targets changed' } }), { status: 409 })
    ));
    await expect(api.proposeTag('tag-1', ['asset-1'], 7)).rejects.toMatchObject({ code: 'STALE_REVISION', status: 409 });
  });
});
