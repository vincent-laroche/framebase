# Phase 7 — Durable Visual Workflows Implementation Plan

**Goal:** Let Framebase create, preview, approve, execute, observe, and undo safe visual-asset workflows without allowing a rule or model to silently alter the library.

**Architecture:** A pure, versioned workflow domain package parses definitions and produces deterministic execution plans from catalog snapshots. The Mac app remains the authority for applying any catalog mutation. Future Cloudflare Queues and Workflows are delivery/execution adapters around the same idempotent operation records, never a second source of domain logic.

**Tech Stack:** Swift 6.2, GRDB/SQLite, SwiftUI/AppKit; later-only Cloudflare Queues, Workflows, D1 migrations, and Worker routes.

## Constraints

- Permanent purge is excluded.
- A workflow may create only proposals for rename, move, delete-to-Trash, or any broad mutation until a human applies an exact reviewed plan.
- Every operation has an idempotency key, source snapshot/revision, audit actor, and result state.
- Replaying or retrying a run cannot duplicate a mutation.
- No queue, workflow, Worker binding, secret, route, deployment, or cloud resource is created without a separate approval.
- Model results remain evidence only and can never bypass the existing Phase 6 review rules.

## File Map

| Path | Responsibility |
| --- | --- |
| `Packages/FramebaseKit/Sources/FramebaseDomain/WorkflowModels.swift` | Versioned definition, trigger, condition, action, proposal, run, and state contracts. |
| `Packages/FramebaseKit/Sources/FramebaseDomain/WorkflowPlanner.swift` | Pure deterministic validation and dry-run planning. |
| `Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogWorkflowRepository.swift` | Additive local run, step, proposal, and audit persistence. |
| `App/LibraryWindowModel.swift` | Explicit preview, approval, apply, and recovery commands. |
| `UI/` | Readable workflow list, plan preview, approval state, and activity history. |
| `Cloud/apps/api/` | Deferred queue/Workflow adapter and contract tests. |

## Task 1: Define pure workflow and proposal contracts

- [x] Write validation tests for destructive-action rejection, deterministic idempotency, and snapshot drift.
- [x] Implement triggers for manual selection, import completion, metadata change, folder entry, and schedule; implement safe actions for local analysis, proposal creation, tags, albums, and in-app notification.
- [x] Model `WorkflowPlan`, `WorkflowProposal`, `WorkflowRun`, `WorkflowStepRun`, and explicit approval states.
- [x] Ensure every definition and plan is Codable and carries no SQL closure, raw path, original bytes, token, or mutation authority.
- [x] Run focused domain tests.

## Task 2: Build a deterministic local dry-run planner

- [x] Write fixtures where the same definition/snapshot yields byte-for-byte equal plans.
- [x] Detect snapshot drift between preview and apply, and require a new preview rather than applying stale targets.
- [x] Generate proposed mutations only; do not apply catalog writes from the planner.
- [x] Verify duplicate delivery produces one effective local run and one proposal.

## Task 3: Persist runs, steps, proposals, and audit history locally

- [x] Add an additive migration with restart/reopen tests.
- [x] Store typed workflow/proposal/run state and retain the reviewed plan as evidence.
- [x] Enforce append-only audit events and one effective operation per idempotency key.
- [x] Prove a failed/retried run cannot duplicate an accepted local mutation and a later failed step rolls the whole catalog group back.

## Task 4: Add a Mac-first preview and approval UI

- [x] Provide a terminal-tested local tag workflow: its preview states the exact action, selected-asset count, catalog revision, drift stop, and required approval; it makes no organizational change until approved, then writes one append-only audit group.
- [x] Add explicit workflow preview and apply controls, showing exact target assets, operation count, drift warning, and non-destructive/no-automatic-undo classification. A failed tag attempt stays visible and can only retry by creating a new exact preview; it may never resume a failed plan against changed catalog state.
- [x] Add terminal-only UI tests proving a dry run changes no organization and an approved safe action produces one auditable group.
- [x] Add an undo path for the reversible tag action. Execution stores only the tag memberships it created, keyed to the run and original membership timestamp; undo removes only those rows, preserves pre-existing/re-added membership, removes an empty workflow-created tag only, and appends an idempotent undo audit group.

## Task 5: Add cloud durability only after a separate resource approval

- [ ] Map the same run/step state to Queue messages and a Workflow orchestration adapter.
- [ ] Configure dead-letter handling, retry/backoff, scoped auth, and no-sensitive-payload logging.
- [ ] Run synthetic interruption, duplicate-delivery, approval-pause/resume, and dead-letter recovery proofs.
- [ ] Obtain explicit approval before creating resources, setting bindings/secrets, applying migrations, or deploying.

## Exit Checklist

- [ ] Dry-run output equals later applied mutations or reports snapshot drift.
- [ ] Duplicate delivery cannot duplicate a mutation.
- [ ] Approval pause/resume is deterministic and observable.
- [ ] Runs, costs, evidence, retries, and actor attribution are queryable locally.
- [ ] No workflow can permanently purge or bypass a review/proposal gate.
