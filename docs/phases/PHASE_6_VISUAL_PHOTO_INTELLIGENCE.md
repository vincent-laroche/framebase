# Phase 6 — Visual Photo Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Help Vincent identify strong business photos, review before/after candidates, and assess hairline presentation through an explicit human-feedback loop—without face detection, identity recognition, or automatic organization.

**Architecture:** Framebase keeps labels, decisions, and evaluation records in the local catalog first. A provider-neutral assessment boundary accepts a strictly structured result. Anthropic Claude Sonnet is the selected initial remote assessment provider, but model choice is stored as versioned configuration and may be changed later. The provider sees only an approved bounded derivative; its result creates review candidates, never catalog mutations. Human decisions become the durable training signal. A later lightweight ranking model may be calibrated from that signal; Framebase will not train a foundation vision model from scratch.

**Tech Stack:** Swift 6.2, macOS 26, GRDB/SQLite, SwiftUI/AppKit, ImageIO; later-only Anthropic Claude Sonnet through Cloudflare AI Gateway, with an approved provider credential and privacy/cost controls.

## Global Constraints

- Never run a face-detection request or implement person identity, biometric templates, person naming, or sensitive-person inference.
- `hairlinePresentation` means only a visible hair-system/business-photo attribute: `clearlyVisible`, `partiallyVisible`, `notVisible`, or `unclear`. It is not a person identifier or medical assessment.
- `beforeAfter` is only a candidate relationship. A person must explicitly confirm, reject, or edit every pair before it becomes a curated relationship.
- Assessment, labels, feedback, and recommendations must never rename, move, tag, album, rate, favorite, delete, or trash an asset automatically.
- Do not transmit an image, create AI Gateway/Vectorize resources, configure credentials, set a secret, deploy, or spend money until the remaining approval checklist in `docs/PHASE_6_CLOUD_INTELLIGENCE_OPERATIONS.md` is complete.
- Use generated non-personal fixtures until Vincent separately approves a per-library consent/permission workflow for real photos.
- Store exact provider/model identifier, assessment-schema version, derivative digest and dimensions, timestamp, confidence, recorded cost, and review state for every remote result. Do not store raw image bytes, managed-original paths, EXIF/GPS, OCR/barcode text, raw prompts, or raw provider responses in diagnostics.
- Provider output is advisory. The user-defined review rubric, not the model, is the source of truth for what makes a photo good for the business.

## Product Contract

### Reviewable assessment schema

The first provider response must validate against a versioned, strictly bounded JSON schema. It contains:

| Field | Allowed values / rule |
| --- | --- |
| `businessQuality` | `strong`, `usable`, `weak`, or `needsReview`; always includes short visual evidence codes. |
| `visualEvidence` | Controlled observations such as `sharp`, `wellLit`, `hairlineClear`, `productVisible`, `beforeAfterContext`, `croppedPoorly`, or `uncertain`; no identity or demographic claims. |
| `photoRole` | `beforeCandidate`, `afterCandidate`, `comparisonCandidate`, `other`, or `unclear`. |
| `hairlinePresentation` | `clearlyVisible`, `partiallyVisible`, `notVisible`, or `unclear`; visual presentation only. |
| `confidence` | `0...1`; results below the configured review threshold stay `needsReview`. |
| `rationale` | At most 240 characters, using only the controlled visual scope. |
| `modelIdentifier` / `schemaVersion` | Required, exact values recorded with provenance. |

Before/after matching has a second local relationship record: `candidate`, `confirmed`, `rejected`, or `superseded`. The model may suggest candidates from a bounded candidate set, but never creates a confirmed pair.

### Learning loop

1. Vincent reviews each assessment, corrects the labels, and states whether its recommendation was useful.
2. Framebase records that feedback as append-only, versioned evidence against the source assessment; edits do not erase the original provider result.
3. A frozen, human-labeled holdout fixture set measures each rubric/model revision before it is promoted.
4. Once enough representative reviewed examples exist, a small ranking/calibration model can be trained locally or privately on labels—not on unmanaged originals—and may only reorder review queues. Claude Sonnet remains the high-capability visual assessor, not a continuously self-training black box.

