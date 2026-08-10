import contract from '../../contracts/framebase-api-v1.openapi.json';
import { describe, expect, it } from 'vitest';

const REQUIRED_PATHS = [
  '/v1/health',
  '/v1/capabilities',
  '/v1/auth/enroll',
  '/v1/auth/revoke',
  '/v1/catalog/bootstrap',
  '/v1/changes',
  '/v1/blobs/upload-initiate',
  '/v1/blobs/upload-complete',
  '/v1/blobs/{id}/download',
  '/v1/mutations'
];

describe('versioned API contract', () => {
  it('declares every Phase 2 route and the shared error envelope', () => {
    expect(contract.openapi).toBe('3.1.0');
    for (const path of REQUIRED_PATHS) expect(contract.paths).toHaveProperty(path);
    expect(contract.components.schemas.Error.required).toEqual(['error']);
    expect(contract.components.schemas.Error.properties.error.required).toEqual(['code', 'message', 'requestId']);
  });
});
