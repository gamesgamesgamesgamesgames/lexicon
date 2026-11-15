-- Recounts, for every organization credited as a publisher, how many distinct
-- games it publishes, into publisher_counts. Queued by refreshPublisherCounts.
-- The search document builder reads the table for officialScore. Table:
-- sql/publisher_counts.sql.
--
-- A credit whose roles is missing or not an array counts as no roles.
--
-- One statement: it counts the org.credit records with the publisher role,
-- writes only the counts that changed, and removes organizations that no
-- longer publish anything. A dry run reports the same numbers without writing.
--
-- Input:
--   dryRun   count only

local CREDIT_NSID = "games.gamesgamesgamesgames.org.credit"

local COUNTS = "SELECT record::jsonb->'org'->>'uri' AS org_uri, COUNT(DISTINCT record::jsonb->'game'->>'uri') AS games " ..
  "FROM happyview_records WHERE collection = $1 AND record::jsonb->'org'->>'uri' IS NOT NULL " ..
  "AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(record::jsonb->'roles') = 'array' THEN record::jsonb->'roles' ELSE '[]'::jsonb END) AS r(role) WHERE r.role = 'publisher') " ..
  "GROUP BY 1"

function handle()
  local input = job.input or {}
  local dry_run = input.dryRun == true
  local rows
  if dry_run then
    rows = db.raw(
      "WITH counts AS (" .. COUNTS .. ") SELECT COUNT(*) AS publishers, COUNT(*) FILTER (WHERE games >= 10) AS established, " ..
      "(SELECT COUNT(*) FROM counts c LEFT JOIN publisher_counts p ON p.org_uri = c.org_uri WHERE p.games IS DISTINCT FROM c.games) AS changed, " ..
      "(SELECT COUNT(*) FROM publisher_counts p WHERE NOT EXISTS (SELECT 1 FROM counts c WHERE c.org_uri = p.org_uri)) AS removed FROM counts",
      { CREDIT_NSID }
    )
  else
    rows = db.raw(
      "WITH counts AS (" .. COUNTS .. "), " ..
      "del AS (DELETE FROM publisher_counts p WHERE NOT EXISTS (SELECT 1 FROM counts c WHERE c.org_uri = p.org_uri) RETURNING 1), " ..
      "up AS (INSERT INTO publisher_counts (org_uri, games, updated_at) SELECT org_uri, games, NOW() FROM counts " ..
      "ON CONFLICT (org_uri) DO UPDATE SET games = EXCLUDED.games, updated_at = EXCLUDED.updated_at " ..
      "WHERE publisher_counts.games IS DISTINCT FROM EXCLUDED.games RETURNING 1) " ..
      "SELECT (SELECT COUNT(*) FROM counts) AS publishers, (SELECT COUNT(*) FROM counts WHERE games >= 10) AS established, " ..
      "(SELECT COUNT(*) FROM up) AS changed, (SELECT COUNT(*) FROM del) AS removed",
      { CREDIT_NSID }
    )
  end
  local r = rows and rows[1] or {}
  local out = {
    dryRun = dry_run,
    publishers = tonumber(r.publishers) or 0,
    established = tonumber(r.established) or 0,
    changed = tonumber(r.changed) or 0,
    removed = tonumber(r.removed) or 0,
  }
  job.progress(out)
  log("search.publisher-counts: " .. json.encode(out))
  return out
end