## File Map

| Path | Responsibility |
| --- | --- |
| `Packages/FramebaseKit/Sources/FramebaseDomain/VisualLearningModels.swift` | Rubric, assessment, feedback, relationship, and model-revision value types. |
| `Packages/FramebaseKit/Sources/FramebaseDomain/VisualLearningProtocols.swift` | Provider-neutral assessment, review, and evaluation contracts. |
| `Packages/FramebaseKit/Sources/FramebaseCatalog/FramebaseCatalog.swift` | Additive v9 local review/feedback/relationship migration. |
| `Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogVisualLearningRepository.swift` | Transactional local persistence, provenance lookup, review queue, and immutable feedback history. |
| `Packages/FramebaseKit/Sources/FramebaseMedia/VisualSimilarityService.swift` | Optional local generic-image-similarity shortlist; no face request and no persisted biometric template. |
| `App/LibraryWindowModel.swift` | Explicit assessment/review commands and in-memory UI state. |
| `UI/Inspector/FoundationInspector.swift` | Assessment card, visible provenance, feedback, and before/after confirmation. |
| `UI/AppShell/LibraryWindowView.swift` | Review queue and filter affordances. |
| `Cloud/apps/api/src/routes/intelligence.ts` | Deferred, approved Claude Sonnet request boundary only. |
| `Cloud/apps/api/migrations/0007_intelligence_metadata.sql` | Deferred cloud metadata/provenance records only; never original bytes. |

---

## Task 1: Permanently remove active face detection

**Files:** `IntelligenceModels.swift`, `VisionIntelligenceService.swift`, `LibraryWindowModel.swift`, `FoundationInspector.swift`, related tests and Phase 6 documents.

- [x] Restrict active local Vision requests to OCR, barcode, and document segmentation.
- [x] Retain prior `faceRegions` values for decode-only catalog compatibility, without requesting, displaying, or creating them.
- [x] Verify Vision source contains no `VNDetectFaceRectanglesRequest` and package tests cover the inactive legacy value.
- [ ] Commit the removal with the local Vision test evidence.

## Task 2: Complete local OCR and barcode confidence evidence

**Files:** `VisionIntelligenceServiceTests.swift`, `IntelligenceModelTests.swift`, local Phase 6 plan.

- [x] Generate a non-personal QR fixture in the test target and prove returned symbology, payload, confidence, and normalized geometry.
- [x] Keep OCR, barcode, and document analysis explicit and local-only.
- [ ] Add a document-segmentation fixture where Vision support is stable, or record an explicit platform-support fallback.
- [x] Run the full FramebaseKit suite and the terminal-only native UI test proving analysis leaves organization unchanged.

## Task 3: Define private, reviewable learning contracts

**Files:** new `VisualLearningModels.swift`, `VisualLearningProtocols.swift`, and domain tests.

- [ ] Write failing tests for enum validation, bounded rationale, no-mutation authority, model/schema provenance, and legacy-safe Codable evolution.
- [ ] Implement `PhotoAssessment`, `AssessmentEvidence`, `AssessmentReview`, `BeforeAfterRelationship`, `AssessmentFeedbackEvent`, and `VisualModelRevision`.
- [ ] Make review decision states explicit: `unreviewed`, `accepted`, `corrected`, `rejected`, and `needsMoreContext`.
- [ ] Verify all types forbid identity, biometrics, person names, raw image bytes, managed paths, prompts, and mutation closures.
- [ ] Run `swift test --package-path Packages/FramebaseKit --filter VisualLearningModelTests`.

## Task 4: Add local catalog review history and a non-destructive review UI

**Files:** catalog migration/repository/tests, `LibraryWindowModel.swift`, inspector, review UI, UI tests.

