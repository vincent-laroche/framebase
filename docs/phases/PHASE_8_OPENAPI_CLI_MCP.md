# Phase 8 — OpenAPI, CLI, and MCP Agent Platform Implementation Plan

**Goal:** Expose Framebase’s safe, reviewable capabilities to trusted scripts and agents through one canonical contract, without UI automation, raw storage access, or scope escalation.

**Architecture:** OpenAPI describes the stable capability boundary. The local `framebase` CLI and future MCP server adapt the same typed use cases, proposal system, audit attribution, and operation-status model. The Mac app/catalog remains authoritative; agents never receive Cloudflare, database, R2, or managed-original credentials.

**Tech Stack:** OpenAPI 3.1, TypeScript/Hono for the later Worker adapter, Swift/SwiftPM for local CLI use cases, MCP TypeScript SDK only after a focused server plan and separate identity/deployment approval.

## Constraints

- Search and inspection are read-first and scope-filtered.
- Bulk mutations default to a proposal and cannot apply without an explicit approval token bound to exact targets and snapshot revision.
- No initial agent tool offers permanent purge, raw bucket access, unbounded download, credential readout, or arbitrary SQL.
- Every mutation stores agent identity, delegated scope, originating tool, approval token, and audit event.
- Local CLI fixtures may use generated media/catalogs only until the relevant personal-library authorization is explicit.
- Creating remote agent identities, API credentials, an MCP endpoint, a Worker route, or deployment requires separate approval.

## File Map

| Path | Responsibility |
| --- | --- |
| `Cloud/contracts/framebase-api-v1.openapi.json` | Canonical OpenAPI capability contract and schemas. |
| `Packages/FramebaseKit/Sources/FramebaseDomain/AgentOperationModels.swift` | Typed operation/proposal/status contracts. |
| `Packages/FramebaseKit/Sources/FramebaseCLI/` | Local CLI commands over domain use cases. |
| `Cloud/apps/api/src/routes/` | Deferred authenticated HTTP adapters. |
| `Cloud/apps/mcp/` | Deferred scoped MCP server using the same contract. |
| `Cloud/apps/api/test/` | Contract, scope, revocation, proposal, and parity tests. |

## Task 1: Define canonical agent-operation contracts

- [x] Write tests for scopes, proposal-only bulk mutations, exact approval-token binding, and redaction.
- [x] Implement typed operation contracts for search, inspection, folders, metadata edits, tags, albums, OCR, analysis, workflows, export, and bounded download.
- [x] Exclude permanent purge and arbitrary storage/database operations at the type level.

## Task 2: Generate and validate OpenAPI 3.1

- [x] Add preview-only scope, identity, operation, request, and approval-token schemas to the versioned OpenAPI contract without claiming a new deployed route.
- [x] Typecheck and contract-test the new preview schemas locally.
- [x] Add a compatibility test that rejects undocumented API routes, methods, and required fields; proposal/approval request schemas remain closed to undeclared fields.

## Task 3: Build the local `framebase` CLI

- [x] Add read-only `diagnostics`, `list-folders`, and `search` commands with deterministic JSON output and no managed-original path/storage-key output.
- [x] Start with `search`, `inspect`, `list-folders`, `proposal`, `apply`, `get-operation`, and `diagnostics`.
- [x] Use machine-readable JSON by default where appropriate; redact protected metadata in errors.
- [x] Make the implemented bulk tag command dry-run by default and require an exact short-lived opaque approval token to apply.
- [x] Test CLI output against generated catalogs and compare resulting domain state with the Mac-app workflow use case, including identity-bound proposal/apply, cross-identity token denial, revocation denial, and queryable audit attribution.

## Task 4: Add remote HTTP/MCP adapters after identity approval

**Current source-only implementation (2026-08-10):** migration `0007_agent_operations.sql` and the `agents` Worker route implement the first narrow remote adapter without deploying it. A trusted device can mint a one-time returned, SHA-256-hashed delegated credential whose scopes are a subset of its own; only that device can revoke it. An active agent with `assets.metadata.write` can propose adding an existing tag to up to 500 active assets at an exact catalog revision. The owner device issues a 15-minute opaque approval only if the full target/tag/membership snapshot is unchanged. The same shared idempotent mutation executor used by `/v1/mutations` then adds only previously missing memberships and preserves any pre-existing membership. Every identity/proposal/approval/apply/expiry/stale event is attributed. No migration has been applied, identity created, endpoint deployed, MCP server hosted, cloud credential emitted, or personal media touched.

- [ ] Map the remaining approved OpenAPI operations to scope-enforced Worker handlers and operation records. The initial `addTags` proposal/apply route is source-complete and terminal-tested; it is not deployed.
- [x] Create a separate scoped, local-catalog agent identity/revocation model without exposing infrastructure credentials. The source-only remote adapter mirrors this with one-way credential hashes and owner-device revocation; no remote identity has been created or deployed.
- [x] Implement source-only local stdio MCP tools as thin wrappers in `Cloud/apps/mcp/`; they proxy only `framebase_propose_tag`, `framebase_get_operation`, and `framebase_apply_tag_proposal` to the scoped HTTP adapter. They have no database/R2/UI-automation/credential-creation/purge/model surface and remain unhosted.
- [ ] Prove scope denial, revocation, proposal expiry, audit attribution, and CLI/MCP parity.
- [ ] Obtain explicit approval before remote identities, credentials, endpoint deployment, or MCP hosting.

## Exit Checklist

- [ ] CLI and MCP fixtures produce the same domain outcomes as the Mac use cases. The MCP proxy's HTTP mapping is tested, but full app/CLI/MCP parity still awaits deployment-independent shared fixtures.
- [ ] Bulk mutation remains proposal-first and approval-bound.
- [x] Scope/revocation tests deny out-of-policy local CLI access.
- [x] Every local CLI mutation is attributed and queryable in audit history.
- [ ] No initial tool can purge permanently or expose cloud credentials/raw buckets.
