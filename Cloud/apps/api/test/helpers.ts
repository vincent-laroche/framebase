import app from '../src/index.js';
import type { Bindings } from '../src/types.js';

export async function enrollDevice(
  env: Bindings,
  deviceId: string,
  scopes?: string[]
): Promise<string> {
  const res = await app.request(
    '/v1/auth/enroll',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        deviceId,
        deviceName: `Test Device ${deviceId}`,
        publicKey: `test-public-key-${deviceId}`,
        scopes
      })
    },
    env
  );
  const body = await res.json<{ token: string }>();
  return body.token;
}
