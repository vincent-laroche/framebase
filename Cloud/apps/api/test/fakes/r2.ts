import type { R2Bucket } from '@cloudflare/workers-types';

interface StoredObject {
  body: Uint8Array;
  httpEtag: string;
}

function toBytes(value: ArrayBuffer | ArrayBufferView | string): Uint8Array {
  if (typeof value === 'string') {
    return new TextEncoder().encode(value);
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
}

/** In-memory R2Bucket fake covering only the put/head/get surface the Worker routes use. */
export function createFakeR2(): R2Bucket {
  const store = new Map<string, StoredObject>();

  return {
    async put(key: string, value: ArrayBuffer | ArrayBufferView | string) {
      const bytes = toBytes(value);
      const entry: StoredObject = { body: bytes, httpEtag: `"fake-etag-${key}"` };
      store.set(key, entry);
      return { key, size: bytes.byteLength, httpEtag: entry.httpEtag } as never;
    },
    async head(key: string) {
      const entry = store.get(key);
      if (!entry) return null;
      return { key, size: entry.body.byteLength, httpEtag: entry.httpEtag } as never;
    },
    async get(key: string) {
      const entry = store.get(key);
      if (!entry) return null;
      return {
        body: new Blob([entry.body]).stream(),
        httpEtag: entry.httpEtag,
        writeHttpMetadata(headers: Headers) {
          headers.set('etag', entry.httpEtag);
        }
      } as never;
    }
  } as unknown as R2Bucket;
}
