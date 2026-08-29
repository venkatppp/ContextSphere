-- ---------------------------------------------------------------------
-- Activity observation — local-first workspace activity
--
-- Stores application foreground intervals and web visits observed on
-- this Mac. All rows are local-only, append-only; no telemetry leaves
-- the device. The table is additive — nothing rewrites an existing table.
--
-- Design:
--   app_name      human-readable (Xcode, Safari, Terminal…)
--   bundle_id     e.g. com.apple.dt.Xcode — may be NULL when unavailable
--   window_title  optional front window title (no private content)
--   url_domain    domain only for web visits (developer.apple.com), NULL for app events
--   url_title     page title when permitted (no query strings, no path params)
--   event_type    'app_foreground' | 'web_visit'
--   started_at    when the app became foreground / page became active
--   ended_at      when it ceased being foreground — NULL while still active
--   duration_seconds computed at close, NULL while open
--   workspace_id  workspace this observation correlated to at record time — may be NULL (global)
--   metadata      JSON for future extension (e.g. browser, source)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS activity_events (
    id               TEXT PRIMARY KEY NOT NULL,
    workspace_id     TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
    app_name         TEXT NOT NULL,
    bundle_id        TEXT,
    window_title     TEXT,
    url_domain       TEXT,
    url_title        TEXT,
    event_type       TEXT NOT NULL CHECK (event_type IN ('app_foreground', 'web_visit')),
    started_at       TEXT NOT NULL,
    ended_at         TEXT,
    duration_seconds INTEGER CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    metadata         TEXT,
    created_at       TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_workspace_started
    ON activity_events (workspace_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_app ON activity_events (app_name);
CREATE INDEX IF NOT EXISTS idx_activity_domain ON activity_events (url_domain) WHERE url_domain IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_activity_started ON activity_events (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_type ON activity_events (event_type);
