# Phase 6 — Intelligence and Semantic Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add opt-in, provenance-rich local OCR and visual analysis first, then searchable intelligence without allowing a model result to silently organize a library. The detailed human-reviewed business-photo learning track is in `PHASE_6_VISUAL_PHOTO_INTELLIGENCE.md`.

**Architecture:** A provider-neutral IntelligenceService owns typed requests/results and stores additive provenance records through IntelligenceRepository. The first provider is local Apple Vision operating on a bounded derivative off the main actor. Cloud vision, captions, embeddings, Vectorize, AI Gateway, and semantic search are later opt-in work packages with their own resource, privacy, and cost approval.

**Tech Stack:** Swift 6.2, macOS 26, Vision, ImageIO, GRDB/SQLite, SwiftUI/AppKit; later-only Cloudflare AI Gateway and Vectorize.

## Global Constraints

- Do not start Phase 6 product code until Phase 5 signed File Provider exit evidence is complete, except for the explicitly approved 2026-08-10 local-only Tasks 1–4. That exception does not authorize a File Provider extension, cloud intelligence, personal-library analysis, or infrastructure changes.
- Analysis is opt-in and non-destructive. It must never rename, move, tag, merge, delete, or otherwise mutate organization automatically.
- Process a bounded derivative, not an unrestricted original. Analysis records never retain derivative bytes.
- Every result persists asset ID, kind, engine/provider, model or request revision, schema version, source derivative digest/size, timestamp, confidence, and stale state.
- OCR and barcode content are private metadata. They may not appear in logs, analytics samples, public APIs, browser CORS, or error descriptions.
- Face detection, person naming, and identity recognition are excluded from Phase 6. Existing legacy face-region records remain decode-only so older catalogs can open safely.
- Do not create AI Gateway, Vectorize, Queues, Workflows, Cloudflare bindings, Worker secrets, paid model accounts, or deployments without a separately approved resource/cost plan.
- Use only synthetic fixtures until a distinct approval permits analysis of a real library.

## Entry Gate

1. Phase 5 has signed Finder lifecycle, enumeration, materialization, offline, and relaunch evidence.
2. A local Vision capability probe records supported request revisions and languages against synthetic images.
3. Local OCR/barcode/document result capture and structured OCR search pass before any cloud provider work.
4. Before cloud intelligence, Vincent must approve the provider, derivative specification, retention, AI Gateway logging disablement, retry/rate policy, monthly spend ceiling, Vectorize namespace, migrations, Worker scopes, and rollback procedure.

Vincent explicitly authorized the local-only Phase 6 foundation on 2026-08-10 before the Phase 5 signing exit gate. Tasks 1–4 may proceed against synthetic fixtures; the original Phase 5 gate remains mandatory for File Provider release evidence and all cloud intelligence remains separately gated.

## File Map

| Path | Responsibility |
| --- | --- |
| Packages/FramebaseKit/Sources/FramebaseDomain/IntelligenceModels.swift | Typed analysis kinds, results, provenance, validation, and stale state. |
| Packages/FramebaseKit/Sources/FramebaseDomain/IntelligenceProtocols.swift | Provider-neutral service and repository contracts. |
| Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogIntelligenceRepository.swift | Additive storage, observation, stale invalidation, and parameterized OCR lookup. |
| Packages/FramebaseKit/Sources/FramebaseMedia/IntelligenceDerivativeProvider.swift | Fixed-size, checksum-addressed analysis derivative. |
| Packages/FramebaseKit/Sources/FramebaseMedia/VisionIntelligenceService.swift | Local Vision OCR, barcode, and document adapter. |
| App/LibraryWindowModel.swift and UI/Inspector/FoundationInspector.swift | Explicit Analyze action and provenance display. |
| docs/PHASE_6_CLOUD_INTELLIGENCE_OPERATIONS.md | Development-only resource, privacy, cost, and rollback approval package. |
| docs/phases/PHASE_6_VISUAL_PHOTO_INTELLIGENCE.md | Claude Sonnet assessment, feedback-learning, before/after, and hairline-presentation plan. |
| Cloud/apps/api and Cloud/contracts | Deferred cloud contract after the separate resource approval. |

---

### Task 1: Define intelligence and provenance contracts

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseDomain/IntelligenceModels.swift
- Create: Packages/FramebaseKit/Sources/FramebaseDomain/IntelligenceProtocols.swift
- Create: Packages/FramebaseKit/Tests/FramebaseDomainTests/IntelligenceModelTests.swift

**Produces:** AssetAnalysisRequest, AssetAnalysisResult, AnalysisProvenance, AnalysisKind, AnalysisStatus, and IntelligenceService.

- [x] **Step 1: Write failing validation tests**

~~~swift
func testResultRequiresDerivativeDigestAndEngineRevision() throws {
    XCTAssertThrowsError(try AssetAnalysisResult(
        assetID: assetID, kind: .ocr, provenance: .missingDigest, payload: .ocr([])
    ))
}

func testRequestCannotContainCatalogMutation() {
    XCTAssertFalse(AssetAnalysisRequest(assetID: assetID, kinds: [.ocr]).allowsCatalogMutation)
}
~~~

