export interface FramebaseAgentOperation {
  id: string;
  operation: 'addTags';
  status: 'proposed' | 'approved' | 'succeeded' | 'stale' | 'expired' | 'failed';
  targetAssetIds: string[];
  catalogRevision: number;
  tagId: string;
  createdAt: string;
  updatedAt: string;
  expiresAt: string | null;
  result: Record<string, unknown> | null;
}

export class FramebaseMcpError extends Error {
  constructor(public readonly code: string, message: string, public readonly status: number) {
    super(message);
  }
}

export type FetchFunction = typeof fetch;

export class FramebaseAgentAPI {
  private readonly baseURL: URL;

  constructor(
    endpoint: string,
    private readonly credential: string,
    private readonly fetcher: FetchFunction = fetch
  ) {
    this.baseURL = new URL(endpoint.endsWith('/') ? endpoint : `${endpoint}/`);
    const local = this.baseURL.hostname === 'localhost' || this.baseURL.hostname === '127.0.0.1';
    if (this.baseURL.protocol !== 'https:' && !local) throw new FramebaseMcpError('INVALID_ENDPOINT', 'Framebase MCP requires an HTTPS API endpoint', 400);
    if (!/^[-A-Za-z0-9_]{3,128}\.[-A-Za-z0-9_]{32,128}$/.test(credential)) {
      throw new FramebaseMcpError('INVALID_CREDENTIAL', 'Framebase agent credential is invalid', 400);
    }
  }

  async proposeTag(tagId: string, targetAssetIds: string[], catalogRevision: number): Promise<FramebaseAgentOperation> {
    const body = await this.request('/v1/agent-operations/tag-proposals', 'POST', { tagId, targetAssetIds, catalogRevision });
    return this.operationFrom(body);
  }

  async getOperation(operationId: string): Promise<{ operation: FramebaseAgentOperation; audit: Array<Record<string, unknown>> }> {
    const body = await this.request(`/v1/agent-operations/${encodeURIComponent(operationId)}`, 'GET');
    return {
      operation: this.operationFrom(body),
      audit: Array.isArray(body.audit) ? body.audit.filter((entry): entry is Record<string, unknown> => Boolean(entry) && typeof entry === 'object') : []
    };
  }

  async applyTagProposal(operationId: string, approvalToken: string): Promise<FramebaseAgentOperation> {
    const body = await this.request(`/v1/agent-operations/${encodeURIComponent(operationId)}/apply`, 'POST', { approvalToken });
    return this.operationFrom(body);
  }

  private operationFrom(body: Record<string, unknown>): FramebaseAgentOperation {
    const operation = body.operation;
    if (!operation || typeof operation !== 'object' || Array.isArray(operation)) {
      throw new FramebaseMcpError('INVALID_RESPONSE', 'Framebase API returned an invalid operation response', 502);
    }
    return operation as FramebaseAgentOperation;
  }

  private async request(path: string, method: 'GET' | 'POST', payload?: Record<string, unknown>): Promise<Record<string, unknown>> {
    const response = await this.fetcher(new URL(path.slice(1), this.baseURL), {
      method,
      headers: {
        Authorization: `Agent ${this.credential}`,
        ...(payload ? { 'Content-Type': 'application/json' } : {})
      },
      body: payload ? JSON.stringify(payload) : undefined
    });
    let body: unknown = null;
    try { body = await response.json(); } catch { /* Error remains deliberately bounded below. */ }
    if (!response.ok) {
      const error = body && typeof body === 'object' && 'error' in body ? (body as { error?: { code?: unknown; message?: unknown } }).error : undefined;
      throw new FramebaseMcpError(
        typeof error?.code === 'string' ? error.code : 'FRAMEBASE_API_ERROR',
        typeof error?.message === 'string' ? error.message : `Framebase API request failed (${response.status})`,
        response.status
      );
    }
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new FramebaseMcpError('INVALID_RESPONSE', 'Framebase API returned an invalid response', 502);
    return body as Record<string, unknown>;
  }
}
