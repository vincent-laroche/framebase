import type { R2Bucket } from '@cloudflare/workers-types';

interface StoredObject {
  body: Uint8Array;
  httpEtag: string;
  httpMetadata?: { contentType?: string };
}

interface MultipartUpload {
  key: string;
  httpMetadata?: { contentType?: string };
  parts: Map<number, { body: Uint8Array; etag: string }>;
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

/** In-memory R2Bucket fake covering the upload surfaces exercised by Worker route tests. */
export function createFakeR2(): R2Bucket {
  const store = new Map<string, StoredObject>();
  const uploads = new Map<string, MultipartUpload>();

  function multipartHandle(key: string, uploadId: string) {
    const upload = uploads.get(uploadId);
    if (!upload || upload.key !== key) throw new Error('No such multipart upload');
    return {
      key,
      uploadId,
      async uploadPart(partNumber: number, value: ArrayBuffer | ArrayBufferView | string) {
        const body = toBytes(value);
        const etag = `"fake-part-${uploadId}-${partNumber}-${body.byteLength}"`;
        upload.parts.set(partNumber, { body, etag });
        return { partNumber, etag };
      },
      async abort() { uploads.delete(uploadId); },
      async complete(parts: Array<{ partNumber: number; etag: string }>) {
        const chunks = parts.map((part) => {
          const stored = upload.parts.get(part.partNumber);
          if (!stored || stored.etag !== part.etag) throw new Error('Multipart parts did not match');
          return stored.body;
        });
        const length = chunks.reduce((total, chunk) => total + chunk.byteLength, 0);
        const body = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
        const entry: StoredObject = { body, httpEtag: `"fake-etag-${key}"`, httpMetadata: upload.httpMetadata };
        store.set(key, entry);
        uploads.delete(uploadId);
        return { key, size: body.byteLength, httpEtag: entry.httpEtag, httpMetadata: entry.httpMetadata } as never;
      }
    };
  }

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
    async createMultipartUpload(key: string, options?: { httpMetadata?: { contentType?: string } }) {
      const uploadId = `fake-upload-${crypto.randomUUID()}`;
      uploads.set(uploadId, { key, httpMetadata: options?.httpMetadata, parts: new Map() });
      return multipartHandle(key, uploadId) as never;
    },
    resumeMultipartUpload(key: string, uploadId: string) {
      return multipartHandle(key, uploadId) as never;
    },
    async delete(key: string) {
      store.delete(key);
    }
  } as unknown as R2Bucket;
}
