import type { Context } from 'hono';
import type { AppEnv } from '../types.js';

export function apiError(
  c: Context<AppEnv>,
  status: 400 | 401 | 403 | 404 | 409 | 422 | 429 | 500 | 503,
  code: string,
  message: string
): Response {
  c.header('X-Request-Id', c.get('requestId'));
  return c.json({ error: { code, message, requestId: c.get('requestId') } }, status);
}

export function parseBoundedInteger(value: string | undefined, fallback: number, maximum: number): number | null {
  if (value === undefined) return fallback;
  if (!/^[0-9]+$/.test(value)) return null;
  const parsed = Number(value);
  return parsed >= 0 && parsed <= maximum ? parsed : null;
}

export async function sha256Hex(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, '0')).join('');
}

function canonicalize(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalize).join(',')}]`;
  if (value && typeof value === 'object') {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalize(record[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

export async function fingerprint(value: unknown): Promise<string> {
  const encoded = new TextEncoder().encode(canonicalize(value));
  return sha256Hex(encoded.slice().buffer as ArrayBuffer);
}
