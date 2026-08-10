# Phase 2 — Cloud Contract and Safety Spine

**Status:** Complete (2026-08-09)
**Authority:** `docs/MASTER_ROADMAP.md` governs product scope. This plan governs Phase 2 implementation and exit evidence.

## 1. Outcome and hard boundary

Phase 2 proves a private, fixture-only cloud contract. A registered development
client can authenticate, upload a fixture original to private R2, verify its
bytes, create and replay a catalog mutation, consume a monotonic change feed,
and retrieve the fixture through a bounded authenticated capability.

Phase 2 does **not** connect the shipping macOS app to cloud services. The
Swift `FramebaseAPIClient`, `FramebaseSync`, local outbox, cloud-backed library
migration, conflict UI, and personal-library transfer are Phase 3 work. This
keeps the local library as the only authority for real assets throughout this
phase.

### Non-negotiable constraints

- Development fixtures only; never upload personal or Cloudinary-library media.
- No production deployment, DNS route, public bucket, public delivery URL, or browser administration UI.
- No Cloudflare, R2, or enrollment secret in the app bundle, Git history, logs, test fixture, or generated contract.
- Logical catalog mutations remain idempotent, revisioned, audited, and conflict-aware. A logical move never changes immutable blob bytes.
- Cloud resource, secret, and deploy changes remain separately approval-gated.

## 2. Verified starting point

The following development-only resources already exist. Their existence does not satisfy the Phase 2 exit gate; the final fixture proof and operational evidence still do.

| Surface | Current state | Phase 2 rule |
| --- | --- | --- |
| Worker | `framebase-api-dev` deployed on its Cloudflare `workers.dev` hostname | No custom domain or browser CORS requirement. |
| Catalog | `framebase-catalog-dev` D1 database, initial schema applied | All further changes are replayable numbered migrations. |
| Blob storage | `framebase-blobs-dev` R2 bucket | Private; no custom domain or public-access configuration. |
| API | Hono TypeScript service with health, enrollment, blobs, changes, and mutations routes | Must conform to the contract and negative-test gates below. |
| Authentication | Enrollment-secret gate plus one-hour HS256 JWTs; device revocation and scopes are checked by middleware | Adequate only for fixture development; public-key challenge is a Phase 3 decision. |

Existing automated API tests are useful scaffolding, not complete exit evidence.
The current upload route is an authenticated Worker proxy with an informational
expiry field, rather than the short-lived direct R2 capability promised by the
roadmap. It must not be represented as a presigned upload until it is one.

## 3. Threat model and decisions

### Assets to protect

- Private original bytes and metadata, even when the test content is harmless.
- Catalog organization, revision history, audit history, and device scope.
- R2 signing credentials, enrollment secret, JWT signing secret, and any short-lived bearer capability.

### Threats and required controls

| Threat | Control required in Phase 2 |
| --- | --- |
| Stolen JWT or upload/download URL | One-hour JWT maximum; 15-minute, single-object, single-operation signed R2 capability; never log token-bearing URLs. |
| Unauthorized enrollment | Require `X-Enrollment-Secret`; rate-limit and redact enrollment failures; write no secret to the app or repository. |
| Revoked device retains access | Verify the signed JWT **and** the active device record on every protected request. |
| Scope escalation | Server-owned grantable-scope allow-list; `purge.approve` is never grantable; validate scope per mutation operation. |
| Blob substitution or truncation | Validate SHA-256 format, declared length, signed content type, R2 object length, and server-calculated SHA-256 before marking `verified`. |
| Replayed or duplicate mutation | Require `Idempotency-Key`, bind a receipt to actor plus canonical request fingerprint, and return the original response only for an identical replay. |
| Lost or reordered catalog change | Assign change revision in the same D1 transaction as mutation/audit receipt; cursor is exclusive and ordered ascending. |
| Sensitive telemetry | Structured redaction allow-list only; no filenames, image bytes, tokens, URLs with query strings, raw request bodies, or R2 keys in logs. |

### Enrollment decision for this phase

