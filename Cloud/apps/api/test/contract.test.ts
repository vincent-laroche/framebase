import contract from '../../contracts/framebase-api-v1.openapi.json';
import { describe, expect, it } from 'vitest';

const REQUIRED_PATHS = [
  '/v1/health',
  '/v1/capabilities',
  '/v1/auth/enroll',
  '/v1/auth/enroll/challenge',
  '/v1/auth/enroll/complete',
  '/v1/auth/revoke',
  '/v1/catalog/bootstrap',
  '/v1/changes',
  '/v1/blobs/upload-initiate',
  '/v1/blobs/upload-complete',
  '/v1/blobs/multipart/initiate',
  '/v1/blobs/multipart/{uploadId}/parts/{partNumber}',
  '/v1/blobs/multipart/{uploadId}/complete',
  '/v1/blobs/multipart/{uploadId}/confirm',
  '/v1/blobs/{id}/download',
  '/v1/blobs/{id}/verification-download',
  '/v1/assets/{id}/variants/{variant}',
  '/v1/mutations'
];

describe('versioned API contract', () => {
  it('declares the Phase 4 organization contract and shared error envelope', () => {
    expect(contract.openapi).toBe('3.1.0');
    expect(contract.info.version).toBe('1.2.0');
    for (const path of REQUIRED_PATHS) expect(contract.paths).toHaveProperty(path);
    expect(contract.components.schemas.Error.required).toEqual(['error']);
    expect(contract.components.schemas.Error.properties.error.required).toEqual(['code', 'message', 'requestId']);
    const operations = contract.components.schemas.MutationOperation.properties.type.enum;
    expect(operations).toEqual(expect.arrayContaining(['create_tag', 'add_tag_to_assets', 'create_saved_search']));
  });
});
