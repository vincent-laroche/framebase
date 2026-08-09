# Fixture Restore Drill

This is Phase 4 recovery evidence for deterministic test libraries only. It is not a user-library recovery command and must never be pointed at `~/Pictures/Framebase Library.framebase`.

1. Create a `FixtureLibraryFactory` library and obtain `FixtureMigrationAuthorization.fixtureOnly(rootURL:)`.
2. Run `FixtureLibraryManifestService.export(authorization:catalog:)`. It writes `Recovery/fixture-library-manifest.json` inside that fixture package and stores catalog relationships plus SHA-256/byte-count evidence, never original bytes.
3. Run `FixtureLibraryManifestService.restoreDrill(authorization:)`. It builds a new catalog below the fixture's `Recovery/RestoreDrill-*/Catalog/` directory from the sidecar manifest, then reports catalog parity, explicitly missing original Asset IDs, and checksum mismatches.
4. Treat any non-empty mismatch list as a failed drill. There is no purge, original deletion, overwrite, or real-library operation in this path.

The package acceptance test `FixtureMigrationAcceptanceTests.fixtureManifestRestoreDrill` proves both the clean reconstruction and explicit reporting when a temporary fixture original is removed.
