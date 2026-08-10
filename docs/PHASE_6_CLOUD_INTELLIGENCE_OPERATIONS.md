# Phase 6 Cloud Intelligence — Approval Package

**Status:** Draft only. No cloud-intelligence resource, secret, migration, route, binding, deployment, or image transmission is authorized by this document.

## Decision requested

Approve or decline a development-only cloud-intelligence experiment after the local Phase 6 verification gate passes. The recommendation is to begin with explicit single-asset analysis and semantic search only; do not add queues, workflows, automatic analysis, or automatic organization in this approval.

The existing development Worker is `framebase-api-dev`. This package does not assume a production target, public route, or a change to the master environment file.

## Proposed development contract

| Area | Recommended starting value | Approval required |
| --- | --- | --- |
| Environment | Existing development Worker and development data only | Yes |
| Provider | Cloudflare AI Gateway in front of Anthropic Claude Sonnet; pin the exact dated model revision immediately before enablement so it remains replaceable | Partly — provider chosen; exact revision and current terms still required |
| Input | A newly generated JPEG or PNG derivative no larger than 1,600 pixels on its longest edge; never the managed original | Yes |
| Tasks | Manual caption, categories, detected objects, business-quality assessment, before/after candidates, hairline presentation assessment, and embedding generation; OCR remains local-first | Yes |
| Payload retention | Provider retention disabled where offered; no prompt/response or image payload logging | Yes — confirm provider setting |
| AI Gateway | Payload logging disabled; diagnostic events contain only opaque IDs, timing, status, model revision, and metered cost | Yes |
| Rate/concurrency | At most 2 concurrent requests and 10 assets per minute per enrolled device | Yes |
| Retry | One automatic retry only for a transient, retryable failure; all other failures remain visible for manual retry | Yes |
| Spend limit | **Recommended development ceiling: USD 20/month**; hard stop before any provider request once the recorded ceiling is reached | Yes — amount and currency |
| Vectorize | One development namespace per catalog and embedding revision: `framebase-dev/<catalog-id>/embedding-v1` | Yes |
| D1 | Additive metadata-only migration, proposed as `0007_intelligence_metadata.sql`; no original bytes, image paths, OCR text, or credentials | Yes |
| API scopes | New `intelligence.run` plus existing `library.read`; no organization or delete scope grants | Yes |
| Result behavior | Return candidates, confidence, provider/model revision, source-derivative digest, and cost/provenance; never mutate folders, tags, albums, names, or Trash | Yes |

## Data boundary

Allowed to leave the Mac after approval:

- a bounded analysis derivative;
- an opaque catalog/asset identifier;
- an explicit task, schema revision, and model-selection identifier.

Never sent, stored in AI logs, or included in API error text:

- managed originals, storage paths, filenames, EXIF/GPS, OCR/barcode text, person identity, credentials, bearer URLs, or raw prompts/responses;
- unbounded image data;
- any data from a personal library until a separate per-library authorization is given.

The assessment schema must not request face detection, person identity, biometric templates, age, gender, ethnicity, medical inferences, or any other sensitive-person inference. Hairline is a visual business/composition attribute only, never a biometric identifier. Before/after output is a candidate relationship that requires a human confirmation.

## Required implementation controls

1. Route all model calls through the approved AI Gateway configuration with payload collection disabled before the first request.
2. Enforce the device's authenticated catalog namespace in every D1 and Vectorize operation; cross-namespace candidates must be rejected.
3. Store only structured result metadata, stale state, source derivative digest/dimensions, model/schema revision, and recorded cost. Embeddings stay in the catalog namespace and are not catalog truth.
4. Use parameterized D1 queries and structured catalog filters before vector similarity.
5. Add a durable local/cloud audit event for request, completion, rejection, retry, and cost-cap stop without sensitive content.
6. Make analysis user-initiated and reviewable. A result may suggest an action but cannot apply one.
7. Fail closed when authentication, cost accounting, provider privacy settings, or the namespace check is unavailable.

## Synthetic-fixture proof before any real library

The first development proof must use generated fixtures only and demonstrate:

- a provider receives only the bounded derivative;
- payload logging is disabled and application logs contain no private media metadata;
- rate/concurrency and the monthly cap stop new work predictably;
- retry produces no duplicate result or double charge record;
- a different catalog namespace receives `403`/no candidates;
- structured filters constrain similarity candidates;
- old model/derivative results become stale rather than being overwritten;
- no result changes any folder, album, tag, name, favorite, rating, or Trash state.

## Rollback

Before enabling the first cloud request, the implementation must have these reversible controls:

1. Disable the `intelligence.run` route/capability without deleting local or cloud provenance.
2. Stop new requests immediately on a privacy, cost, or provider failure.
3. Mark the affected model revision unavailable/stale; retain existing records for review.
4. Revoke the purpose-specific provider credential and remove the development binding only with separate approval.
5. Do not delete Vectorize or D1 records as rollback; preserve an audit trail and provide a separately approved retention/delete action if needed.

## Vincent approval checklist

Reply with the approved values for each item, or explicitly decline/defer cloud intelligence:

- Development-only target: approve / decline
- Provider and exact model/revision: Anthropic Claude Sonnet selected; exact dated revision to pin before enablement:
- Provider data-retention terms reviewed: yes / no
- AI Gateway payload logging disabled: yes / no
- Derivative format and 1,600px maximum: approve / change
- Monthly spend ceiling and currency:
- Vectorize namespace/version: approve / change
- API scopes (`library.read`, `intelligence.run`): approve / change
- D1 migration and synthetic-fixture proof: approve / decline
- Personal-library analysis after synthetic proof: approve / decline
- Deployment after passing tests: approve / decline

Until every required value is explicitly approved, Phase 6 cloud code and infrastructure remain out of scope.
