-- Phase F: Preserve file identity across renames/moves.
-- Adds a stable filesystem identifier (device:inode on Unix, fileResourceIdentifier on macOS)
-- so a rename can be correlated as an UPDATE rather than DELETE+INSERT.
-- Existing rows get NULL (treated as “unknown, fall back to path”); new rows store it.
-- No data loss, no index rebuild beyond the new column.

ALTER TABLE files ADD COLUMN file_identifier TEXT;

CREATE INDEX IF NOT EXISTS idx_files_workspace_identifier ON files (workspace_id, file_identifier) WHERE file_identifier IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_files_identifier ON files (file_identifier) WHERE file_identifier IS NOT NULL;
