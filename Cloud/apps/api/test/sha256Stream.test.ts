import { describe, expect, it } from 'vitest';
import { Sha256Sink, sha256HexStream } from '../src/lib/sha256Stream.js';

async function subtleHex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

describe('streaming SHA-256', () => {
  it('matches WebCrypto for empty, short, and chunked messages', async () => {
    const samples = [
      new Uint8Array(),
      new TextEncoder().encode('fixture-bytes'),
      new Uint8Array(64).fill(7),
      new Uint8Array(65).fill(9),
      crypto.getRandomValues(new Uint8Array(1000))
    ];
    for (const sample of samples) {
      const sink = new Sha256Sink();
      const midpoint = Math.floor(sample.byteLength / 3);
      sink.update(sample.subarray(0, midpoint));
      sink.update(sample.subarray(midpoint));
      expect(sink.digestHex()).toBe(await subtleHex(sample));
      const stream = new Blob([sample]).stream();
      expect(await sha256HexStream(stream)).toBe(await subtleHex(sample));
    }
  });
});