import contract from '../../contracts/framebase-api-v1.openapi.json';
import { describe, expect, it } from 'vitest';

const DOCUMENTED_ROUTE_METHODS: Record<string, string[]> = {
  '/v1/health': ['get'],
  '/v1/capabilities': ['get'],
  '/v1/auth/enroll': ['post'],
  '/v1/auth/enroll/challenge': ['post'],
  '/v1/auth/enroll/complete': ['post'],
  '/v1/auth/revoke': ['post'],
  '/v1/catalog/bootstrap': ['get'],
  '/v1/changes': ['get'],
  '/v1/blobs/upload-initiate': ['post'],
  '/v1/blobs/upload-complete': ['post'],
  '/v1/blobs/multipart/initiate': ['post'],
  '/v1/blobs/multipart/{uploadId}/parts/{partNumber}': ['put'],
  '/v1/blobs/multipart/{uploadId}/complete': ['post'],
  '/v1/blobs/multipart/{uploadId}/confirm': ['post'],
  '/v1/blobs/{id}/download': ['get'],
  '/v1/blobs/{id}/verification-download': ['get'],
  '/v1/assets/{id}/variants/{variant}': ['get'],
  '/v1/mutations': ['post']
};

const APPROVED_REQUIRED_FIELDS: Record<string, string[]> = {
  Error: ['error'],
  ChangeEvent: ['revision', 'entityType', 'entityId', 'operation', 'payload', 'actorId', 'createdAt'],
  AgentOperationRequest: ['id', 'operation', 'targetAssetIds', 'catalogRevision'],
  AgentApprovalToken: ['id', 'operationId', 'targetAssetIds', 'catalogRevision', 'expiresAt'],
  MutationOperation: ['type', 'targetId', 'payload']
};

describe('versioned API contract', () => {
  it('declares the Phase 4 organization contract and shared error envelope', () => {
    expect(contract.openapi).toBe('3.1.0');
    expect(contract.info.version).toBe('1.2.0');
    expect(Object.keys(contract.paths).sort()).toEqual(Object.keys(DOCUMENTED_ROUTE_METHODS).sort());
    for (const [path, methods] of Object.entries(DOCUMENTED_ROUTE_METHODS)) {
      expect(Object.keys(contract.paths[path]).sort()).toEqual(methods);
    }
    expect(contract.components.schemas.Error.required).toEqual(['error']);
    expect(contract.components.schemas.Error.properties.error.required).toEqual(['code', 'message', 'requestId']);
    const operations = contract.components.schemas.MutationOperation.properties.type.enum;
    expect(operations).toEqual(expect.arrayContaining(['create_tag', 'add_tag_to_assets', 'create_saved_search']));
  });

  it('keeps the Phase 8 preview vocabulary proposal-first and excludes unsafe capabilities', () => {
    const schemas = contract.components.schemas;
    const scopes = schemas.AgentScope.enum;
    const operations = schemas.AgentOperationKind.enum;
    expect(scopes).toEqual(expect.arrayContaining(['library.read', 'assets.organize', 'intelligence.run']));
    expect(operations).toEqual(expect.arrayContaining(['searchAssets', 'moveAssets', 'runWorkflow']));
    expect(operations).not.toContain('permanentPurge');
    expect(operations).not.toContain('rawStorageAccess');
    expect(schemas.AgentOperationRequest.required).toEqual(['id', 'operation', 'targetAssetIds', 'catalogRevision']);
    expect(schemas.AgentApprovalToken.required).toEqual(['id', 'operationId', 'targetAssetIds', 'catalogRevision', 'expiresAt']);
  });

  it('rejects undocumented routes and required request fields', () => {
    const schemas = contract.components.schemas;
    for (const [schemaName, approvedFields] of Object.entries(APPROVED_REQUIRED_FIELDS)) {
      const schema = schemas[schemaName];
      expect(schema.required).toEqual(approvedFields);
      expect(schema.required.every((field: string) => Object.hasOwn(schema.properties, field))).toBe(true);
    }
    expect(schemas.AgentOperationRequest.additionalProperties).toBe(false);
    expect(schemas.AgentApprovalToken.additionalProperties).toBe(false);
  });
});