The deployed enrollment-secret plus JWT mechanism is accepted only as a single-user **development** protocol. The submitted `publicKey` is recorded as device provenance, not proof of possession. A Secure-Enclave/keypair challenge is deliberately deferred to Phase 3, before a real Mac library can enroll. The Phase 2 evidence must label that limitation plainly.

## 4. Canonical Phase 2 contract

Create a versioned, language-neutral contract under `Cloud/contracts/` before adding more routes. It is the source for Worker validation and future Swift generation/hand-written client types; it is not an app client implementation.

### Required entities

`Device`, `Blob`, `Folder`, `Asset`, `Album`, `ChangeEvent`, `MutationReceipt`, and `AuditEvent` use stable UUID/string IDs and ISO-8601 UTC timestamps. Blob identity is a lowercase SHA-256 hex digest. `Asset` and `Blob` remain separate, even if the Phase 2 fixture creates one asset per blob.

### Routes

| Route | Required behavior |
| --- | --- |
| `GET /v1/health` | Public liveness only: API version, deployment environment, and non-sensitive dependency status. |
| `GET /v1/capabilities` | Authenticated feature/version document; no credentials or infrastructure identifiers. |
| `POST /v1/auth/enroll` | Enrollment-secret-gated development enrollment; returns a one-hour token and explicit scopes. |
| `GET /v1/catalog/bootstrap` | Authenticated paginated fixture snapshot with a watermark revision. |
| `GET /v1/changes?after=&limit=` | Authenticated exclusive, monotonically ordered changes; bounded limit and `nextCursor`. |
| `POST /v1/blobs/upload-initiate` | Validates immutable blob intent and returns a 15-minute direct `PUT` capability for exactly one content-addressed key. |
| `POST /v1/blobs/upload-complete` | Reads R2 object metadata/bytes, verifies size and SHA-256, and atomically marks the blob verified or returns a structured mismatch. |
| `GET /v1/blobs/{id}/download` | Returns a 15-minute direct `GET` capability only for a verified blob and a device with `originals.download`. |
| `POST /v1/mutations` | Applies the supported fixture mutation set atomically with validation, revision, audit record, receipt, and change events. |

All protected responses use the same error shape:

```json
{
  "error": {
    "code": "UPPER_SNAKE_CASE",
    "message": "safe user-facing summary",
    "requestId": "opaque correlation id"
  }
}
```

Use `401` for missing, invalid, expired, or revoked identities; `403` for valid but under-scoped identities; `409` for stale base revision or idempotency-key fingerprint mismatch; `422` for checksum/size/media validation failure; and `429` for bounded enrollment or capability issuance.

### Upload/download capability decision

Use direct R2 S3 presigned `PUT`/`GET` URLs, not a Worker-proxy URL described as presigned. The Worker signs one content-addressed key with `aws4fetch` using a dedicated R2 access-key pair stored only as Worker secrets. The signed request must bind method, target key, expiry, and content type. The API stores only safe intent/verification metadata; the URL is returned once and never persisted or logged. This follows Cloudflare's documented R2 presigned-URL pattern.

Before adding the R2 signing credentials, obtain explicit approval for that new secret material. If approval is not granted, retain the current Worker proxy only as a development aid and mark the direct-capability exit gate open.

## 5. Data and mutation rules

### Migrations

Move the checked-in schema into numbered SQL migrations at `Cloud/apps/api/migrations/`, configure `migrations_dir` in `wrangler.json`, and retain the baseline as `0001_initial_schema.sql`. New schema work receives a new migration; never edit an applied migration. CI replays migrations from an empty local D1 state, and the deployment runbook checks the remote migration list before applying.

Add or validate the following constraints during the migration review:

- immutable `blobs.sha256`, `blobs.r2_key`, and verified byte size;
- unique `change_events.revision` and actor-scoped idempotency receipts;
- base revision on every mutable entity and mutation operation;
- foreign keys enabled for every D1 connection;
- a seeded system Inbox with an explicit library/catalog identity; and
- tombstone/retention fields where a fixture delete is supported.

