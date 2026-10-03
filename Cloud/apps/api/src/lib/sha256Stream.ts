const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]);

function rotr(value: number, bits: number): number {
  return (value >>> bits) | (value << (32 - bits));
}

/** Incremental SHA-256. Callers feed bounded chunks and never retain the whole message. */
export class Sha256Sink {
  private readonly state = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ]);
  private readonly block = new Uint8Array(64);
  private blockLength = 0;
  private bytes = 0;

  update(chunk: Uint8Array): void {
    let offset = 0;
    this.bytes += chunk.byteLength;
    while (offset < chunk.byteLength) {
      const take = Math.min(64 - this.blockLength, chunk.byteLength - offset);
      this.block.set(chunk.subarray(offset, offset + take), this.blockLength);
      this.blockLength += take;
      offset += take;
      if (this.blockLength === 64) {
        this.compress(this.block);
        this.blockLength = 0;
      }
    }
  }

  digestHex(): string {
    const bitLength = BigInt(this.bytes) * 8n;
    this.block[this.blockLength] = 0x80;
    if (this.blockLength >= 56) {
      this.block.fill(0, this.blockLength + 1);
      this.compress(this.block);
      this.block.fill(0);
    } else {
      this.block.fill(0, this.blockLength + 1, 56);
    }
    new DataView(this.block.buffer, this.block.byteOffset, 64).setBigUint64(56, bitLength);
    this.compress(this.block);
    this.blockLength = 0;
    return Array.from(this.state, (word) => word.toString(16).padStart(8, '0')).join('');
  }

  private compress(block: Uint8Array): void {
    const words = new Uint32Array(64);
    const view = new DataView(block.buffer, block.byteOffset, 64);
    for (let index = 0; index < 16; index += 1) words[index] = view.getUint32(index * 4);
    for (let index = 16; index < 64; index += 1) {
      const s0 = rotr(words[index - 15], 7) ^ rotr(words[index - 15], 18) ^ (words[index - 15] >>> 3);
      const s1 = rotr(words[index - 2], 17) ^ rotr(words[index - 2], 19) ^ (words[index - 2] >>> 10);
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) >>> 0;
    }
    let a = this.state[0];
    let b = this.state[1];
    let c = this.state[2];
    let d = this.state[3];
    let e = this.state[4];
    let f = this.state[5];
    let g = this.state[6];
    let h = this.state[7];
    for (let index = 0; index < 64; index += 1) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + s1 + ch + K[index] + words[index]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + maj) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    this.state[0] = (this.state[0] + a) >>> 0;
    this.state[1] = (this.state[1] + b) >>> 0;
    this.state[2] = (this.state[2] + c) >>> 0;
    this.state[3] = (this.state[3] + d) >>> 0;
    this.state[4] = (this.state[4] + e) >>> 0;
    this.state[5] = (this.state[5] + f) >>> 0;
    this.state[6] = (this.state[6] + g) >>> 0;
    this.state[7] = (this.state[7] + h) >>> 0;
  }
}

/** Hashes an R2 object body in bounded reads. The source bytes are not retained. */
export async function sha256HexStream(stream: ReadableStream<Uint8Array>): Promise<string> {
  const sink = new Sha256Sink();
  const reader = stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value?.byteLength) sink.update(value);
    }
  } finally {
    reader.releaseLock();
  }
  return sink.digestHex();
}
