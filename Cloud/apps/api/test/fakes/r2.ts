import type { R2Bucket } from '@cloudflare/workers-types';

interface StoredObject {
  body: Uint8Array;
  httpEtag: string;
  httpMetadata?: { contentType?: string };
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
    async put(key: string, value: ArrayBuffer | ArrayBufferView | string, options?: { httpMetadata?: { contentType?: string } }) {
      const bytes = toBytes(value);
      const entry: StoredObject = { body: bytes, httpEtag: `"fake-etag-${key}"`, httpMetadata: options?.httpMetadata };
      store.set(key, entry);
      return { key, size: bytes.byteLength, httpEtag: entry.httpEtag } as never;
    },
    async head(key: string) {
      const entry = store.get(key);
      if (!entry) return null;
      return { key, size: entry.body.byteLength, httpEtag: entry.httpEtag, httpMetadata: entry.httpMetadata } as never;
    },
    async get(key: string) {
      const entry = store.get(key);
      if (!entry) return null;
      return {
        body: new Blob([entry.body]).stream(),
        size: entry.body.byteLength,
        httpEtag: entry.httpEtag,
        httpMetadata: entry.httpMetadata,
        arrayBuffer: async () => entry.body.slice().buffer,
        writeHttpMetadata(headers: Headers) {
          headers.set('etag', entry.httpEtag);
          if (entry.httpMetadata?.contentType) headers.set('Content-Type', entry.httpMetadata.contentType);
        }
      } as never;
    },
    async delete(key: string) {
      store.delete(key);
    }
  } as unknown as R2Bucket;
}
