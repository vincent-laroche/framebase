import { createHash, randomUUID } from 'node:crypto';

const apiUrl = process.env.FRAMEBASE_API_URL?.replace(/\/$/, '');
const enrollmentSecret = process.env.FRAMEBASE_API_DEV_ENROLLMENT_SECRET;
if (!apiUrl || !enrollmentSecret) {
  console.error('Set FRAMEBASE_API_URL and FRAMEBASE_API_DEV_ENROLLMENT_SECRET before running this fixture-only acceptance check.');
  process.exit(2);
}

const runId = `fixture-${randomUUID()}`;
const deviceId = `${runId}-device`;
const folderId = `${runId}-folder`;
const assetId = `${runId}-asset`;
const fixture = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL9oQAAAABJRU5ErkJggg==', 'base64');
const sha256 = createHash('sha256').update(fixture).digest('hex');

async function request(path, options = {}) {
  const response = await fetch(`${apiUrl}${path}`, options);
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new Error(`API ${response.status}: ${body?.error?.code ?? 'UNKNOWN_ERROR'}`);
  }
  return response.json();
}

let token;
try {
  const enrollment = await request('/v1/auth/enroll', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Enrollment-Secret': enrollmentSecret },
    body: JSON.stringify({
      deviceId,
      deviceName: 'Framebase Phase 2 fixture acceptance',
      publicKey: `fixture-provenance-${runId}`,
      scopes: ['library.read', 'assets.import', 'assets.metadata.write', 'assets.organize', 'originals.download']
    })
  });
  token = enrollment.token;
  const auth = { Authorization: `Bearer ${token}` };

  const initiated = await request('/v1/blobs/upload-initiate', {
    method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ sha256, byteSize: fixture.byteLength, mediaType: 'image/png', originalExtension: 'png' })
  });
  if (initiated.status === 'pending_upload') {
    const upload = await fetch(initiated.upload.url, {
      method: initiated.upload.method,
      headers: initiated.upload.requiredHeaders,
      body: fixture
    });
    if (!upload.ok) throw new Error(`Direct R2 fixture upload failed: HTTP ${upload.status}`);

    await request('/v1/blobs/upload-complete', {
      method: 'POST',
      headers: { ...auth, 'Content-Type': 'application/json' },
      body: JSON.stringify({ sha256, byteSize: fixture.byteLength })
    });
  } else if (initiated.status !== 'already_verified') {
    throw new Error('Fixture blob was neither ready for upload nor verified');
  }

  const mutate = (idempotencyKey, operations) => request('/v1/mutations', {
    method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
    body: JSON.stringify({ operations })
  });
  await mutate(`${runId}-folder`, [{ type: 'create_folder', targetId: folderId, payload: { name: 'Phase 2 Fixture' } }]);
  await mutate(`${runId}-asset`, [{
    type: 'create_asset', targetId: assetId,
    payload: { blobId: sha256, folderId, displayName: 'phase2-fixture.png' }
  }]);

  const bootstrap = await request('/v1/catalog/bootstrap?limit=500', { headers: auth });
  const fixtureAsset = bootstrap.entities.find((entity) => entity.entityType === 'asset' && entity.entityId === assetId);
  if (!fixtureAsset) throw new Error('Fresh bootstrap did not contain the fixture asset');

  await mutate(`${runId}-rating`, [{
    type: 'update_rating', targetId: assetId, baseRevision: fixtureAsset.revision, payload: { rating: 5 }
  }]);
  const changes = await request(`/v1/changes?after=${bootstrap.watermarkRevision}&limit=100`, { headers: auth });
  if (!changes.changes.some((change) => change.entityType === 'asset' && change.entityId === assetId && change.payload.rating === 5)) {
    throw new Error('Ordered change feed did not reproduce the fixture rating');
  }

  const download = await request(`/v1/blobs/${sha256}/download`, { headers: auth });
  const downloaded = await fetch(download.download.url);
  if (!downloaded.ok || !Buffer.from(await downloaded.arrayBuffer()).equals(fixture)) {
    throw new Error('Signed download did not return the verified fixture bytes');
  }

  console.log(`Phase 2 fixture acceptance passed for ${runId}.`);
} finally {
  if (token) {
    await fetch(`${apiUrl}/v1/auth/revoke`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Enrollment-Secret': enrollmentSecret },
      body: JSON.stringify({ deviceId })
    });
  }
}
