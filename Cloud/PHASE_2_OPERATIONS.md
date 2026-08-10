# Framebase Phase 2 Development Operations

This runbook covers only the isolated fixture environment. It does not authorize a deployment, a secret change, a resource reset, a production action, or use of any personal media.

## Development inventory

| Resource | Name | Required property |
| --- | --- | --- |
| Worker | `framebase-api-dev` | No custom domain; no permissive CORS. |
| D1 | `framebase-catalog-dev` | Numbered migrations only. |
| R2 | `framebase-blobs-dev` | Private, no public bucket or custom domain. |

## Approval-required live validation

Before a live deploy, obtain approval to do all of the following:

1. create/store the narrowly scoped R2 S3 credentials as Worker secrets (`R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`);
2. apply the two D1 migrations to `framebase-catalog-dev`;
3. deploy `framebase-api-dev`; and
4. run the fixture-only acceptance command below.

The dev deploy must use a purpose-specific token if one exists with only Workers Scripts Write, D1 Write, and R2 Write. Do not edit `/Users/vMac/.env` without separate approval.

## Local checks

Run from `Cloud/apps/api`:

```bash
npm run typecheck
npm test
npm audit --omit=dev --audit-level=high
./node_modules/.bin/wrangler deploy --dry-run --config wrangler.json
```

Validate migration replay with an isolated temporary local D1 state:

```bash
state_dir=$(mktemp -d /tmp/framebase-phase2-d1.XXXXXX)
./node_modules/.bin/wrangler d1 migrations apply framebase-catalog-dev --local --persist-to="$state_dir" --config wrangler.json
./node_modules/.bin/wrangler d1 migrations list framebase-catalog-dev --local --persist-to="$state_dir" --config wrangler.json
```

## Approved live procedure

1. Record the remote migration list before applying changes.
2. Set Worker secrets without printing their values.
3. Apply `wrangler d1 migrations apply framebase-catalog-dev --remote --config wrangler.json`.
4. Deploy the Worker with `--keep-vars` so no dashboard-managed variable is removed.
5. Supply `FRAMEBASE_API_URL` and `FRAMEBASE_API_DEV_ENROLLMENT_SECRET` in the shell, then run `npm run acceptance:live`.
6. Inspect the live Worker response headers and logs. The fixture device is revoked by the acceptance script even when the test fails.
7. Record only deployment version, migration names, test status, resource privacy evidence, and cost snapshot in `PROJECT.md`.

## Rollback and reset

- Redeploy the previous known-good Worker version; do not delete the Worker.
- Fix schema only with a forward migration. A fixture data reset or R2 object deletion needs fresh explicit approval.
- Revoke the test device before any credential rotation. Secret rotation needs fresh explicit approval and a redeploy.
- Stop if development usage could exceed the Phase 2 US$5/month ceiling.
