-- Phase 3 keeps the immutable local asset envelope with the remote catalog so
-- a clean catalog can be rebuilt without inventing a new Asset ID or storage key.
ALTER TABLE assets ADD COLUMN asset_metadata TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(asset_metadata));

CREATE INDEX IF NOT EXISTS album_assets_asset_idx ON album_assets(asset_id, album_id);