- [ ] Write migration/reopen tests before implementation. Migration v9 must be additive and include assessment provenance, human reviews, append-only feedback events, and candidate/confirmed/rejected relationships.
- [ ] Enforce uniqueness/idempotency on asset, provider/model, schema, and derivative digest. Correcting a review appends an event; it does not overwrite the original assessment.
- [ ] Add an explicit inspector review card that shows model/schema/derivative provenance and lets Vincent accept, correct, or reject an assessment.
- [ ] Add manual before/after confirmation and rejection actions. A candidate may never alter a folder, tag, album, name, rating, favorite, or Trash state.
- [ ] Add terminal-only UI tests that snapshot these organization fields before and after assessment/review actions.
- [ ] Run focused catalog/domain/UI tests and `./script/build_and_run.sh --verify`.

## Task 5: Freeze an evaluation set and quality promotion rules

**Files:** synthetic fixture generator, local evaluation harness, `docs/phases/` scorecard.

- [ ] Define the rubric with Vincent using examples he labels manually; do not infer business-quality rules from unreviewed media.
- [ ] Create a versioned fixture manifest split into development, frozen holdout, and regression cases. It may use generated/sanitized images until per-library permission is approved.
- [ ] Measure at minimum: assessment-label agreement, strong-photo precision in the review queue, before/after candidate precision, hairline-presentation agreement, low-confidence rate, latency, and cost per reviewed asset.
- [ ] Require improvement on the frozen holdout and no privacy regressions before promoting a new rubric/model revision.
- [ ] Keep an explicit rollback that returns all assets to the prior review ordering while retaining evidence.

## Task 6: Implement Claude Sonnet only after the approval matrix is complete

**Files:** Cloud Worker route/tests/OpenAPI, Swift provider client/config, migration, operations package.

- [ ] Reconfirm Anthropic’s current retention terms, exact Claude Sonnet model revision, supported image limits, and current pricing immediately before enablement.
- [ ] Obtain Vincent’s explicit values for spend cap, development-only target, Cloudflare AI Gateway payload logging disablement, synthetic-first proof, namespace/migration/scopes, and personal-library permission.
- [ ] Implement a provider selector with a pinned `modelIdentifier` and `assessmentSchemaVersion`; changing providers creates a new revision rather than rewriting older results.
- [ ] Send only the approved 1,600px bounded derivative and opaque IDs through AI Gateway with payload collection disabled. Validate the strict schema and discard raw response data after extracting permitted fields.
- [ ] Enforce rate/concurrency, cost reservation before request, one transient retry, namespace isolation, and a hard stop at the approved ceiling.
- [ ] Prove against generated fixtures that logs have no image payload, filenames, paths, OCR/barcode text, prompts, or raw provider response; prove failure and cost-cap paths cannot organize an asset.
- [ ] Do not deploy, set secrets, create a Vectorize namespace, or transmit a personal image without a new explicit approval.

## Task 7: Calibrate a learning model only after representative human feedback exists

**Files:** future local evaluation/training package and model card.

- [ ] Establish a minimum evidence threshold with Vincent after reviewing label balance and real-world variety; do not choose a numeric threshold blindly.
- [ ] Train a small, interpretable ranking/calibration model on reviewed labels only. It may prioritize an unreviewed queue but cannot auto-accept or auto-organize assets.
- [ ] Version the dataset manifest, feature definition, model, rubric, and evaluation scorecard. Keep a model card describing intended use, exclusions, known failure modes, and rollback.
- [ ] Promote only after holdout performance meets the agreed threshold and blind human review confirms the queue is useful.

## Exit Checklist

- [ ] No executable face detection or identity recognition exists in Phase 6 sources.
- [ ] OCR, barcode, and document results are local, provenance-rich, bounded, and non-destructive.
- [ ] Every visual assessment is clearly labeled as provider advice or a human decision.
- [ ] Before/after and hairline presentation are reviewable attributes, not automated organization or biometric recognition.
- [ ] Claude Sonnet integration has a pinned revision, approved privacy/cost controls, synthetic proof, and redacted logs before any real-photo use.
- [ ] A versioned feedback dataset and frozen evaluation set govern future calibration instead of opaque self-training.
