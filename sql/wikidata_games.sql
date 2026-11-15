-- Tables for the wikidata.sync job. Run once, before deploying the job.
-- Postgres. Idempotent.
--
-- wikidata_games holds one row per IGDB game ID that Wikidata knows something
-- useful about: at least one sitelink, a publisher (P123), or an instance-of
-- class that marks a mod or fan game. Items with none of those are left out,
-- because they would add nothing to search ranking.
--
-- The job fills wikidata_games_staging step by step, then replaces the
-- contents of wikidata_games with it in one statement, so readers never see a
-- half-finished sync. Data from Wikidata is CC0.

CREATE TABLE IF NOT EXISTS wikidata_games (
  igdb_id       TEXT PRIMARY KEY,              -- IGDB numeric game ID (Wikidata P5794 qualifier P9043)
  qid           TEXT NOT NULL,                 -- Wikidata item, such as Q213911
  sitelinks     INTEGER NOT NULL DEFAULT 0,    -- number of Wikimedia sitelinks
  has_publisher INTEGER NOT NULL DEFAULT 0,    -- 1 when the item has a publisher (P123)
  veto_class    TEXT,                          -- set when instance-of (P31) is a mod / fan game class
  enwiki_title  TEXT,                          -- English Wikipedia article title, for pageviews later
  synced_at     TIMESTAMPTZ NOT NULL DEFAULT NOW() -- when a sync last changed this row
);

CREATE TABLE IF NOT EXISTS wikidata_games_staging (
  igdb_id       TEXT PRIMARY KEY,
  qid           TEXT,
  sitelinks     INTEGER NOT NULL DEFAULT 0,
  has_publisher INTEGER NOT NULL DEFAULT 0,
  veto_class    TEXT,
  enwiki_title  TEXT
);