- [x] **Step 2: Confirm the tests fail**

Run: swift test --package-path Packages/FramebaseKit --filter IntelligenceModelTests

Expected: compile failure because the contracts are absent.

- [x] **Step 3: Implement strict provider-neutral types**

Start with OCR, barcode, and document. OCR lines include normalized rectangles and confidence; barcode results include symbology and payload. Legacy face-region payloads may decode only to keep prior catalogs readable; no active request or UI may expose them. Provenance includes local engine, request revision, schema version, derivative SHA-256/dimension, timestamp, and locales. No type may hold a token, local path, original bytes, or mutation closure.

- [x] **Step 4: Verify domain tests**

Run: swift test --package-path Packages/FramebaseKit --filter IntelligenceModelTests

Expected: PASS for validation, Codable stability, no-mutation invariant, and redacted debug rendering.

- [x] **Step 5: Commit**

~~~bash
git add Packages/FramebaseKit/Sources/FramebaseDomain Packages/FramebaseKit/Tests/FramebaseDomainTests
git commit -m "Add intelligence provenance contracts"
~~~

### Task 2: Add additive catalog persistence and stale-result rules

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseCatalog/CatalogIntelligenceRepository.swift
- Modify: Packages/FramebaseKit/Sources/FramebaseCatalog/FramebaseCatalog.swift
- Create: Packages/FramebaseKit/Tests/FramebaseCatalogTests/CatalogIntelligenceRepositoryTests.swift

**Produces:** IntelligenceRepository with result persistence, lookup, structured OCR query, and stale invalidation.

- [x] **Step 1: Write the failing migration/reopen test**

~~~swift
func testChangedDerivativeMarksPriorResultStaleWithoutDeletingIt() async throws {
    try await repository.store(result(for: assetID, digest: oldDigest))
    try await repository.markStaleIfSourceDigestDiffers(assetID: assetID, digest: newDigest)
    XCTAssertEqual(try await repository.results(for: assetID).first?.status, .stale)
}
~~~

- [x] **Step 2: Confirm the test fails**

Run: swift test --package-path Packages/FramebaseKit --filter CatalogIntelligenceRepositoryTests

Expected: compile failure because the repository is absent.

- [x] **Step 3: Implement additive tables and indexes**

Add analysis_runs, analysis_results, and analysis_text_lines with foreign keys to assets and uniqueness on asset, kind, engine, revision, and derivative digest. Use typed columns or validated JSON for geometry/confidence. Add only normalized parameterized OCR search indexing. Never log or expose stored OCR/barcode values.

- [x] **Step 4: Verify catalog tests**

Run: swift test --package-path Packages/FramebaseKit --filter CatalogIntelligenceRepositoryTests

Expected: PASS from empty and upgraded catalogs, idempotent retries, stale marking, parameterized lookup, and retained prior provenance.

- [x] **Step 5: Commit**

~~~bash
git add Packages/FramebaseKit/Sources/FramebaseCatalog Packages/FramebaseKit/Tests/FramebaseCatalogTests
git commit -m "Add catalog intelligence provenance storage"
~~~

### Task 3: Implement bounded local Apple Vision analysis

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseMedia/IntelligenceDerivativeProvider.swift
- Create: Packages/FramebaseKit/Sources/FramebaseMedia/VisionIntelligenceService.swift
- Create: Packages/FramebaseKit/Tests/FramebaseMediaTests/VisionIntelligenceServiceTests.swift
- Create: Packages/FramebaseKit/Tests/FramebaseMediaTests/Fixtures/ with synthetic text and barcode images

**Produces:** local-only OCR, barcode, and document analysis.

- [ ] **Step 1: Write the failing Vision test**

~~~swift
func testOCRCapturesFixtureTextWithProvenance() async throws {
    let result = try await service.analyze(request: .fixtureOCR(assetID))
    XCTAssertTrue(result.ocrLines.contains { $0.text == "FRAMEBASE" })
    XCTAssertEqual(result.provenance.engine, "Apple Vision")
    XCTAssertFalse(result.provenance.derivativeSHA256.isEmpty)
}
~~~

- [ ] **Step 2: Confirm the test fails**

Run: swift test --package-path Packages/FramebaseKit --filter VisionIntelligenceServiceTests

Expected: compile failure because the provider is absent.

- [x] **Step 3: Implement the bounded derivative and requests**

Generate a maximum 1600-pixel ImageIO derivative, hash it, and discard transient bytes after processing. Execute VNRecognizeTextRequest, VNDetectBarcodesRequest, and document detection where supported. Capture actual request revision/language configuration. Run off the main actor and honor cancellation between requests. Do not execute face detection.

- [x] **Step 4: Verify local analysis tests**

Run: swift test --package-path Packages/FramebaseKit --filter VisionIntelligenceServiceTests

Expected: PASS for text/geometry, QR/barcode payload capture, empty result, cancellation, unsupported-request fallback, derivative bound, and provenance.

- [ ] **Step 5: Commit**

