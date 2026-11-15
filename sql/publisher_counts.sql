-- Table for the search.publisher-counts job and the officialScore signal in
-- src/shared/game_index.lua. Run once, before deploying them. Postgres.
-- Idempotent.
--
-- One row per organization credited as a publisher on at least one game, with
-- the number of distinct games it is credited as publishing. The search
-- builder treats a publisher with at least 10 games as an established one.

CREATE TABLE IF NOT EXISTS publisher_counts (
  org_uri    TEXT PRIMARY KEY,
  games      INTEGER NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS publisher_counts_games ON publisher_counts (games);
