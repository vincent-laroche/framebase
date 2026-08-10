import { McpServer } from '@modelcontextprotocol/server';
import * as z from 'zod/v4';
import { FramebaseAgentAPI, FramebaseMcpError } from './api.js';

function toolResult(value: unknown, isError = false) {
  return { content: [{ type: 'text' as const, text: JSON.stringify(value) }], ...(isError ? { isError: true } : {}) };
}

function guarded<T>(action: () => Promise<T>) {
  return action().then((value) => toolResult(value)).catch((error: unknown) => {
    if (error instanceof FramebaseMcpError) return toolResult({ error: { code: error.code, message: error.message } }, true);
    return toolResult({ error: { code: 'MCP_INTERNAL_ERROR', message: 'Framebase MCP request failed' } }, true);
  });
}

/**
 * The MCP surface is deliberately only a thin transport adapter. It does not
 * perform catalog mutations, mint credentials, or retain approval values.
 */
export function createFramebaseMcpServer(api: FramebaseAgentAPI): McpServer {
  const server = new McpServer(
    { name: 'framebase-mcp', version: '0.1.0' },
    { instructions: 'Framebase changes are proposal-first. Create a tag proposal, have its owner approve it outside MCP, then apply the exact short-lived approval. Never invent asset IDs, catalog revisions, tags, or approval values.' }
  );
  server.registerTool(
    'framebase_propose_tag',
    {
      description: 'Create a dry-run proposal to add an existing Framebase tag. This changes nothing until a separate owner approval is issued.',
      inputSchema: z.object({ tagId: z.string().min(3).max(128), targetAssetIds: z.array(z.string().min(3).max(128)).min(1).max(500), catalogRevision: z.number().int().nonnegative() })
    },
    ({ tagId, targetAssetIds, catalogRevision }) => guarded(() => api.proposeTag(tagId, targetAssetIds, catalogRevision))
  );
  server.registerTool(
    'framebase_get_operation',
    {
      description: 'Read the current status and redacted audit history for one Framebase agent operation.',
      inputSchema: z.object({ operationId: z.string().uuid() })
    },
    ({ operationId }) => guarded(() => api.getOperation(operationId))
  );
  server.registerTool(
    'framebase_apply_tag_proposal',
    {
      description: 'Apply an owner-approved Framebase tag proposal. The approval must match the agent, exact targets, and unchanged snapshot and is short lived.',
      inputSchema: z.object({ operationId: z.string().uuid(), approvalToken: z.string().min(32).max(128) })
    },
    ({ operationId, approvalToken }) => guarded(() => api.applyTagProposal(operationId, approvalToken))
  );
  return server;
}