~~~bash
git add Packages/FramebaseKit/Sources/FramebaseMedia Packages/FramebaseKit/Tests/FramebaseMediaTests
git commit -m "Add local Vision intelligence service"
~~~

### Task 4: Add explicit review and OCR search UI

**Files:**
- Modify: App/AppContainer.swift
- Modify: App/LibraryWindowModel.swift
- Modify: UI/Inspector/FoundationInspector.swift
- Modify: UI/AppShell/LibraryWindowView.swift
- Modify: FramebaseUITests/FramebaseUITests.swift

**Produces:** explicit Analyze controls, visible provenance/status, and OCR search with no automatic catalog change.

- [x] **Step 1: Write the UI test**

~~~swift
func testAnalyzeShowsProvenanceWithoutChangingOrganization() throws {
    app.buttons["inspector.analyze.ocr"].click()
    XCTAssertTrue(app.staticTexts["analysis.provenance"].waitForExistence(timeout: 5))
    XCTAssertEqual(folderLabel.label, originalFolderName)
    XCTAssertEqual(tagSummary.label, originalTagSummary)
}
~~~

- [ ] **Step 2: Confirm the test fails**

Run: xcodebuild -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS' test -only-testing:FramebaseUITests/IntelligenceUITests

Expected: controls are absent.

- [x] **Step 3: Implement explicit opt-in UI**

Add per-asset and bounded multi-select Analyze actions. Show queued/running/succeeded/failed/stale status, engine/revision/derivative/confidence, and copyable OCR text. Add an OCR filter to browser search with result provenance. Do not add person names, semantic-result claims, or Apply Tags/Move actions.

- [x] **Step 4: Verify UI and app**

Run: xcodebuild -project Framebase.xcodeproj -scheme Framebase -destination 'platform=macOS' test -only-testing:FramebaseUITests/IntelligenceUITests

Run: ./script/build_and_run.sh --verify

Expected: PASS and all organization fields remain unchanged by analysis.

- [ ] **Step 5: Commit**

~~~bash
git add App UI FramebaseUITests
git commit -m "Add opt-in local intelligence review UI"
~~~

### Task 5: Write the cloud-intelligence resource and approval request

**Files:**
- Create: docs/PHASE_6_CLOUD_INTELLIGENCE_OPERATIONS.md
- Modify: docs/phases/PHASE_6_INTELLIGENCE_AND_SEMANTIC_SEARCH.md

- [x] **Step 1: Specify the exact approval matrix**

Document provider/model, derivative dimensions/format, payload, retention, prompt/schema version, AI Gateway logging disablement, rate/retry policy, monthly cap, Vectorize namespace, D1 migrations, Worker scopes, observability, rollback, and synthetic-fixture proof.

- [x] **Step 2: Verify no cloud intelligence is wired prematurely**

Run: rg -n 'AIGateway|Vectorize|Workers AI|embedding|semantic' App Packages Cloud/apps/api

Expected: no executable cloud-intelligence route.

- [ ] **Step 3: Stop for separate authorization**

Do not create resources, alter /Users/vMac/.env, set secrets, deploy, or transmit an image derivative until Vincent approves the provider and spend cap.

### Task 6: Add semantic retrieval only after Task 5 authorization

**Files:**
- Create: Packages/FramebaseKit/Sources/FramebaseDomain/SemanticSearchModels.swift
- Create: Cloud/apps/api/migrations/0007_intelligence_metadata.sql
- Create: Cloud/apps/api/src/routes/intelligence.ts
- Modify: Cloud/apps/api/src/index.ts
- Modify: Cloud/contracts/framebase-api-v1.openapi.json
- Create: Cloud/apps/api/test/intelligence.test.ts

- [ ] **Step 1: Write the failing contract test**

~~~ts
it("rejects semantic search outside the authenticated library namespace", async () => {
  const response = await app.request("/v1/intelligence/search", { headers: otherLibraryToken })
  expect(response.status).toBe(403)
})
~~~

- [ ] **Step 2: Confirm the test fails**

Run: npm test -- --run intelligence.test.ts

Expected: route-not-found failure.

- [ ] **Step 3: Implement only the approved contract**

Use an explicit library namespace, structured filters, provenance, rate limits, cost accounting, and redacted logging. Return ranked candidates with provenance only; no model result may mutate organization.

- [ ] **Step 4: Verify contract and privacy tests**

Run: npm test && npm run typecheck

Expected: PASS for namespace isolation, scope rejection, bounded payload, rate limit, redacted logging, and failed-provider retry behavior.

- [ ] **Step 5: Request deployment approval**

Do not apply a migration, create Vectorize, set secrets, deploy, or transmit derivatives without exact approval.

## Phase 6 Exit Checklist

- [ ] Representative local OCR quality and runtime evidence exists.
- [ ] Every result has engine/provider, revision, schema, confidence, and derivative provenance.
- [ ] Same-input reprocessing is idempotent and changed inputs/models mark old results stale.
- [ ] No failed or low-confidence result silently organizes an asset.
- [ ] Structured catalog filters constrain semantic candidates and namespaces cannot cross.
- [ ] Cost caps, rate limits, logging privacy, and recovery are verified before a cloud result is enabled.
