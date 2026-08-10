import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';

const apiUrl = process.env.FRAMEBASE_API_URL?.replace(/\/$/, '');
const pairingCredential = process.env.FRAMEBASE_API_DEV_ENROLLMENT_SECRET;
if (!apiUrl || !pairingCredential) {
  console.error('Set FRAMEBASE_API_URL and FRAMEBASE_API_DEV_ENROLLMENT_SECRET before running this synthetic Phase 3 acceptance check.');
  process.exit(2);
}

const ASSET_COUNT = 5_000;
const ALBUM_MEMBER_COUNT = 500;
const MAX_CONCURRENT_MUTATIONS = 8;
const runId = `phase3fixture${randomUUID().replaceAll('-', '')}`;
const deviceId = `${runId}device`;
const rootFolderId = `${runId}root`;
const childFolderId = `${runId}child`;
const albumId = `${runId}album`;
const fixture = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9oQAAAABJRU5ErkJggg==', 'base64');
const sha256 = createHash('sha256').update(fixture).digest('hex');

function assetId(index) {
  return `${runId}asset${String(index).padStart(5, '0')}`;
}

async function request(path, options = {}) {
  const response = await fetch(`${apiUrl}${path}`, options);
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(`API ${response.status}: ${body?.error?.code ?? 'UNKNOWN_ERROR'}`);
  }
  return response.json();
}

async function mutate(auth, idempotencyKey, operations) {
  return request('/v1/mutations', {
    method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ operations })
  });
}

async function bootstrapAll(auth) {
  const entities = [];
  let cursor = undefined;
  do {
    const query = new URLSearchParams({ limit: '500' });
    if (cursor) query.set('cursor', cursor);
    const page = await request(`/v1/catalog/bootstrap?${query}`, { headers: auth });
    entities.push(...page.entities);
    cursor = page.nextCursor ?? undefined;
  } while (cursor);
  return entities;
}

function enrollmentKeyPair() {
  const pair = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return {
    privateKey: pair.privateKey,
    publicKey: pair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64url')
  };
}