### Fixture mutation subset

The initial supported operations are create/rename folder, move fixture asset, and update rating/favorite. Each operation carries `targetId`, `baseRevision`, and a typed payload. The server, not `actorId` supplied in JSON, derives actor identity from the JWT. Unsupported operations fail closed.

The mutation transaction must:

1. authenticate and authorize;
2. load and verify the base revisions;
3. reject stale non-commutative state with `409` and current entity state;
4. apply the domain mutation;
5. write mutation receipt, audit event, and ordered change event(s);
6. store the canonical idempotency response; and
7. return the updated entity and its new revision.

## 6. Work packages and sequence

| Order | Package | Deliverable and proof |
| --- | --- | --- |
| 0 | Safety baseline | Document resource inventory, reset procedure, spending ceiling, no-public-access assertion, and a redacted deploy checklist. No cloud mutation without approval. |
| 1 | Contract and migrations | `Cloud/contracts/` contract, request validators, error catalog, migration directory/config, and local empty-state replay test. |
| 2 | Auth hardening | Strict enrollment input validation, request IDs, rate limits, device revocation test, scope matrix, and CORS removed or locked to no browser origin. |
| 3 | Private blob plane | Real direct signed upload/download capabilities; checksum and byte-size verification; rejected-object cleanup rule; tests for wrong hash/type/size/expiry. |
| 4 | Catalog and sync proof | Bootstrap watermark, change-feed pagination, base-revision conflicts, actor-derived mutations, idempotency fingerprinting, audit receipts, and deterministic rebuild test. |
| 5 | Live fixture acceptance | One harmless image fixture through enroll → signed upload → verify → catalog → download → fresh rebuild; compare bytes, catalog relationships, and every revision. |
| 6 | Operations closeout | Remote migration/deployment evidence, redacted log review, cost snapshot, rollback/reset rehearsal, and an explicit Phase 2 exit report in `PROJECT.md`. |

## 7. Verification matrix

| Gate | Required assertion |
| --- | --- |
| Contract | Every documented route has request/response and error tests; Worker route validation uses the same contract. |
| Migration | Empty local D1 replay succeeds; a second replay is clean; remote migration list is recorded before/after approved apply. |
| Authentication | Missing, malformed, expired, revoked, and wrong-secret enrollment identities return `401`; every required scope returns `403` when absent. |
| Capability | A signed capability is single-object/method/content-type, expires within 15 minutes, and never appears in logs. |
| Blob integrity | Wrong hash, wrong byte size, wrong media type, missing R2 object, and duplicate upload all fail safely; valid bytes become `verified`. |
| Idempotency/conflict | Identical replay returns the exact receipt; same key with a different request returns `409`; stale folder/asset mutation returns structured `409`. |
| Change feed | Sequential revisions have no gaps or duplicates; a fresh fixture catalog rebuilt from bootstrap plus feed exactly matches server state. |
| Privacy | Structured log capture contains no secret, JWT, presigned query, filename, R2 key, image byte, or raw metadata value. |
| Regression | `npm test`, TypeScript check, existing Swift package tests, native UI tests, and `./script/build_and_run.sh --verify` pass. |
| Live acceptance | The fixture-only end-to-end run is repeated against the deployed development Worker; all temporary device access is revoked afterward. |

## 8. Deployment, rollback, and cost controls

### Approval gates

- **Required before cloud changes:** create/delete resources, set/rotate Worker secrets, create an R2 signing credential, apply remote migrations, deploy a Worker, alter bucket access/CORS, or reset remote fixture data.
- **Never implied by this plan:** production resources, DNS/custom domains, Cloudflare Access, personal asset migration, or modification of `/Users/vMac/.env`.

### Safe deployment procedure

1. Run contract, migration, API, and local app verification.
2. Inspect the diff and remote migration status; confirm the named `-dev` resources and fixture-only scope.
3. Obtain the specific approval needed for secrets, migrations, reset, or deploy.
4. Apply one numbered migration, deploy the Worker with the narrowest capable token, then run live fixture acceptance.
5. Record deployment version, migration state, tests, resource privacy checks, and cost snapshot in `PROJECT.md` without secrets or URLs carrying tokens.

