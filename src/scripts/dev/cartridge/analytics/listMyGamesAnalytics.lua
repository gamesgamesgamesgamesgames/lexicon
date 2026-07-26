-- Headline analytics for every game the authenticated caller owns.
--
-- Auth:      requires an authenticated caller (`caller_did`); anonymous
--            requests are rejected.
-- Ownership: a game is owned by the DID whose repo holds the game record, so
--            "my games" is exactly the game records where `did = caller_did`
--            (the same predicate as listGames.lua's `did` filter, and the
--            authority segment used by getGame.lua's verified-owner lookup).
-- Data:      per-game headline metrics come from a separate self-hosted
--            ClickHouse (read over HTTP). Slug sets are batched into one query
--            per metric with a bound `Array(String)` parameter.

local RANGE_DAYS = { ["7d"] = 7, ["30d"] = 30, ["90d"] = 90 }

-- ---------------------------------------------------------------------------
-- Small numeric helpers.
-- ---------------------------------------------------------------------------

local function num(v)
  return tonumber(v) or 0
end

-- Round to a whole number (ClickHouse aggregates arrive as strings/floats).
local function iround(v)
  return math.floor(num(v) + 0.5)
end

-- Round a fraction to 4 decimal places (used for CTR, 0..1).
local function round4(v)
  return math.floor(num(v) * 10000 + 0.5) / 10000
end

-- ---------------------------------------------------------------------------
-- Range → inclusive UTC Date bounds + the full day axis.
-- ---------------------------------------------------------------------------

local function normalize_range(r)
  if r and RANGE_DAYS[r] then return r end
  return "30d"
end

-- Ordered list of 'YYYY-MM-DD' UTC days ending today, `days` long.
local function date_axis(days)
  local now_t = os.time()
  local axis = {}
  for i = days - 1, 0, -1 do
    axis[#axis + 1] = os.date("!%Y-%m-%d", now_t - i * 86400)
  end
  return axis
end

-- ---------------------------------------------------------------------------
-- ClickHouse HTTP read helper.
--
-- POSTs SQL to the ClickHouse HTTP interface with `FORMAT JSON`, using a
-- read-only user over basic-style ClickHouse auth headers. Query parameters
-- are bound with ClickHouse's `{name:Type}` / `param_name` mechanism so slugs
-- and dates are never interpolated into SQL. Returns the `data` array, or an
-- empty table on ANY failure — ClickHouse being unreachable must never error
-- the whole request.
-- ---------------------------------------------------------------------------

local function ch_urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function ch_query(sql, ch_params)
  local base = env.CLICKHOUSE_URL
  if not base or base == "" then return {} end

  local qs = "default_format=JSON&database=" ..
    ch_urlencode(env.CLICKHOUSE_DATABASE or "cartridge_analytics")
  if ch_params then
    for k, v in pairs(ch_params) do
      qs = qs .. "&param_" .. k .. "=" .. ch_urlencode(v)
    end
  end

  local ok, resp = pcall(function()
    return http.post(base .. "?" .. qs, {
      headers = {
        ["X-ClickHouse-User"] = env.CLICKHOUSE_READ_USER or "readonly",
        ["X-ClickHouse-Key"] = env.CLICKHOUSE_READONLY_PASSWORD or "",
        ["content-type"] = "text/plain",
      },
      body = sql,
    })
  end)

  if not ok or not resp or resp.status ~= 200 then
    return {}
  end

  local decoded_ok, decoded = pcall(json.decode, resp.body)
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
    return {}
  end
  return decoded.data
end

-- Build a ClickHouse `Array(String)` param literal, e.g. ['a','b'], with
-- single-quote/backslash escaping so arbitrary slugs bind safely.
local function ch_array_param(items)
  local parts = {}
  for _, s in ipairs(items) do
    local esc = tostring(s):gsub("\\", "\\\\"):gsub("'", "\\'")
    parts[#parts + 1] = "'" .. esc .. "'"
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- ---------------------------------------------------------------------------
-- Ownership helper.
-- ---------------------------------------------------------------------------

local function find_slug(uri)
  local rows = db.raw("SELECT slug FROM slugs WHERE uri = $1 LIMIT 1", { uri })
  if rows and #rows > 0 then return rows[1].slug end
  return nil
end

function handle()
  -- Require authentication.
  if not caller_did or caller_did == "" then
    return { error = "AuthRequired", message = "Authentication required" }
  end

  local range = normalize_range(params.range)
  local days = RANGE_DAYS[range]
  local axis = date_axis(days)
  local from = axis[1]
  local to = axis[#axis]

  -- The caller's owned games: game records living in the caller's repo.
  local rows = db.raw(
    "SELECT uri, record FROM happyview_records WHERE collection = $1 AND did = $2",
    { "games.gamesgamesgamesgames.game", caller_did }
  )
  if not rows or #rows == 0 then
    return { range = range, games = toarray({}) }
  end

  -- Map each game to its slug (games without a slug can't be looked up in
  -- ClickHouse, which keys on slug, so they're skipped).
  local games = {}
  local slugs = {}
  for _, row in ipairs(rows) do
    local rec = json.decode(row.record)
    local slug = find_slug(row.uri)
    if slug then
      games[#games + 1] = { slug = slug, name = (rec and rec.name) or slug }
      slugs[#slugs + 1] = slug
    end
  end
  if #games == 0 then
    return { range = range, games = toarray({}) }
  end

  local ch = { slugs = ch_array_param(slugs), from = from, to = to }

  -- Impressions + clicks per slug (for CTR).
  local surface_rows = ch_query(
    "SELECT game_slug, sumMerge(impressions) AS impressions, sumMerge(clicks) AS clicks " ..
    "FROM daily_game_surface " ..
    "WHERE game_slug IN {slugs:Array(String)} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY game_slug", ch)
  local impressions_by, clicks_by = {}, {}
  for _, row in ipairs(surface_rows) do
    impressions_by[row.game_slug] = iround(row.impressions)
    clicks_by[row.game_slug] = iround(row.clicks)
  end

  -- Pageviews + mean dwell per slug.
  local eng_rows = ch_query(
    "SELECT game_slug, countMerge(pageviews) AS pageviews, avgMerge(dwell_avg) AS dwell_avg " ..
    "FROM daily_game_engagement " ..
    "WHERE game_slug IN {slugs:Array(String)} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY game_slug", ch)
  local pageviews_by, dwell_by = {}, {}
  for _, row in ipairs(eng_rows) do
    pageviews_by[row.game_slug] = iround(row.pageviews)
    dwell_by[row.game_slug] = iround(row.dwell_avg)
  end

  -- Pageviews per day per slug (for the sparkline).
  local spark_rows = ch_query(
    "SELECT game_slug, date, countMerge(pageviews) AS pageviews " ..
    "FROM daily_game_engagement " ..
    "WHERE game_slug IN {slugs:Array(String)} AND date BETWEEN {from:Date} AND {to:Date} " ..
    "GROUP BY game_slug, date ORDER BY date", ch)
  local spark_by = {}
  for _, row in ipairs(spark_rows) do
    local s = row.game_slug
    spark_by[s] = spark_by[s] or {}
    spark_by[s][row.date] = iround(row.pageviews)
  end

  -- Assemble one row per game.
  local out = {}
  for _, g in ipairs(games) do
    local imp = impressions_by[g.slug] or 0
    local clk = clicks_by[g.slug] or 0
    local per_day = spark_by[g.slug] or {}
    local sparkline = {}
    for _, d in ipairs(axis) do
      sparkline[#sparkline + 1] = { date = d, value = per_day[d] or 0 }
    end
    out[#out + 1] = {
      slug = g.slug,
      name = g.name,
      impressions = imp,
      pageviews = pageviews_by[g.slug] or 0,
      ctr = imp > 0 and round4(clk / imp) or 0,
      avgDwellMs = dwell_by[g.slug] or 0,
      sparkline = toarray(sparkline),
    }
  end

  -- Rank the table by impressions (busiest games first), then name.
  table.sort(out, function(a, b)
    if a.impressions ~= b.impressions then return a.impressions > b.impressions end
    return a.name < b.name
  end)

  return { range = range, games = toarray(out) }
end
