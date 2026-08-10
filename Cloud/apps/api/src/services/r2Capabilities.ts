import { AwsClient } from 'aws4fetch';
import type { Bindings } from '../types.js';

const CAPABILITY_LIFETIME_SECONDS = 15 * 60;

export interface R2Capability {
  url: string;
  method: 'GET' | 'PUT';
  expiresAt: string;
  requiredHeaders?: Record<string, string>;
}

function configured(env: Bindings): env is Bindings & Required<Pick<Bindings, 'R2_ACCOUNT_ID' | 'R2_ACCESS_KEY_ID' | 'R2_SECRET_ACCESS_KEY'>> {
  return Boolean(env.R2_ACCOUNT_ID && env.R2_ACCESS_KEY_ID && env.R2_SECRET_ACCESS_KEY);
}

export async function createR2Capability(
  env: Bindings,
  method: 'GET' | 'PUT',
  key: string,
  mediaType?: string
): Promise<R2Capability | null> {
  if (!configured(env)) return null;

  const bucketName = env.R2_BUCKET_NAME ?? 'framebase-blobs-dev';
  const url = new URL(`https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${bucketName}/${key}`);
  url.searchParams.set('X-Amz-Expires', String(CAPABILITY_LIFETIME_SECONDS));

  const headers = new Headers();
  if (method === 'PUT' && mediaType) headers.set('Content-Type', mediaType);

  const client = new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY
  });
  const signed = await client.sign(new Request(url, { method, headers }), { aws: { signQuery: true } });
  const expiresAt = new Date(Date.now() + CAPABILITY_LIFETIME_SECONDS * 1000).toISOString();

  return {
    url: signed.url,
    method,
    expiresAt,
    ...(method === 'PUT' && mediaType ? { requiredHeaders: { 'Content-Type': mediaType } } : {})
  };
}