### Rollback and reset

- Worker: redeploy the previous known-good version; do not delete the service.
- D1: forward-only corrective migration or a fixture-only reset after explicit approval; never edit an applied migration.
- R2: delete only the exact test prefix/object after explicit approval and only after its catalog receipt is removed in the same approved reset procedure.
- Device: revoke the device row first; rotate an enrollment/JWT/R2 signing secret only with explicit approval and redeploy the Worker.

Keep a development spending ceiling of **US$5/month** for Phase 2 fixture use. Before every approved deploy/reset, inspect the current Worker/D1/R2 usage and stop if the next change could exceed that ceiling.

## 9. Planned file ownership

```text
Cloud/contracts/                         # New versioned HTTP/domain contract
Cloud/apps/api/migrations/               # Numbered D1 migrations
Cloud/apps/api/src/middleware/           # Auth, validation, request context/redaction
Cloud/apps/api/src/routes/               # Contract-conforming API routes
Cloud/apps/api/src/services/             # Blob capability, checksum, mutation use cases
Cloud/apps/api/test/                     # Local contract, migration, negative, fixture tests
Cloud/apps/api/wrangler.json             # Bindings/migration config only; never secrets
docs/phases/PHASE_2_CLOUD_FOUNDATION.md  # This active plan
PROJECT.md                               # Session evidence and handoff only
```

`Packages/FramebaseKit/Sources/FramebaseAPIClient/` and `Packages/FramebaseKit/Sources/FramebaseSync/` are intentionally excluded until the Phase 3 entry gate. The Phase 2 contract must make their later work straightforward without creating speculative Swift modules now.

## 10. Exit gate and handoff

Phase 2 is complete only when all of the following are recorded in `PROJECT.md`:

1. The exact development Worker deployment and private R2 assertion are verified after an explicitly approved deployment.
2. Numbered D1 migrations replay from empty state and are applied remotely with recorded status.
3. A registered development client completes the fixture upload, checksum verification, authenticated download, mutation, and ordered change-feed rebuild flow.
4. Idempotency, stale revision, invalid/expired/revoked/under-scoped identity, and sensitive-log negative cases all pass.
5. The direct R2 capability uses no long-lived infrastructure credential in the client and leaves no public access path.
6. The current local Framebase library remains untouched and all native regression gates pass.

The Phase 3 entry handoff includes the frozen HTTP contract/version, migration state, fixture acceptance transcript with secrets redacted, open enrollment limitations, usage/cost snapshot, and proof that no personal media was used.

### Recorded exit evidence (2026-08-09)

- Approved development release deployed Worker version `25ab4e1f-463b-4c4e-8311-e1d76d5e178f`; `/v1/health` subsequently returned `0.2.0` with D1 status `ok`.
- `0001_initial_schema.sql` and `0002_idempotency_and_mutation_guards.sql` were applied remotely; Wrangler then reported no pending migrations. Both also replayed locally from empty state.
- The fixture-only live acceptance completed one registered temporary device through signed 1×1 PNG upload, strict verification, catalog mutation, bootstrap/change replay, signed byte-identical download, and device revocation.
- The Worker has only the dedicated R2 account/access/secret signing values required for direct capabilities. The signer token is restricted to object read/write on `framebase-blobs-dev`; no client receives that credential.
- Post-release checks found no Worker or R2 custom domains, no browser CORS header, `401` for an unauthenticated protected route, and no current-period billed cost in the reported R2/Workers usage rows.
- Local Phase 2 contract tests, native regression gates, and the source audit establish the negative identity/logging cases and preserve the untouched local library. Enrollment remains a development-only shared-secret protocol until Phase 3 replaces it with keypair proof of possession.

## References

- [Framebase master roadmap](../MASTER_ROADMAP.md)
- [Cloudflare R2 presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
- [Cloudflare D1 migrations](https://developers.cloudflare.com/d1/reference/migrations/)