let token;
try {
  const keys = enrollmentKeyPair();
  const challenge = await request('/v1/auth/enroll/challenge', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Pairing-Credential': pairingCredential },
    body: JSON.stringify({
      deviceId,
      deviceName: 'Framebase Phase 3 synthetic fixture',
      publicKey: keys.publicKey,
      scopes: ['library.read', 'assets.import', 'assets.metadata.write', 'assets.organize', 'originals.download']
    })
  });
  const signedPayload = `${challenge.challengeId}.${deviceId}.${challenge.challenge}`;
  const signature = sign('sha256', Buffer.from(signedPayload), { key: keys.privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  const enrollment = await request('/v1/auth/enroll/complete', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ challengeId: challenge.challengeId, signature })
  });
  token = enrollment.token;
  const auth = { Authorization: `Bearer ${token}` };

  const initiated = await request('/v1/blobs/upload-initiate', {
    method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ sha256, byteSize: fixture.byteLength, mediaType: 'image/png', originalExtension: 'png' })
  });
  if (initiated.status === 'pending_upload') {
    const upload = await fetch(initiated.upload.url, {
      method: initiated.upload.method, headers: initiated.upload.requiredHeaders, body: fixture
    });
    if (!upload.ok) throw new Error(`Synthetic direct upload failed: HTTP ${upload.status}`);
    await request('/v1/blobs/upload-complete', {
      method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ sha256, byteSize: fixture.byteLength })
    });
  } else if (initiated.status !== 'already_verified') {
    throw new Error('Synthetic blob was neither ready for upload nor verified');
  }

  await mutate(auth, `${runId}foldersroot`, [{ type: 'create_folder', targetId: rootFolderId, payload: { name: 'Phase 3 Fixture Root' } }]);
  await mutate(auth, `${runId}folderschild`, [{ type: 'create_folder', targetId: childFolderId, payload: { name: 'Phase 3 Fixture Child', parentId: rootFolderId } }]);
  await mutate(auth, `${runId}albumcreate`, [{ type: 'create_album', targetId: albumId, payload: { name: 'Phase 3 Fixture Album' } }]);

  const assetBatches = [];
  for (let start = 0; start < ASSET_COUNT; start += 25) {
    const operations = Array.from({ length: Math.min(25, ASSET_COUNT - start) }, (_, offset) => {
      const index = start + offset;
      return {
        type: 'create_asset', targetId: assetId(index),
        payload: {
          blobId: sha256,
          folderId: index % 2 === 0 ? rootFolderId : childFolderId,
          displayName: `phase3-${String(index).padStart(5, '0')}.png`,
          assetMetadata: { fixture: 'phase3', index, storageKey: `synthetic/${String(index).padStart(5, '0')}.png` }
        }
      };
    });
    assetBatches.push({ start, operations });
  }
  for (let start = 0; start < assetBatches.length; start += MAX_CONCURRENT_MUTATIONS) {
    const window = assetBatches.slice(start, start + MAX_CONCURRENT_MUTATIONS);
    await Promise.all(window.map((batch) => mutate(
      auth,
      `${runId}assets${String(batch.start).padStart(5, '0')}`,
      batch.operations
    )));
    if ((start + window.length) % 40 === 0 || start + window.length === assetBatches.length) {
      console.log(`Phase 3 fixture created ${Math.min((start + window.length) * 25, ASSET_COUNT)}/${ASSET_COUNT} synthetic assets.`);
    }
  }

  await mutate(auth, `${runId}albummembers`, [{
    type: 'add_assets_to_album', targetId: albumId, baseRevision: 1,
    payload: { assetIds: Array.from({ length: ALBUM_MEMBER_COUNT }, (_, index) => assetId(index)) }
  }]);

  const retryKey = `${runId}interruptionretry`;
  const retryOperation = [{ type: 'update_rating', targetId: assetId(0), baseRevision: 1, payload: { rating: 5 } }];
  await mutate(auth, retryKey, retryOperation);
  // Simulate a client that lost the first successful response and safely retries after restart.
  await mutate(auth, retryKey, retryOperation);

  const entities = await bootstrapAll(auth);
  // Development contains prior synthetic fixtures. A clean local rebuild reads
  // the complete snapshot; this acceptance check asserts the current fixture's
  // isolated namespace within that snapshot rather than assuming an empty D1.
  const assets = entities.filter((entity) => entity.entityType === 'asset' && entity.entityId.startsWith(runId));
  const folders = entities.filter((entity) => entity.entityType === 'folder' && entity.entityId.startsWith(runId));
  const album = entities.find((entity) => entity.entityType === 'album' && entity.entityId === albumId);
  if (assets.length !== ASSET_COUNT || folders.length !== 2 || !album) {
    throw new Error(`Clean rebuild count mismatch: assets=${assets.length}, folders=${folders.length}, album=${Boolean(album)}`);
  }
  const root = folders.find((entity) => entity.entityId === rootFolderId);
  const child = folders.find((entity) => entity.entityId === childFolderId);
  if (root?.revision !== 1 || child?.revision !== 1 || child?.payload.parentId !== rootFolderId) {
    throw new Error('Clean rebuild folder hierarchy or revision parity failed');
  }
  if (album.revision !== 2 || !Array.isArray(album.payload.assetIds) || album.payload.assetIds.length !== ALBUM_MEMBER_COUNT) {
    throw new Error('Clean rebuild album membership or revision parity failed');
  }
  const byId = new Map(assets.map((entity) => [entity.entityId, entity]));
  for (let index = 0; index < ASSET_COUNT; index += 1) {
    const asset = byId.get(assetId(index));
    const expectedFolder = index % 2 === 0 ? rootFolderId : childFolderId;
    const expectedRating = index === 0 ? 5 : 0;
    if (!asset || asset.payload.folderId !== expectedFolder || asset.payload.displayName !== `phase3-${String(index).padStart(5, '0')}.png` ||
        asset.payload.blobId !== sha256 || asset.payload.assetMetadata?.index !== index || asset.payload.assetMetadata?.storageKey !== `synthetic/${String(index).padStart(5, '0')}.png` ||
        asset.payload.rating !== expectedRating || asset.revision !== (index === 0 ? 2 : 1)) {
      throw new Error(`Clean rebuild asset parity failed at index ${index}`);
    }
  }

  const download = await request(`/v1/blobs/${sha256}/download`, { headers: auth });
  const downloaded = await fetch(download.download.url);
  if (!downloaded.ok || !Buffer.from(await downloaded.arrayBuffer()).equals(fixture)) {
    throw new Error('Verified synthetic download did not return the original fixture bytes');
  }
  console.log(`Phase 3 live fixture acceptance passed: ${ASSET_COUNT} synthetic assets, keypair enrollment, retry, rebuild parity, and byte verification (${runId}).`);
} finally {
  if (token) {
    const revoked = await fetch(`${apiUrl}/v1/auth/revoke`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Pairing-Credential': pairingCredential },
      body: JSON.stringify({ deviceId })
    });
    if (!revoked.ok) throw new Error(`Synthetic fixture device revocation failed: HTTP ${revoked.status}`);
  }
}
