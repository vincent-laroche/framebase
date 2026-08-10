import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { FramebaseAgentAPI } from './api.js';
import { createFramebaseMcpServer } from './server.js';

function config(name: 'FRAMEBASE_API_URL' | 'FRAMEBASE_AGENT_CREDENTIAL'): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

try {
  const api = new FramebaseAgentAPI(config('FRAMEBASE_API_URL'), config('FRAMEBASE_AGENT_CREDENTIAL'));
  serveStdio(() => createFramebaseMcpServer(api), {
    onerror: (error) => console.error(`Framebase MCP error: ${error.message}`)
  });
} catch (error) {
  console.error(error instanceof Error ? `Framebase MCP configuration error: ${error.message}` : 'Framebase MCP configuration error');
  process.exitCode = 1;
}
