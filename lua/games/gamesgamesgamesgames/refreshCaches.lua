local function parse_admin_dids()
  local dids = {}
  local raw = env.ADMIN_DIDS or ""
  for did in raw:gmatch("[^,]+") do
    dids[did:match("^%s*(.-)%s*$")] = true
  end
  return dids
end

local ADMIN_DIDS = parse_admin_dids()

function handle()
  if not ADMIN_DIDS[caller_did] then
    error("unauthorized: only admins can refresh caches")
  end

  -- Refresh stats_cache
  local game_count = db.raw(
    "SELECT COUNT(*) as count FROM records WHERE collection = $1",
    {"games.gamesgamesgamesgames.game"}
  )
  local studio_count = db.raw(
    "SELECT COUNT(DISTINCT json_extract(record, '$.org.uri')) as count FROM records WHERE collection = $1",
    {"games.gamesgamesgamesgames.org.credit"}
  )
  local review_count = db.raw(
    "SELECT COUNT(*) as count FROM records WHERE collection = $1",
    {"social.popfeed.feed.review"}
  )

  db.raw("INSERT INTO stats_cache (key, value, updated_at) VALUES ('totalGames', $1, datetime('now')) ON CONFLICT (key) DO UPDATE SET value = $1, updated_at = datetime('now')",
    { game_count and game_count[1] and game_count[1].count or 0 })
  db.raw("INSERT INTO stats_cache (key, value, updated_at) VALUES ('totalStudios', $1, datetime('now')) ON CONFLICT (key) DO UPDATE SET value = $1, updated_at = datetime('now')",
    { studio_count and studio_count[1] and studio_count[1].count or 0 })
  db.raw("INSERT INTO stats_cache (key, value, updated_at) VALUES ('totalReviews', $1, datetime('now')) ON CONFLICT (key) DO UPDATE SET value = $1, updated_at = datetime('now')",
    { review_count and review_count[1] and review_count[1].count or 0 })

  -- Refresh genre_counts_cache
  db.raw("DELETE FROM genre_counts_cache", {})
  local genres = db.raw(
    "SELECT je.value AS genre, COUNT(*) AS count FROM records, json_each(record, '$.genres') AS je WHERE collection = $1 GROUP BY je.value ORDER BY count DESC",
    {"games.gamesgamesgamesgames.game"}
  )
  if genres then
    for _, row in ipairs(genres) do
      db.raw("INSERT INTO genre_counts_cache (genre, count, updated_at) VALUES ($1, $2, datetime('now'))",
        { row.genre, row.count })
    end
  end

  return { refreshed = toarray({ "stats_cache", "genre_counts_cache" }) }
end
